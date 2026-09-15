import CoreAudio
import Foundation

/// `FormatApplier.apply` 的结果。
///
/// 每个 case 对应一种**明确不同的处理方式**（《详细设计.md》§8）。
/// 特别重要的是把"没生效"和"落到错误格式"分开 ——
/// 两者都返回 `noErr`，但排查方向完全不同（可行性分析 §2.2）。
public enum ApplyOutcome: Equatable, Sendable {

    /// 写入成功且回读校验通过
    case applied

    /// 目标组合当前不在能力清单里 —— **不算失败**，应等待（D9）
    case capabilityNotReady(availableMaxChannels: UInt32)

    /// 设备没有输出流
    case noOutputStreams

    /// F3：返回 `noErr` 但**完全没变**（多为设备被其它工具独占）
    case notEffective(before: AudioStreamBasicDescription, after: AudioStreamBasicDescription)

    /// F4：返回 `noErr` 但落到了**另一个格式**（多为 ASBD 构造问题）
    case wrongFormat(wanted: AudioStreamBasicDescription, got: AudioStreamBasicDescription)

    /// F5：声道/位深对，但采样率补设后仍未生效
    case sampleRateNotApplied(wanted: Double, got: Double)

    /// F7：真实 OSStatus 错误
    case osStatus(Int32)

    public var isSuccess: Bool {
        if case .applied = self { return true }
        return false
    }

    /// 是否应该"什么都不做，等下一次事件"
    public var shouldWait: Bool {
        if case .capabilityNotReady = self { return true }
        return false
    }

    /// 映射到 UI 失败分类（成功与等待态返回 nil）
    public var failureKind: FailureKind? {
        switch self {
        case .applied, .capabilityNotReady:
            return nil
        case .noOutputStreams:
            return .unknown("设备没有输出流")
        case .notEffective:
            return .notEffective
        case .wrongFormat:
            return .wrongFormat
        case .sampleRateNotApplied:
            return .sampleRateNotApplied
        case .osStatus(let code):
            return .osStatus(code)
        }
    }

    /// 日志用描述。
    ///
    /// ⚠️ 这里**不放任何符号/颜文字**（用户要求）：结果好坏已经由日志级别
    /// （INF / WRN / ERR）和 `failureKind` 表达，正文只需要说清"到底发生了什么"。
    /// 曾经用 ✅/❌/⏳ 开头，与日志级别重复，且纯文本导出、grep 时碍事。
    public var logDescription: String {
        switch self {
        case .applied:
            return "已应用并通过回读校验"
        case .capabilityNotReady(let maxCh):
            return "目标组合尚不可用（当前最高 \(maxCh)ch），等待设备就绪"
        case .noOutputStreams:
            return "设备没有输出流"
        case .notEffective(let before, let after):
            return "写入未生效（模式 A）：期望前 \(CoreAudioHelpers.describeShort(before)) "
                 + "→ 回读仍为 \(CoreAudioHelpers.describeShort(after))"
        case .wrongFormat(let wanted, let got):
            return "落到错误格式（模式 B）：期望 \(CoreAudioHelpers.describeShort(wanted)) "
                 + "→ 回读 \(CoreAudioHelpers.describeShort(got))"
        case .sampleRateNotApplied(let wanted, let got):
            return "采样率未应用：期望 \(AudioFormatPreset.rateString(wanted))Hz "
                 + "→ 回读 \(AudioFormatPreset.rateString(got))Hz"
        case .osStatus(let code):
            return "系统错误：\(CoreAudioHelpers.describe(code))"
        }
    }
}

// MARK: - Equatable

// `AudioStreamBasicDescription` 是 C 结构体，没有 Equatable 合成，
// 因此这里手写比较（只比较我们关心的字段，与 matchesCurrent 的语义保持一致）。
extension ApplyOutcome {
    public static func == (lhs: ApplyOutcome, rhs: ApplyOutcome) -> Bool {
        switch (lhs, rhs) {
        case (.applied, .applied),
             (.noOutputStreams, .noOutputStreams):
            return true
        case let (.capabilityNotReady(a), .capabilityNotReady(b)):
            return a == b
        case let (.osStatus(a), .osStatus(b)):
            return a == b
        case let (.notEffective(lb, la), .notEffective(rb, ra)):
            return asbdEqual(lb, rb) && asbdEqual(la, ra)
        case let (.wrongFormat(lw, lg), .wrongFormat(rw, rg)):
            return asbdEqual(lw, rw) && asbdEqual(lg, rg)
        case let (.sampleRateNotApplied(lw, lg), .sampleRateNotApplied(rw, rg)):
            return AudioFormatPreset.ratesEqual(lw, rw) && AudioFormatPreset.ratesEqual(lg, rg)
        default:
            return false
        }
    }

    private static func asbdEqual(_ a: AudioStreamBasicDescription,
                                  _ b: AudioStreamBasicDescription) -> Bool {
        a.mChannelsPerFrame == b.mChannelsPerFrame
            && a.mBitsPerChannel == b.mBitsPerChannel
            && a.mFormatFlags == b.mFormatFlags
            && a.mBytesPerFrame == b.mBytesPerFrame
            && a.mBytesPerPacket == b.mBytesPerPacket
            && a.mFramesPerPacket == b.mFramesPerPacket
            && AudioFormatPreset.ratesEqual(a.mSampleRate, b.mSampleRate)
    }
}
