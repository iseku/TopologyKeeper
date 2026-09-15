import CoreAudio
import Foundation

/// 声道交换计划 —— **纯逻辑**，不碰任何硬件，可完整单测。
///
/// 背景：
/// AUHAL 的 `kAudioOutputUnitProperty_ChannelMap` 接受 `map[dst] = src`
/// 形式的**任意置换**（SDK `AudioUnitProperties.h:2437`），-1 表示该目标声道静音。
/// 因此"交换中置与低音"就是 `map[2] = 3; map[3] = 2`，
/// **不需要自己写实时回调搬样本** —— 交给 HAL/AUConverter 完成。
///
/// 本类型只负责"算出那张映射表"，以及回答"这台设备能不能做"。
/// 实际写入由 `Audio/ChannelSwapEngine` 负责（唯一出 CoreAudio 的地方）。
///
/// ## ⚠️ 声道编号规范（对外一律 1-based）
///
/// CoreAudio / HDMI 的**标准布局**（下表用 1-based 表述，与
/// 「音频MIDI设置」和电视/功放的 UI 一致）：
///
/// | 声道号 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 |
/// |--------|---|---|---|---|---|---|---|---|
/// | 语义   | L | R | **C** | **LFE** | Ls | Rs | Lrs | Rrs |
///
/// 因此 **只要声道数 ≥ 6，第 3/4 声道恒为 C/LFE**，与 6ch(5.1) 还是 8ch(7.1) 无关
/// —— 这是"≥6 声道"这个前置条件的由来（用户确认）。
///
/// **约定（用户要求）**：
/// * 所有**对外展示**（UI、日志、文档、诊断输出）一律用 **1-based**（第 1…8 声道）；
/// * 仅在与 CoreAudio API 交互时转换为 **0-based**，且转换只发生在
///   `swapMap` / `apiIndex(forChannel:)` 两处 —— 不要在别处自行 ±1。
public struct ChannelSwapPlan: Equatable, Sendable {

    /// 源设备（BlackHole）要取的声道数 = 目标设备声道数（"取前 N"）
    public let sourceChannelCount: Int

    /// 交换的两个声道（**对外 1-based**）。默认中置(3) ↔ 低音(4)
    public let firstChannel: Int
    public let secondChannel: Int

    /// 目标设备做声道交换所需的最小声道数。
    ///
    /// 依据：5.1/7.1 布局下 C=3、LFE=4（1-based），
    /// 而用户的筛选条件是 **≥6**（真正的 5.1 起步），故取 6。
    public static let minimumChannelCount = 6

    /// 默认交换对：中置 ↔ 低音（1-based 第 3 / 第 4 声道）
    public static let defaultFirstChannel = 3
    public static let defaultSecondChannel = 4

    /// 对外 1-based 声道号 → CoreAudio 的 0-based 索引。**唯一**的转换点。
    public static func apiIndex(forChannel channel: Int) -> Int { channel - 1 }

    /// CoreAudio 的 0-based 索引 → 对外 1-based 声道号。**唯一**的转换点。
    public static func channelNumber(forAPIIndex index: Int) -> Int { index + 1 }

    public init(sourceChannelCount: Int,
                firstChannel: Int = ChannelSwapPlan.defaultFirstChannel,
                secondChannel: Int = ChannelSwapPlan.defaultSecondChannel) {
        self.sourceChannelCount = sourceChannelCount
        self.firstChannel = firstChannel
        self.secondChannel = secondChannel
    }

    // MARK: - 生成映射

