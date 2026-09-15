import Foundation

/// 全部行为参数（《详细设计.md》附录 B）。
/// 每个默认值都有实测依据，改动前请先看依据。
public struct AppConfig: Codable, Equatable, Sendable {

    /// 配置结构版本，便于将来迁移
    public var version: Int

    public var rules: [DeviceRule]

    /// 声道交换（**全局功能，与 rules 平级**）。
    ///
    /// 依据（用户确认，2026-09）：交换与"输出格式锁定"是解耦的两个功能，
    /// 需要交换的设备不一定需要锁定，因此做成独立的全局开关，
    /// 由独立的 `ChannelSwapEngine` 驱动（与 `RuleEngine` 零交互）。
    public var channelSwap: ChannelSwapSettings

    // MARK: 通用开关

    public var launchAtLogin: Bool
    public var showNotifications: Bool
    public var recordLogToFile: Bool

    // MARK: 行为参数

    /// 设备事件防抖窗口。
    /// 依据：实测 `devices-list` 会在 ~0.5s 内密集触发多次（§2.12 单次唤醒触发 8 次）
    public var eventDebounceMs: Int

    /// 自身写入抑制窗口。
    /// 依据：实测一次写入会触发 `physicalFormat`/`virtualFormat`/`nominalSampleRate`
    /// 各 2 次（HAL 两阶段提交），回声在 ~400ms 内出现（§2.7）。
    /// 注意：此窗口是为了防**自触发**，不是为了防死循环（R1 已排除）。
    public var selfWriteSuppressMs: Int

    /// 写入失败后的重试退避序列
    public var applyRetryBackoffMs: [Int]

    /// 连续失败多少次判定为"被其它工具争夺"
    public var conflictBackoffThreshold: Int

    /// 抖动检测窗口。
    ///
    /// 为什么需要它：连续失败判据**检测不到"写入成功但立刻被改回"这种争夺**。
    /// 两个工具各有不同目标格式时会互相覆盖，而每次写入的**回读校验都是通过的**，
    /// 于是失败计数永远是 0，双方无限 ping-pong。
    /// 因此额外用"单位时间内的应用次数"来识别抖动。
    public var thrashWindowMs: Int

    /// 窗口内应用次数达到该值即判定为抖动
    public var thrashThreshold: Int

    /// 退避时长
    public var conflictBackoffMs: Int

    /// 唤醒后的低频兜底轮询间隔。
    /// 依据：能力到位**总是**伴随设备重建（实测能力监听器从不触发），
    /// 但万一有例外，用低频轮询兜底（§2.12 / D6）
    public var postWakePollIntervalMs: Int

    /// 唤醒后轮询持续时间。
    /// 依据：实测能力到位耗时 19.0s / 28.0s，取 60s 留足余量（§2.12）
    public var postWakePollDurationMs: Int

    /// UI 日志环形缓冲容量
    public var logRingCapacity: Int

    public init(version: Int = AppConfig.currentVersion,
                rules: [DeviceRule] = [],
                channelSwap: ChannelSwapSettings = ChannelSwapSettings(),
                launchAtLogin: Bool = false,
                showNotifications: Bool = true,
                recordLogToFile: Bool = false,
                eventDebounceMs: Int = 300,
                selfWriteSuppressMs: Int = 3000,
                applyRetryBackoffMs: [Int] = [500, 1000, 2000],
                conflictBackoffThreshold: Int = 5,
                thrashWindowMs: Int = 60_000,
                thrashThreshold: Int = 8,
                conflictBackoffMs: Int = 60_000,
                postWakePollIntervalMs: Int = 2000,
                postWakePollDurationMs: Int = 60_000,
                logRingCapacity: Int = 500) {
        self.version = version
        self.rules = rules
        self.channelSwap = channelSwap
        self.launchAtLogin = launchAtLogin
        self.showNotifications = showNotifications
        self.recordLogToFile = recordLogToFile
        self.eventDebounceMs = eventDebounceMs
        self.selfWriteSuppressMs = selfWriteSuppressMs
        self.applyRetryBackoffMs = applyRetryBackoffMs
        self.conflictBackoffThreshold = conflictBackoffThreshold
        self.thrashWindowMs = thrashWindowMs
        self.thrashThreshold = thrashThreshold
        self.conflictBackoffMs = conflictBackoffMs
        self.postWakePollIntervalMs = postWakePollIntervalMs
        self.postWakePollDurationMs = postWakePollDurationMs
        self.logRingCapacity = logRingCapacity
    }

    public static let currentVersion = 1
}

// MARK: - 容错解码

extension AppConfig {
    /// 宽松解码：新增字段缺失时回落到默认值，避免升级后配置读取失败。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppConfig()
        self.version = (try? c.decode(Int.self, forKey: .version)) ?? d.version
        self.rules = (try? c.decode([DeviceRule].self, forKey: .rules)) ?? d.rules
        // ★ 新增字段必须走宽松解码，否则升级后整份配置读取失败
        self.channelSwap = (try? c.decode(ChannelSwapSettings.self, forKey: .channelSwap))
            ?? d.channelSwap
        self.launchAtLogin = (try? c.decode(Bool.self, forKey: .launchAtLogin)) ?? d.launchAtLogin
        self.showNotifications = (try? c.decode(Bool.self, forKey: .showNotifications)) ?? d.showNotifications
        self.recordLogToFile = (try? c.decode(Bool.self, forKey: .recordLogToFile)) ?? d.recordLogToFile
        self.eventDebounceMs = (try? c.decode(Int.self, forKey: .eventDebounceMs)) ?? d.eventDebounceMs
        self.selfWriteSuppressMs = (try? c.decode(Int.self, forKey: .selfWriteSuppressMs)) ?? d.selfWriteSuppressMs
        self.applyRetryBackoffMs = (try? c.decode([Int].self, forKey: .applyRetryBackoffMs)) ?? d.applyRetryBackoffMs
        self.conflictBackoffThreshold = (try? c.decode(Int.self, forKey: .conflictBackoffThreshold)) ?? d.conflictBackoffThreshold
        self.thrashWindowMs = (try? c.decode(Int.self, forKey: .thrashWindowMs)) ?? d.thrashWindowMs
        self.thrashThreshold = (try? c.decode(Int.self, forKey: .thrashThreshold)) ?? d.thrashThreshold
        self.conflictBackoffMs = (try? c.decode(Int.self, forKey: .conflictBackoffMs)) ?? d.conflictBackoffMs
        self.postWakePollIntervalMs = (try? c.decode(Int.self, forKey: .postWakePollIntervalMs)) ?? d.postWakePollIntervalMs
        self.postWakePollDurationMs = (try? c.decode(Int.self, forKey: .postWakePollDurationMs)) ?? d.postWakePollDurationMs
        self.logRingCapacity = (try? c.decode(Int.self, forKey: .logRingCapacity)) ?? d.logRingCapacity
    }
}
