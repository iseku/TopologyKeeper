import CoreAudio
import Foundation

/// 冲突策略。
///
/// 默认 `enforceAlways`（2025-09 决策）：
/// 本工具的定位是**取代 SoundSource 的采样率锁定**
/// —— 后者此前用于对抗"采样率自动跳到 192k"。
/// 因此需要**持续维持**，而不只是插拔/唤醒时恢复一次。
///
/// 若将来同时运行其它会锁定格式的工具，会与它持续争夺；
/// 此时实测争夺失败方会**静默失败**（模式 A），
/// 因此保留 `onConnectOnly` 与 `paused` 作为降级选项。
public enum ConflictPolicy: String, Codable, CaseIterable, Sendable {
    /// 任何时候发现格式不符就改回来（默认）
    case enforceAlways
    /// 仅在设备接入 / 系统唤醒时恢复一次，之后不再干预
    case onConnectOnly
    /// 暂停该规则
    case paused

    public var displayText: String {
        switch self {
        case .enforceAlways: return "持续强制锁定（推荐）"
        case .onConnectOnly: return "仅插拔/唤醒时恢复"
        case .paused:        return "暂停"
        }
    }

    public var explanation: String {
        switch self {
        case .enforceAlways:
            return "任何时候发现格式被改掉都会改回来。若同时运行 SoundSource 等会锁定格式的工具，两者会互相争夺。"
        case .onConnectOnly:
            return "只在设备接入或系统唤醒时恢复一次。适合想避免与其它工具争夺的场景。"
        case .paused:
            return "该规则不生效，但仍保留配置。"
        }
    }

    /// 界面上**允许选择**的策略。
    ///
    /// 刻意不含 `paused`：它与「启用」开关语义重复 —— 两者都让规则不动作，
    /// 却多出一层心智负担（用户实测反馈"看不懂它有什么用"）。
    /// 需要"暂时不生效"时，直接用「启用」开关即可。
    ///
    /// ⚠️ 枚举值本身**必须保留**：旧配置里可能已存有 `paused`，
    /// 删掉这个 case 会导致 JSON 解码失败、整份配置读不出来。
    /// UI 只在加载到旧 `paused` 规则时把它迁移成「未启用 + 持续锁定」。
    public static var selectable: [ConflictPolicy] { [.enforceAlways, .onConnectOnly] }
}

/// 设备规则。
public struct DeviceRule: Codable, Identifiable, Equatable, Sendable {

    public var id: UUID
    public var isEnabled: Bool

    // MARK: 设备识别

    /// 主匹配键。实测跨唤醒/拔插保持稳定
    public var deviceUID: String
    /// 展示用，兼作 UID 失效时的兜底匹配
    public var deviceName: String
    /// 兜底匹配用（HDMI / USB / …）
    public var transportType: UInt32
    /// 端口线索。HDMI 的 UID 疑似由 EDID/端口派生，**换端口可能变**，
    /// 届时用名称+端口引导用户重新绑定
    public var portHint: String?

    // MARK: 目标格式

    /// 完整 ASBD 语义
    public var preset: AudioFormatPreset

    // MARK: 行为

    /// 冲突策略，默认持续锁定
    public var conflictPolicy: ConflictPolicy
    /// 强制回读校验。**不建议关闭** —— `noErr` 不可信
    public var verifyAfterApply: Bool

    // MARK: 运行时诊断（持久化以便排查）

    public var lastAppliedAt: Date?
    public var lastError: String?
    public var consecutiveFailures: Int

    public init(id: UUID = UUID(),
                isEnabled: Bool = true,
                deviceUID: String,
                deviceName: String,
                transportType: UInt32,
                portHint: String? = nil,
                preset: AudioFormatPreset,
                conflictPolicy: ConflictPolicy = .enforceAlways,
                verifyAfterApply: Bool = true,
                lastAppliedAt: Date? = nil,
                lastError: String? = nil,
                consecutiveFailures: Int = 0) {
        self.id = id
        self.isEnabled = isEnabled
        self.deviceUID = deviceUID
        self.deviceName = deviceName
        self.transportType = transportType
        self.portHint = portHint
        self.preset = preset
        self.conflictPolicy = conflictPolicy
        self.verifyAfterApply = verifyAfterApply
        self.lastAppliedAt = lastAppliedAt
        self.lastError = lastError
        self.consecutiveFailures = consecutiveFailures
    }
}

extension DeviceRule {
    /// 设备是否匹配本规则。
    ///
    /// 优先 UID（实测稳定）；UID 不匹配时按 名称+传输类型 兜底，
    /// 以便 UID 因换端口而变化时仍能识别。
    public func matches(_ descriptor: DeviceDescriptor) -> Bool {
        if descriptor.uid == deviceUID { return true }
        // 兜底：UID 变了但看起来仍是同一台设备
        return descriptor.name == deviceName && descriptor.transportType == transportType
    }

    /// 是否走了兜底匹配（UI 可提示用户"设备标识已变化，建议重新绑定"）
    public func matchedViaFallback(_ descriptor: DeviceDescriptor) -> Bool {
        descriptor.uid != deviceUID && matches(descriptor)
    }
}
