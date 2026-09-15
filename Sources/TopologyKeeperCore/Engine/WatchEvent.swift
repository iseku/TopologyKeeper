import CoreAudio
import Foundation

/// 触发来源。
///
/// 之所以要区分：`ConflictPolicy.onConnectOnly`（"仅插拔/唤醒时恢复"）
/// 需要据此判断是否应该动作 —— 就地变更不算"接入"。
public enum TriggerKind: Equatable, Sendable {
    /// 设备列表变化（插入/拔出/唤醒时的设备重建）
    case deviceEvent
    /// 系统唤醒
    case systemWake
    /// 就地变更：格式或采样率被别的进程改掉
    case inPlaceChange
    /// 用户手动点击"立即应用"
    case manual
    /// 唤醒后的低频兜底轮询
    case poll

    public var displayText: String {
        switch self {
        case .deviceEvent:   return "设备事件"
        case .systemWake:    return "系统唤醒"
        case .inPlaceChange: return "就地变更"
        case .manual:        return "手动"
        case .poll:          return "轮询"
        }
    }

    /// 是否属于"接入类"触发（onConnectOnly 策略下允许动作的情形）
    public var isConnectLike: Bool {
        switch self {
        case .deviceEvent, .systemWake, .manual: return true
        case .inPlaceChange, .poll:              return false
        }
    }
}

/// DeviceWatcher 对外发出的事件
public enum WatchEvent: Equatable, Sendable {
    case devicesChanged(trigger: TriggerKind)
    case deviceAppeared(uid: String, deviceID: AudioDeviceID)
    case deviceDisappeared(uid: String)
    case nominalRateChanged(uid: String, deviceID: AudioDeviceID)
    case physicalFormatChanged(uid: String, streamID: AudioStreamID)
    case systemRestarted
    case woke
    case poll

    /// 映射到统一的触发类型
    public var trigger: TriggerKind {
        switch self {
        case .devicesChanged(let trigger):          return trigger
        case .deviceAppeared, .deviceDisappeared:   return .deviceEvent
        case .nominalRateChanged, .physicalFormatChanged: return .inPlaceChange
        case .systemRestarted:                      return .deviceEvent
        case .woke:                                 return .systemWake
        case .poll:                                 return .poll
        }
    }
}

/// 延迟执行器。
///
/// 抽出来是为了**可测试**：生产环境用 `audioQueue.asyncAfter`，
/// 测试里注入一个"立即执行"的实现，就能同步地验证防抖/抑制/退避逻辑，
/// 不必在测试里真的 sleep。
public typealias DelayedExecutor = @Sendable (Int, @escaping @Sendable () -> Void) -> Void

/// 真实实现：在指定串行队列上延迟执行。
public func makeQueueExecutor(_ queue: DispatchQueue) -> DelayedExecutor {
    { milliseconds, work in
        queue.asyncAfter(deadline: .now() + .milliseconds(milliseconds), execute: work)
    }
}

/// 测试实现：立即同步执行。
public let immediateExecutor: DelayedExecutor = { _, work in work() }

// MARK: - 抽象接口

/// 设备监听抽象（便于在测试里替换）
public protocol DeviceWatching: AnyObject, Sendable {
    var onEvent: (@Sendable (WatchEvent) -> Void)? { get set }
    func start()
    func stop()
    /// 立即重新注册监听器（设备重建后必须调用，见 D7）
    func rearm()
    /// 当前已 armed 的设备（诊断用）
    var armedDescription: String { get }
}

/// 睡眠/唤醒抽象
public protocol SleepWakeObserving: AnyObject, Sendable {
    var isSleeping: Bool { get }
    var onSleep: (@Sendable () -> Void)? { get set }
    var onWake: (@Sendable () -> Void)? { get set }
    func start()
    func stop()
}
