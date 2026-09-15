import Foundation

/// 写入抑制 / 失败退避 / 冲突保护。
///
/// 两件事：
///
/// 1. **自身写入抑制**：我们的写入会触发 `physicalFormat` / `virtualFormat` /
///    `nominalSampleRate` 监听器（实测一次写入触发 6 次事件，HAL 两阶段提交）。
///    不抑制就会自己响应自己，造成重复写入。
///    注意：这是为了防**自触发**，不是为了防死循环（该风险已排除）。
///
/// 2. **冲突退避**：若另一个工具也在锁定同一设备的格式，两者会互相争夺，
///    且**失败方会静默失败**（实测 SoundSource 会导致此现象）。
///    连续失败达阈值后暂停一段时间，避免无意义的持续抢占。
public final class ApplyPolicy: @unchecked Sendable {

    private let configProvider: @Sendable () -> AppConfig
    private let now: @Sendable () -> Date

    private var lastAppliedAt: [UUID: Date] = [:]
    private var consecutiveFailures: [UUID: Int] = [:]
    private var backoffUntil: [UUID: Date] = [:]
    /// 每次成功应用的时刻（滑动窗口，用于抖动检测）
    private var applyTimestamps: [UUID: [Date]] = [:]

    public init(config: @escaping @Sendable () -> AppConfig,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.configProvider = config
        self.now = now
    }

    // MARK: - 自身写入抑制

    /// 是否处于自身写入抑制窗口内
    public func isSuppressed(_ ruleID: UUID) -> Bool {
        guard let appliedAt = lastAppliedAt[ruleID] else { return false }
        let elapsedMs = now().timeIntervalSince(appliedAt) * 1000
        return elapsedMs < Double(configProvider().selfWriteSuppressMs)
    }

    /// 记录一次成功写入，开启抑制窗口并清空失败计数。
    ///
    /// ★ 同时做**抖动检测**：如果短时间内反复"成功写入"，
    /// 说明有另一个工具在把格式改回去（双方的目标不同）。
    /// 这种情况下连续失败计数永远是 0，必须靠应用频率才能识别。
    ///
    /// - Returns: 本次是否**触发了**抖动退避
    @discardableResult
    public func markApplied(_ ruleID: UUID) -> Bool {
        let timestamp = now()
        lastAppliedAt[ruleID] = timestamp
        consecutiveFailures[ruleID] = 0

        let config = configProvider()
        let cutoff = timestamp.addingTimeInterval(-Double(config.thrashWindowMs) / 1000)
        var stamps = (applyTimestamps[ruleID] ?? []).filter { $0 >= cutoff }
        stamps.append(timestamp)

        if stamps.count >= config.thrashThreshold {
            backoffUntil[ruleID] = timestamp.addingTimeInterval(Double(config.conflictBackoffMs) / 1000)
            applyTimestamps[ruleID] = []
            Log.warn("检测到格式抖动：\(config.thrashWindowMs / 1000) 秒内已应用 \(stamps.count) 次。"
                     + "判定为有其它应用在争夺同一设备，退避 \(config.conflictBackoffMs / 1000) 秒。")
            return true
        }

        applyTimestamps[ruleID] = stamps
        backoffUntil[ruleID] = nil
        return false
    }

    /// 窗口内最近一次统计到的应用次数（诊断用）
    public func recentApplyCount(_ ruleID: UUID, windowMs: Int) -> Int {
        let cutoff = now().addingTimeInterval(-Double(windowMs) / 1000)
        return (applyTimestamps[ruleID] ?? []).filter { $0 >= cutoff }.count
    }

    /// 记录一次真实写入尝试（无论成败）。用于诊断。
    public func lastAppliedDate(_ ruleID: UUID) -> Date? {
        lastAppliedAt[ruleID]
    }

    // MARK: - 失败与退避

    public func failureCount(_ ruleID: UUID) -> Int {
        consecutiveFailures[ruleID] ?? 0
    }

    /// 记录一次失败。
    /// - Returns: 本次是否**触发了**冲突退避
    @discardableResult
    public func markFailure(_ ruleID: UUID) -> Bool {
        let count = (consecutiveFailures[ruleID] ?? 0) + 1
        consecutiveFailures[ruleID] = count

        let config = configProvider()
        guard count >= config.conflictBackoffThreshold else { return false }

        backoffUntil[ruleID] = now().addingTimeInterval(Double(config.conflictBackoffMs) / 1000)
        consecutiveFailures[ruleID] = 0
        Log.warn("连续失败 \(count) 次，判定为与其它应用争夺设备；"
                 + "进入退避 \(config.conflictBackoffMs / 1000) 秒")
        return true
    }

    public func isInBackoff(_ ruleID: UUID) -> Bool {
        guard let until = backoffUntil[ruleID] else { return false }
        if now() >= until {
            backoffUntil[ruleID] = nil
            return false
        }
        return true
    }

    /// 能力未就绪 / 已是目标格式：清空失败计数（这不是冲突）
    public func resetFailures(_ ruleID: UUID) {
        consecutiveFailures[ruleID] = 0
    }

    /// 清除退避（用户手动"立即应用"时调用）。
    ///
    /// 理由：退避是"系统自动判断此时不该抢占"，
    /// 而用户按下按钮就是明确的下一次尝试指令，应当覆盖它。
    public func clearBackoff(_ ruleID: UUID) {
        backoffUntil[ruleID] = nil
        consecutiveFailures[ruleID] = 0
        applyTimestamps[ruleID] = []
    }

    // MARK: - 会话重置

    /// 唤醒或音频服务重启后调用。
    /// 清掉退避与失败计数（换了新会话，旧的冲突判定不再有效），
    /// 但**保留**抑制窗口的起点也没意义 —— 一并清掉。
    public func resetForNewSession() {
        consecutiveFailures.removeAll()
        backoffUntil.removeAll()
        lastAppliedAt.removeAll()
        applyTimestamps.removeAll()
        Log.debug("ApplyPolicy：会话重置（退避/失败/抑制窗口已清空）")
    }
}
