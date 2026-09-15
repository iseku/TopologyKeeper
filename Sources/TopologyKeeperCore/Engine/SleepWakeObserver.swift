import AppKit
import Foundation

/// 系统睡眠 / 唤醒观察。
///
/// ## 为什么需要它（D8，实测依据 §2.12）
/// 设备在**睡眠期间**以 `[2ch]` 状态存在了 16 秒。若此时尝试应用规则，
/// 会因目标格式不可用而失败（无害），但更可能在睡眠/唤醒临界点
/// 触发显示重新同步。因此睡眠期间要抑制动作。
///
/// ## ⚠️ 实测踩到的严重缺陷（务必保留看门狗）
/// 最初的实现把"睡眠中"做成**闭锁**：`willSleep` 置位，只有 `didWake` 清除。
/// 但实测发现 **`willSleep` 可能在没有真正睡眠的情况下发出** ——
/// 例如睡眠被电源断言阻止（真机日志：`InternalPreventSleep`，
/// `pmset -g log` 显示 `Total Sleep/Wakes: 0`），此时 `didWake` 永不到来，
/// **引擎会永久停在"睡眠中"再也不动作**，格式漂移后也不修复。
///
/// 修复思路：**"定时器能触发"本身就是"系统醒着"的证据**。
/// `willSleep` 后启动一次性看门狗，若它在系统确实睡眠前触发，
/// 说明睡眠没真正发生，立即清除标志。
/// 真正的睡眠期间进程被挂起、定时器不会触发；唤醒后定时器补触发，
/// 与 `didWake` 一起把标志清掉 —— 两条路径都安全。
public final class SleepWakeObserver: SleepWakeObserving, @unchecked Sendable {

    public var onSleep: (@Sendable () -> Void)?
    public var onWake: (@Sendable () -> Void)?

    /// 睡眠标志。**由本类维护**，引擎据此决定是否动作。
    private let sleepingFlag = LockedFlag()

    public var isSleeping: Bool { sleepingFlag.value }

    private var observers: [NSObjectProtocol] = []
    private let hopQueue: DispatchQueue?

    /// 看门狗用的延迟执行器（可注入，便于测试）
    private let watchdogExecutor: DelayedExecutor?
    private let watchdogIntervalMs: Int
    private var watchdogGeneration: UInt64 = 0

    /// 看门狗触发时打的标志，供测试断言
    public private(set) var watchdogFireCount = 0

    /// - Parameters:
    ///   - hopQueue: 事件转发到该队列（通常是 audioQueue，保持串行纪律）。
    ///     传 nil 则在主线程回调。
    ///   - watchdogExecutor: 看门狗执行器。传 nil 表示不启用看门狗
    ///     （仅测试用；生产环境必须启用）。
    ///   - watchdogIntervalMs: 看门狗延时。
    public init(hopQueue: DispatchQueue? = nil,
                watchdogExecutor: DelayedExecutor? = nil,
                watchdogIntervalMs: Int = 8000) {
        self.hopQueue = hopQueue
        self.watchdogExecutor = watchdogExecutor
        self.watchdogIntervalMs = watchdogIntervalMs
    }

    // MARK: - 生命周期

    public func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        let queue: OperationQueue = .main

        func observe(_ name: NSNotification.Name, _ body: @escaping @Sendable () -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: queue) { _ in
                if let hop = self.hopQueue {
                    hop.async { body() }
                } else {
                    body()
                }
            }
            observers.append(token)
        }

        observe(NSWorkspace.willSleepNotification) { [weak self] in
            self?.handleWillSleep()
        }
        observe(NSWorkspace.didWakeNotification) { [weak self] in
            self?.handleDidWake()
        }
        observe(NSWorkspace.screensDidSleepNotification) { [weak self] in
            self?.handleScreensDidSleep()
        }
        observe(NSWorkspace.screensDidWakeNotification) { [weak self] in
            self?.handleScreensDidWake()
        }
    }

    public func stop() {
        cancelWatchdog()
        let center = NSWorkspace.shared.notificationCenter
        for token in observers { center.removeObserver(token) }
        observers.removeAll()
        sleepingFlag.value = false
    }

    // MARK: - 状态机（internal，便于测试直接驱动）

    /// 系统即将睡眠
    func handleWillSleep() {
        sleepingFlag.value = true
        startWatchdog()
        Log.info("系统即将睡眠 —— 暂停一切设备动作")
        onSleep?()
    }

    /// 系统已唤醒
    func handleDidWake() {
        cancelWatchdog()
        guard sleepingFlag.value else { return }   // 重复通知，避免重复评估
        sleepingFlag.value = false
        Log.info("系统已唤醒 —— 恢复评估")
        onWake?()
    }

    private func handleScreensDidSleep() {
        Log.debug("显示器休眠")
    }

    private func handleScreensDidWake() {
        // 显示器唤醒早于系统唤醒，早一点恢复评估有好处
        // （实测能力到位需要 19~28 秒，早开始没坏处）
        cancelWatchdog()
        Log.info("显示器已唤醒")
        guard sleepingFlag.value else { return }
        sleepingFlag.value = false
        onWake?()
    }

    // MARK: - 看门狗

    /// `willSleep` 后启动一次性看门狗。
    ///
    /// 语义：**它若触发，就说明系统根本没睡**。
    /// 真正的睡眠期间进程被挂起，定时器不可能触发；
    /// 唤醒后它会补触发，与 `didWake` 一起清标志（幂等）。
    private func startWatchdog() {
        guard let executor = watchdogExecutor else { return }
        watchdogGeneration &+= 1
        let generation = watchdogGeneration

        executor(watchdogIntervalMs) { [weak self] in
            guard let self, self.watchdogGeneration == generation else { return }
            guard self.sleepingFlag.value else { return }

            self.watchdogFireCount += 1
            self.sleepingFlag.value = false
            Log.warn("睡眠标志超时仍未收到唤醒通知 —— "
                     + "判定睡眠未真正发生（可能被电源断言阻止），恢复设备动作")
            self.onWake?()
        }
    }

    private func cancelWatchdog() {
        watchdogGeneration &+= 1
    }
}

/// 简单加锁的可变布尔值（跨线程读写的睡眠标志）
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}