    /// 生成 AUHAL `kAudioOutputUnitProperty_ChannelMap` 用的映射表。
    ///
    /// 语义：`map[dst] = src`（**API 用 0-based 索引**），
    /// 即"目标第 dst 声道取源的第 map[dst] 声道"。
    /// 默认是恒等映射（`[0,1,2,…,N-1]`，即"取源的前 N 声道"），再把两处互换。
    ///
    /// **返回 nil 表示这台设备根本做不了**：
    /// * 声道数 < `minimumChannelCount`（产品规则：少于 6 声道不做交换）
    /// * 两个声道号越界，或指向同一个声道
    public var swapMap: [Int32]? {
        let n = sourceChannelCount
        guard n >= Self.minimumChannelCount else { return nil }
        // 对外是 1-based，转成 API 索引后校验
        let a = Self.apiIndex(forChannel: firstChannel)
        let b = Self.apiIndex(forChannel: secondChannel)
        guard a >= 0, b >= 0, a < n, b < n else { return nil }

        // ★ `firstChannel == secondChannel` = **显式声明"不交换"**，返回恒等映射。
        //
        //   为什么不是 nil：nil 的语义是"这台设备做不了"（声道数不足/越界），
        //   会被驱动当成错误拒绝启动。而"我不交换，但通路照跑"是一个**合法需求** ——
        //   混音与交换互斥但共用同一条通路，只开混音时就需要这种恒等计划。
        //   （早先这里对 a == b 返回 nil，导致"只开混音"无法表达成恒等计划。）
        guard a != b else { return (0..<n).map { Int32($0) } }

        var map = (0..<n).map { Int32($0) }
        map[a] = Int32(b)
        map[b] = Int32(a)
        return map
    }

    /// 目标声道（**对外 1-based**）对应源声道（1-based）。可读性用。
    public func sourceChannel(forDestination channel: Int) -> Int? {
        guard channel >= 1, channel <= sourceChannelCount else { return nil }
        if channel == firstChannel { return secondChannel }
        if channel == secondChannel { return firstChannel }
        return channel
    }

    // MARK: - 可行性判定

    /// 给定目标设备的输出声道数，这台设备能否做声道交换。
    public static func canSwap(onDeviceWithChannels channels: Int) -> Bool {
        channels >= minimumChannelCount
    }

    /// 不可行时的原因说明（UI 直接展示，声道号 1-based）
    public static func unavailableReason(channels: Int) -> String {
        "目标设备当前 \(channels) 声道，少于 \(minimumChannelCount) 声道 —— "
            + "不存在第 \(defaultFirstChannel) 声道与第 \(defaultSecondChannel) 声道"
            + "（中置/低音），无法交换"
    }

    /// 是否为恒等映射（没做任何交换）—— 诊断用
    public var isIdentity: Bool {
        guard let map = swapMap else { return true }
        return map.enumerated().allSatisfy { Int32($0.offset) == $0.element }
    }

    /// 声道语义名。**参数为对外 1-based 声道号**（1=L … 4=LFE …）
    public static func semanticName(forChannel channel: Int) -> String? {
        switch channel {
        case 1: return "左"
        case 2: return "右"
        case 3: return "中置"
        case 4: return "低音"
        case 5: return "左环绕"
        case 6: return "右环绕"
        case 7: return "左后环绕"
        case 8: return "右后环绕"
        default: return nil
        }
    }

    /// 例 "中置(第3声道) ↔ 低音(第4声道)"。
    ///
    /// ⚠️ 恒等计划（`isIdentity`）**必须明说"不交换"**。
    /// 只开混音时交换是恒等的，而恒等计划是用 `first == second == 1` 构造的
    /// （见 `ChannelSwapSettings.plan(identityWhenDisabled:)`），
    /// 先前这里会输出 **"左(第1声道) ↔ 左(第1声道)"** ——
    /// 读起来像"把第 1 声道与它自己交换"，是个不成立的说法，
    /// 而且它会出现在启动日志里，直接误导排查。
    public var swapDescription: String {
        guard !isIdentity else { return "不交换" }
        let a = Self.semanticName(forChannel: firstChannel) ?? "第\(firstChannel)声道"
        let b = Self.semanticName(forChannel: secondChannel) ?? "第\(secondChannel)声道"
        return "\(a)(第\(firstChannel)声道) ↔ \(b)(第\(secondChannel)声道)"
    }
}
