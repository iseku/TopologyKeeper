import Foundation

/// 把多条规则的快照聚合为**菜单栏总状态**。
///
/// 抽成纯函数放在 Core 里，是为了让这段逻辑可以脱离 AppKit 单测 ——
/// 它决定了菜单栏图标，写错用户会直接看到。
public enum LockStateAggregator {

    /// 聚合规则：
    /// 1. **没有规则，或全部规则被停用 → "未启用锁定"**（图标 `waveform.slash`）。
    ///    这是用户的明确动作，必须立即反映，不能按"设备当前是否恰好是目标格式"来判定。
    /// 2. 否则取**最需要注意**的那条（按 `severity`）。
    ///
    /// ⚠️ 踩过的 bug：原先只看 `snapshots` 是否为空、并让停用规则沿用旧状态，
    /// 结果"关掉全部锁定后图标不变、必须重启"。
    public static func aggregate(_ snapshots: [RuleSnapshot]) -> LockState {
        let enabled = snapshots.filter(\.isEnabled)
        guard !enabled.isEmpty else { return .noRule }
        return enabled.max { $0.state.severity < $1.state.severity }?.state ?? .noRule
    }

    /// 菜单栏 tooltip 用的摘要文案
    public static func summary(_ snapshots: [RuleSnapshot]) -> String {
        guard !snapshots.isEmpty else { return "未配置设备规则" }

        let enabled = snapshots.filter(\.isEnabled)
        guard !enabled.isEmpty else {
            return snapshots.count == 1
                ? "锁定未启用（规则已停用）"
                : "锁定未启用（\(snapshots.count) 条规则均已停用）"
        }

        if enabled.count == 1 { return enabled[0].state.displayText }
        let worst = aggregate(snapshots)
        return "\(enabled.count) 台设备 · \(worst.displayText)"
    }

    /// 是否所有规则都处于停用状态（UI 可据此给出更明确提示）
    public static func allDisabled(_ snapshots: [RuleSnapshot]) -> Bool {
        !snapshots.isEmpty && snapshots.allSatisfy { !$0.isEnabled }
    }
}
