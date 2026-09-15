import Foundation

/// 失败分类。
///
/// 之所以分这么细：**两种静默失败模式的排查方向完全不同**
/// —— "设备被独占"要查别的工具，"落到错误格式"要查我们自己的 ASBD 构造。
/// 混在一起就没法诊断了。
public enum FailureKind: Equatable, Sendable {
    /// 写入返回 `noErr`，但回读发现**完全没变**。
    /// 典型原因：设备被其它工具独占（实测 SoundSource 会导致此现象）。
    case notEffective

    /// 写入返回 `noErr`，但**落到了另一个格式**。
    /// 典型原因：ASBD 构造错误（例如自己重算了 `mBytesPerFrame`）。
    case wrongFormat

    /// 声道/位深对了，但采样率没跟上（补设标称采样率也无效）。
    case sampleRateNotApplied

    /// 真实的 OSStatus 错误。
    case osStatus(Int32)

    /// 其它
    case unknown(String)

    public var displayText: String {
        switch self {
        case .notEffective:
            return "写入未生效（设备可能被其它应用占用）"
        case .wrongFormat:
            return "写入落到了错误格式（ASBD 构造异常）"
        case .sampleRateNotApplied:
            return "采样率未能应用"
        case .osStatus(let code):
            return "系统错误：OSStatus \(code)"
        case .unknown(let detail):
            return "未知错误：\(detail)"
        }
    }
}

/// 挂起原因
public enum SuspendReason: Equatable, Sendable {
    /// 系统正在睡眠 —— 实测此时设备以 `[2ch]` 状态存在 16 秒，不应动作
    case sleeping
    /// 用户手动暂停该规则
    case userPaused
    /// 连续冲突后进入退避，避免与其它工具互相争夺
    case conflictBackoff
    /// 规则策略为"仅插拔/唤醒时恢复"，而本次触发是就地变更
    case policyOnConnectOnly

    public var displayText: String {
        switch self {
        case .sleeping:             return "系统睡眠中"
        case .userPaused:           return "已暂停"
        case .conflictBackoff:      return "冲突退避中"
        case .policyOnConnectOnly:  return "仅插拔/唤醒时恢复"
        }
    }
}

/// 单条规则的运行时锁定状态。
///
/// ⚠️ 与只有 3 态的早期版本相比，这里**新增了两态**：
/// * `waitingForCapability` —— 唤醒后 0~28 秒内的**必经状态**（实测）。
///   没有它，用户会以为工具坏了。
/// * `applying` —— 正在写入。
public enum LockState: Equatable, Sendable {
    /// 该设备没有配置规则
    case noRule
    /// 规则存在但设备当前不在
    case deviceAbsent
    /// 设备在，但目标组合尚未出现在能力清单里 —— 等待，不写入
    case waitingForCapability(availableMaxChannels: UInt32)
    /// 已是目标格式
    case locked
    /// 正在写入
    case applying
    /// 写入失败
    case failed(FailureKind)
    /// 被挂起
    case suspended(SuspendReason)

    /// 菜单栏状态文案
    public var displayText: String {
        switch self {
        case .noRule:                    return "未配置"
        case .deviceAbsent:              return "未连接"
        case .waitingForCapability(let maxCh):
            return "等待设备就绪（当前最高 \(maxCh)ch）"
        case .locked:                    return "已锁定"
        case .applying:                  return "正在应用"
        case .failed(let kind):          return "失败：\(kind.displayText)"
        case .suspended(let reason):     return "挂起：\(reason.displayText)"
        }
    }

    /// SF Symbol 名（菜单栏与列表共用）。
    ///
    /// 按需求简化为**三个符号**：
    /// * 已锁定 → `waveform.badge.checkmark`
    /// * 失败   → `waveform.badge.xmark`
    /// * 其余（未配置 / 未连接 / 挂起 / 等待能力就绪 / 正在应用）→ `waveform.slash`
    ///
    /// 过渡态（等待能力就绪、正在应用）靠**颜色**区分（见 `statusTint`），
    /// 这样既保持三符号制，又不会把"正在努力"和"没在管"混为一谈。
    /// 三个符号均已在本机验证存在（SF Symbols）。
    public var iconName: String {
        switch self {
        case .locked: return "waveform.badge.checkmark"
        case .failed: return "waveform.badge.xmark"
        default:      return "waveform.slash"
        }
    }

    /// 着色语义。
    /// 放在 Core 里是为了让菜单栏与弹出面板用**同一套语义**，
    /// 同时避免 Core 依赖 AppKit。
    public enum Tint: Sendable, Equatable {
        /// 跟随菜单栏外观（模板图）
        case normal
        /// 橙：正在努力（等待设备就绪 / 正在应用）
        case inProgress
        /// 红：失败
        case critical
    }

    public var statusTint: Tint {
        switch self {
        case .failed:
            return .critical
        case .waitingForCapability, .applying:
            return .inProgress
        default:
            return .normal
        }
    }

    /// 聚合到菜单栏总状态时的优先级（数字越大越"需要注意"）
    public var severity: Int {
        switch self {
        case .locked, .noRule:      return 0
        case .deviceAbsent:         return 1
        case .suspended:            return 2
        case .waitingForCapability: return 3
        case .applying:             return 4
        case .failed:               return 5
        }
    }

    /// 是否处于"正在努力"的过程态（UI 可显示进度指示）
    public var isTransient: Bool {
        switch self {
        case .waitingForCapability, .applying: return true
        default: return false
        }
    }
}
