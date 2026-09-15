import Foundation

/// 某条规则的运行时快照，供 UI 展示。
///
/// 刻意同时包含 **预设值** 与 **当前值** ——
/// 因为实测证明写入可能静默失败，
/// 只显示"当前格式"的话用户无法判断锁定到底有没有生效。
public struct RuleSnapshot: Equatable, Sendable, Identifiable {

    public let ruleID: UUID
    public var id: UUID { ruleID }

    /// 用户给设备起的名字（规则里存的）
    public let deviceName: String
    public let transportName: String

    /// 设备当前是否在场
    public let devicePresent: Bool
    /// 是否走了"名称+传输类型"兜底匹配（UID 可能因换端口而变）
    public let matchedViaFallback: Bool

    public let state: LockState
    public let conflictPolicy: ConflictPolicy
    public let isEnabled: Bool

    /// 预设格式
    public let preset: AudioFormatPreset
    /// 设备当前实际格式（可能为 nil = 读不到）
    public let currentFormat: AudioFormatPreset?

    /// 设备当前能力摘要
    public let capabilitySummary: String
    public let capabilityMaxChannels: UInt32
    public let capabilityCombinationCount: Int

    // 运行时诊断
    public let lastAppliedAt: Date?
    public let lastError: String?
    public let consecutiveFailures: Int

    public init(ruleID: UUID,
                deviceName: String,
                transportName: String,
                devicePresent: Bool,
                matchedViaFallback: Bool,
                state: LockState,
                conflictPolicy: ConflictPolicy,
                isEnabled: Bool,
                preset: AudioFormatPreset,
                currentFormat: AudioFormatPreset?,
                capabilitySummary: String,
                capabilityMaxChannels: UInt32,
                capabilityCombinationCount: Int,
                lastAppliedAt: Date?,
                lastError: String?,
                consecutiveFailures: Int) {
        self.ruleID = ruleID
        self.deviceName = deviceName
        self.transportName = transportName
        self.devicePresent = devicePresent
        self.matchedViaFallback = matchedViaFallback
        self.state = state
        self.conflictPolicy = conflictPolicy
        self.isEnabled = isEnabled
        self.preset = preset
        self.currentFormat = currentFormat
        self.capabilitySummary = capabilitySummary
        self.capabilityMaxChannels = capabilityMaxChannels
        self.capabilityCombinationCount = capabilityCombinationCount
        self.lastAppliedAt = lastAppliedAt
        self.lastError = lastError
        self.consecutiveFailures = consecutiveFailures
    }

    /// 预设与当前是否一致（UI 差异高亮用）
    public var isFormatMatching: Bool {
        guard let currentFormat else { return false }
        return currentFormat.channelCount == preset.channelCount
            && currentFormat.bitDepth == preset.bitDepth
            && AudioFormatPreset.ratesEqual(currentFormat.sampleRate, preset.sampleRate)
    }

    /// 菜单栏展示用
    public var currentFormatText: String {
        currentFormat?.displayString ?? "未知"
    }
}
