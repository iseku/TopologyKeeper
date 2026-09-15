import AppKit
import Foundation
import TopologyKeeperCore

/// 依赖装配（DI 容器）。
///
/// 线程纪律（《详细设计.md》§9.1）：
/// 所有 CoreAudio 交互收敛到**单一串行队列** `audioQueue`；
/// `CoreAudioService` 的监听器回调也投递到该队列，
/// 因此回调与其它工作天然有序，无需 `Task` 或 actor 重入处理（D12）。
final class AppEnvironment: @unchecked Sendable {

    let audioQueue = DispatchQueue(label: "com.iseku.topologykeeper.audio", qos: .userInitiated)
    let store: ConfigStore
    let service: CoreAudioService
    let policy: ApplyPolicy
    let watcher: DeviceWatcher
    let sleepWake: SleepWakeObserver
    let engine: RuleEngine

    /// 声道交换的**独立队列**。
    ///
    /// 为什么不复用 `audioQueue`：声道交换是一个与格式锁定解耦的全局功能
    /// （用户确认），它有自己的重试节奏与设备解析；混进 `audioQueue` 会让
    /// 两个功能互相排队、互相影响。它的实时回调另有 HAL 线程，与此队列无关。
    let swapQueue = DispatchQueue(label: "com.iseku.topologykeeper.swap", qos: .userInitiated)
    let swapEngine: ChannelSwapEngine

    init(store: ConfigStore = ConfigStore()) {
        self.store = store
        let service = CoreAudioService()
        self.service = service

        // 配置读取在任意线程都可能发生；store 内部有锁保护。
        let storeRef = store
        self.policy = ApplyPolicy(config: { storeRef.config })

        self.watcher = DeviceWatcher(
            service: service,
            queue: audioQueue,
            debounceMs: store.config.eventDebounceMs,
            // 只监控已配置规则的设备 —— 避免为无关设备注册监听器
            watchedUIDs: { storeRef.config.rules.map(\.deviceUID) })

        // ★ 必须传 watchdogExecutor：否则一旦 willSleep 发出但睡眠被取消，
        //   引擎会永久卡在"睡眠中"（实测踩过，见 SleepWakeObserver 的说明）
        self.sleepWake = SleepWakeObserver(hopQueue: audioQueue,
                                           watchdogExecutor: makeQueueExecutor(audioQueue))

        self.engine = RuleEngine(
            service: service,
            watcher: watcher,
            sleepWake: sleepWake,
            policy: policy,
            config: { storeRef.config },
            queue: audioQueue,
            pollExecutor: makeQueueExecutor(audioQueue))

        // 声道交换：独立引擎 + 独立队列（与格式锁定零交互）。
        // 告警接收器通过持有盒注入（引擎在 init 时就需要 notifier 闭包，
        // 而"已授权的 Notifier"要到 AppState.start 才拿得到）。
        let sink = Self.sinkHolder
        self.swapEngine = ChannelSwapEngine(
            queue: swapQueue,
            notifier: { message in sink.deliver(message) })
    }

    /// 启动引擎。`publish` 会在 audioQueue 上被调用，调用方负责 hop 到主线程。
    ///
    /// - Parameter notify: 声道交换穷尽重试后的告警（用户确认：1-2-4-8 秒后仍不成功则提示）。
    ///   由调用方注入**已授权**的 Notifier —— 新造一个实例没走过授权流程，会静默不发。
    func start(publish: @escaping @Sendable ([RuleSnapshot]) -> Void,
               notify: (@Sendable (String) -> Void)? = nil,
               publishSwapState: (@Sendable (ChannelSwapState) -> Void)? = nil) {
        engine.onSnapshots = { snapshots in
            publish(snapshots)
        }
        // ★ 关键接线：设备拓扑变化（含睡眠唤醒的设备重建）或规则刚锁定后，
        //   让声道处理（交换 / 混音）重新评估并装配。
        //
        //   为什么必须由 RuleEngine 广播：它独占 `DeviceWatcher` 的事件流
        //   （`watcher.onEvent` 是单一闭包），而 `channelSwapDevicesChanged()`
        //   在此之前**只有**用户手动点"重试 / 立即应用全部"才会被调用 ——
        //   于是唤醒后设备重建（AudioDeviceID 变 2~3 次）时，
        //   交换通路的 AUHAL 单元仍然绑在**已销毁的旧设备**上，
        //   功能静默失效（日志实锤：唤醒后只留下"已锁定为 8ch"，
        //   再无一条"声道交换通路已启动"）。
        //
        //   顺序天然正确：`onChannelProcessingNeeded` 在本引擎的评估**之后**触发，
        //   此刻设备已被锁回 8ch，声道处理的 ≥6 声道门控才能通过。
        //
        //   参数 `devicesDisappeared` 区分两类事件：设备**被销毁**时必须强制重建
        //   （AUHAL 单元绑的 AudioDeviceID 已失效），而"只是列表变了"允许幂等短路
        //   —— 唤醒时事件会成簇到来，实测同一瞬间连着重启了 4 次。
        let swapTarget = swapEngine
        engine.onChannelProcessingNeeded = { devicesDisappeared in
            if devicesDisappeared {
                swapTarget.devicesDisappeared()
            } else {
                swapTarget.devicesChanged()
            }
        }
        audioQueue.async { [engine] in
            engine.start()
        }

        swapEngine.onStateChange = { state in
            publishSwapState?(state)
        }
        // 注入告警回调后按当前配置启动一次（开关为关时不占用任何设备）
        let storeRef = store
        swapQueue.async { [swapEngine] in
            swapEngine.apply(storeRef.config.channelSwap) { storeRef.config }
        }
        if let notify {
            Self.sinkHolder.set(notify)
        }
    }

