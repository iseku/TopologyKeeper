import AudioToolbox
import CoreAudio
import Foundation

/// 声道交换引擎的门面（`ChannelSwapEngineable` 的真实实现）。
///
/// 它把两件事装配起来：
/// * `ChannelSwapSupervisor` —— 决策与重试状态机（纯逻辑，可单测）
/// * `ChannelSwapAudioDriver` —— 真正的 AUHAL 数据通路
///
/// 之所以分三层而不是一个大类：状态机与硬件无关，能完整单测；
/// 而音频驱动受实时线程纪律约束、无法单测。分层后"何时重试/何时放弃"
/// 这类**业务正确性**不再依赖音频硬件。
public final class ChannelSwapEngine: ChannelSwapEngineable, @unchecked Sendable {

    private let supervisor: ChannelSwapSupervisor
    private let queue: DispatchQueue

    /// 状态变化回调（在 `queue` 上触发；UI 层负责 hop 到主线程）
    public var onStateChange: (@Sendable (ChannelSwapState) -> Void)? {
        get { supervisor.onStateChange }
        set { supervisor.onStateChange = newValue }
    }

    public init(queue: DispatchQueue,
                resolver: ChannelSwapDeviceResolving = CoreAudioChannelSwapResolver(),
                audio: ChannelSwapAudioDriving = ChannelSwapAudioDriver(),
                executor: DelayedExecutor? = nil,
                notifier: (@Sendable (String) -> Void)? = nil) {
        self.queue = queue
        self.supervisor = ChannelSwapSupervisor(resolver: resolver,
                                               audio: audio,
                                               queue: queue,
                                               executor: executor,
                                               notifier: notifier)
    }

    public var state: ChannelSwapState { supervisor.state }

    public func apply(_ settings: ChannelSwapSettings,
                      configProvider: @escaping @Sendable () -> AppConfig) {
        supervisor.apply(settings)
    }

    public func stop() { supervisor.stop() }

    public func diagnostics() -> ChannelSwapDiagnostics { supervisor.diagnostics() }

    /// 设备列表变化（插入/拔出/重建/唤醒/音频服务重启）时调用。
    ///
    /// 与 `RuleEngine` 无关：声道交换有自己的重试节奏，
    /// 这里只是"有新情况了，重新评估一次"的信号。
    /// 幂等：解析出的设备与当前通路绑定的完全一致时不会重新装配。
    public func devicesChanged() { supervisor.devicesChanged() }

    /// 设备**被销毁**（消失/重建前）时调用 —— 强制重建通路。
    ///
    /// 依据（D7）：`AudioDeviceID` 每次重建都会变，绑定它的 AUHAL 单元随之失效。
    public func devicesDisappeared() { supervisor.devicesDisappeared() }
}
