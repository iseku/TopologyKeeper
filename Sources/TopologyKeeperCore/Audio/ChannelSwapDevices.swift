import CoreAudio
import Foundation

/// 音频设备解析边界（让 `ChannelSwapSupervisor` 可以脱离硬件单测）。
///
/// 与 `CoreAudioServiceProtocol` 的关系：那个是**格式锁定**用的 HAL 抽象；
/// 本协议只覆盖声道交换需要的"找设备 + 读声道数/采样率"。
/// 实现可以复用同一个 `CoreAudioService`，也可以自己列设备。
public protocol ChannelSwapDeviceResolving: Sendable {

    /// 按 UID 找设备；`uid == nil` 时按 `namePrefix` 自动挑选（取第一个匹配）。
    func device(uid: String?, namePrefix: String) -> ChannelSwapDeviceInfo?

    /// 查找交换的候选输出设备：**非 BlackHole 中输出声道数最多者**。
    ///
    /// ⚠️ 这里**不做 ≥6 声道的过滤**，是刻意的：
    /// 目标设备可能临时掉回 2ch（这正是格式锁定要治的病），
    /// 那种情况应当报"声道数不足，等待重试"，而不是"找不到设备"。
    /// 声道数的门控由 `ChannelSwapSupervisor` 负责（对应 `ChannelSwapState.WaitReason`）。
    func preferredOutputDevice(excludingNamePrefix: String) -> ChannelSwapDeviceInfo?

    /// 系统当前默认输出设备
    func defaultOutputDevice() -> ChannelSwapDeviceInfo?

    /// 设置标称采样率。**只允许对输入设备（BlackHole）调用** —— 见
    /// `ChannelSwapSettings.alignInputSampleRate` 的说明。
    func setNominalSampleRate(_ rate: Double, on device: ChannelSwapDeviceInfo) -> OSStatus

    /// 读该设备**自己声明的**声道布局，解析出低音/中置在第几条声道。
    ///
    /// 为什么需要它：本项目原先假定"第 3 声道 = 中置、第 4 声道 = 低音"恒成立，
    /// 但本机 `27C3A Pro` 声明的顺序是 **L R LFE C** —— 正好相反。
    /// 对交换无所谓（对称），对**混音**致命（有向，混错就没声音）。
    /// ⇒ 混音的源/目标索引必须问设备。
    ///
    /// 有默认实现（返回 nil = 读不到），这样既有的 Mock 不必改动。
    func declaredChannelIndices(of device: ChannelSwapDeviceInfo) -> CoreAudioHelpers.ChannelIndices?
}

public extension ChannelSwapDeviceResolving {
    func declaredChannelIndices(of device: ChannelSwapDeviceInfo) -> CoreAudioHelpers.ChannelIndices? {
        nil
    }
}

/// 设备信息的最小集合（值类型，便于跨线程/测试传递）
public struct ChannelSwapDeviceInfo: Equatable, Sendable {
    public let id: AudioDeviceID
    public let uid: String
    public let name: String
    /// 输出声道数（对输入源而言即"可读取的声道数"）
    public let outputChannels: Int
    /// 输入声道数（BlackHole 有 16 进 16 出）
    public let inputChannels: Int
    public let nominalSampleRate: Double
    public let isBlackHole: Bool

    public init(id: AudioDeviceID, uid: String, name: String,
                outputChannels: Int, inputChannels: Int,
                nominalSampleRate: Double, isBlackHole: Bool) {
        self.id = id
        self.uid = uid
        self.name = name
        self.outputChannels = outputChannels
        self.inputChannels = inputChannels
        self.nominalSampleRate = nominalSampleRate
        self.isBlackHole = isBlackHole
    }

    /// 目标设备可用的声道数（驱动交换的那一侧）
    public var usableChannels: Int { outputChannels }

    /// 例 "27C3A Pro (HDMI)" 风格在 UI 层另有实现，这里给最小可读串
    public var displayName: String { name }
}

/// 声道交换引擎：真正的 AUHAL 装配与数据通路。
/// 抽象出来是为了让 supervisor 的状态机可以脱离音频硬件单测。
public protocol ChannelSwapAudioDriving: AnyObject, Sendable {
    /// 装配并启动数据通路。成功返回 nil，失败返回原因。
    /// - Parameters:
    ///   - plan: 已确定的交换计划（含 1-based 声道号）
    ///   - channels: 目标设备声道数（= 从源取前 N 声道）
    /// - Returns: 实际写入并回读成功的 ChannelMap（**API 0-based**）；失败抛错
    /// - Parameter mix: 已解析的 LFE 混音计划；`nil` = 不混音。
    ///   默认参数保证既有调用点与 Mock 无需改动。
    func start(plan: ChannelSwapPlan,
               input: ChannelSwapDeviceInfo,
               output: ChannelSwapDeviceInfo,
               outputIsSystemDefault: Bool,
               mix: LfeMixPlan.Resolved?) throws -> [Int32]

    /// 停止并释放全部音频资源（必须可重复调用）
    func stop()

    /// 实时统计快照
    func stats() -> ChannelSwapAudioStats
}

public extension ChannelSwapAudioDriving {
    /// 不混音的便捷调用（保持既有调用点不变）
    func start(plan: ChannelSwapPlan,
               input: ChannelSwapDeviceInfo,
               output: ChannelSwapDeviceInfo,
               outputIsSystemDefault: Bool) throws -> [Int32] {
        try start(plan: plan, input: input, output: output,
                  outputIsSystemDefault: outputIsSystemDefault, mix: nil)
    }
}

/// 音频通路的实时统计
public struct ChannelSwapAudioStats: Equatable, Sendable {
    public var inputCallbackCount: Int
    public var outputCallbackCount: Int
    public var framesIn: Int64
    public var framesOut: Int64
    public var underruns: Int64
    public var renderFailures: Int64

    /// ★ **每路输出声道的峰值**（索引 0 = 第 1 声道）。
    ///
    /// 为什么需要它：混音的"方向"（把哪一路衰减、往哪一路叠加）光看代码容易
    /// 自我说服，必须能**量出来**。有了逐路峰值就能直接验证：
    ///   输出[目标] ≈ 目标内容 + 低音内容 × gain
    ///   输出[低音] ≈ 低音内容 × gain
    /// 早先"低音没有被衰减"的 bug 就是靠这类实测暴露的（用户听出来的）。
    public var channelPeaks: [Float]

    /// ★ 输入侧**非零**帧数（抽样统计）。用于区分：
    ///   · `framesIn` 涨、`nonZeroInFrames == 0` → 读到了，但内容是静音
    ///   · `renderFailures` 涨                    → 根本没读到（TCC 拒绝）
    public var nonZeroInFrames: Int64


    public init(inputCallbackCount: Int = 0, outputCallbackCount: Int = 0,
                framesIn: Int64 = 0, framesOut: Int64 = 0,
                underruns: Int64 = 0, renderFailures: Int64 = 0,
                channelPeaks: [Float] = [],
                nonZeroInFrames: Int64 = 0) {
        self.inputCallbackCount = inputCallbackCount
        self.outputCallbackCount = outputCallbackCount
        self.framesIn = framesIn
        self.framesOut = framesOut
        self.underruns = underruns
        self.renderFailures = renderFailures
        self.channelPeaks = channelPeaks
        self.nonZeroInFrames = nonZeroInFrames
    }
}