    /// 告警接收器持有盒：`start(notify:)` 时填入，引擎经闭包间接调用。
    private static let sinkHolder = NotificationSinkHolder()

    func stop() {
        audioQueue.sync { [engine] in engine.stop() }
        swapQueue.sync { [swapEngine] in swapEngine.stop() }
    }

    // MARK: - 声道交换（在 swapQueue 上执行）

    /// 设置变更后重新应用（开关切换、设备选择变化等）
    func applyChannelSwap(_ settings: ChannelSwapSettings) {
        let storeRef = store
        swapQueue.async { [swapEngine] in
            swapEngine.apply(settings) { storeRef.config }
        }
    }

    /// 设备变化时让交换引擎重新评估。
    ///
    /// ★ 触发源有两个，语义互补：
    /// * **自动**：`RuleEngine.onChannelProcessingNeeded` —— 设备拓扑变化 /
    ///   规则刚锁定（`start()` 里接线，覆盖唤醒后的设备重建）；
    /// * **手动**：UI 的「重试 / 立即应用全部」（`AppState.reapplyChannelSwap`）。
    ///
    /// 开关未开时这里也是一次空转：`ChannelSwapSupervisor.devicesChanged()`
    /// 内部有 `needsAudioPath` 门控，不会为关着的功能去碰设备。
    ///
    /// - Parameter devicesDisappeared: 设备**被销毁**时为 true（强制重新装配）。
    ///   与"只是列表变了"分开的必要性见 `ChannelSwapSupervisor.devicesDisappeared()`。
    func channelSwapDevicesChanged(devicesDisappeared: Bool = false) {
        swapQueue.async { [swapEngine] in
            if devicesDisappeared {
                swapEngine.devicesDisappeared()
            } else {
                swapEngine.devicesChanged()
            }
        }
    }

    func channelSwapDiagnostics() -> ChannelSwapDiagnostics {
        swapQueue.sync { [swapEngine] in swapEngine.diagnostics() }
    }

    // MARK: - 对外动作（在 audioQueue 上执行）

    func applyNow(ruleID: UUID) {
        audioQueue.async { [engine] in engine.applyNow(ruleID: ruleID) }
    }

    func applyAllNow() {
        audioQueue.async { [engine] in engine.applyAllNow() }
    }

    /// 刷新快照（打开面板时调用；会顺带修正漂移）
    func refresh() {
        audioQueue.async { [engine] in engine.refreshSnapshots() }
    }

    /// 配置变更：重新注册监听器并立即评估。
    ///
    /// ⚠️ 不能只调 `refresh()` —— 新增规则后必须 `rearm()`，
    /// 否则新设备的就地变更检测不会生效（见 RuleEngine.configDidChange 的说明）。
    func configDidChange() {
        audioQueue.async { [engine] in engine.configDidChange() }
    }

    func setRuleEnabled(_ ruleID: UUID, _ enabled: Bool) {
        store.setRuleEnabled(ruleID, enabled)
        configDidChange()
    }

    /// 按"名称+传输类型"兜底查找设备（HDMI 的 UID 疑似由 EDID/端口派生，
    /// 换端口或换显示器后会变，此时需要重新绑定规则到新 UID）
    func deviceForFallbackMatch(of rule: DeviceRule) -> DeviceDescriptor? {
        audioQueue.sync { [service] in
            service.allOutputDevices().first { rule.matches($0) }
        }
    }

    /// 读取某设备当前物理格式（"添加规则"界面展示用）
    func currentFormat(forUID uid: String) -> AudioFormatPreset? {
        audioQueue.sync { [service] in
            guard let descriptor = service.deviceDescriptor(forUID: uid) else { return nil }
            return service.currentPhysicalFormat(ofDevice: descriptor.id)
                .map { AudioFormatPreset(asbd: $0) }
        }
    }

    /// 枚举当前所有输出设备（用于"添加规则"界面）
    func listOutputDevices() -> [DeviceDescriptor] {
        audioQueue.sync { [service] in service.allOutputDevices() }
    }

    /// 读取某设备的能力清单（用于级联格式选择器）
    func capability(forUID uid: String) -> DeviceCapability {
        audioQueue.sync { [service] in
            guard let descriptor = service.deviceDescriptor(forUID: uid) else { return .empty }
            return service.capability(of: descriptor.id)
        }
    }
}

/// 线程安全的"告警接收器"持有盒。
///
/// 存在的原因：`ChannelSwapEngine` 在 `AppEnvironment.init` 时就要拿到
/// notifier 闭包，而"已授权的 Notifier"要到 `AppState.start` 才存在。
/// 用一个盒子做中介，既保持依赖方向清晰，又避免为此把引擎改成可变注入。
private final class NotificationSinkHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var sink: (@Sendable (String) -> Void)?

    func set(_ newSink: @escaping @Sendable (String) -> Void) {
        lock.lock(); sink = newSink; lock.unlock()
    }

    func deliver(_ message: String) {
        lock.lock(); let current = sink; lock.unlock()
        current?(message)
    }
}
