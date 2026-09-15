import CoreAudio
import Foundation

/// 声道交换的**全局设置**（`AppConfig` 顶层字段，与 `rules` 平级）。
///
/// ## 为什么是全局而不是每条规则一个（用户确认，2026-09）
///
/// 声道交换与"输出格式锁定"是**两个解耦的功能**：
/// 需要交换的设备不一定需要锁定。因此交换不挂在 `DeviceRule` 上，
/// 而是独立的一套设置 + 独立的引擎（`ChannelSwapEngine`），
/// 与 `RuleEngine` 零交互。
///
/// ## 功能定位（重要，别误解）
///
/// 这是**针对特定应用的补偿措施**，不是通用修正。
/// 实测（用户以 Loopback 验证）：只对**原先中置/重低音错位**的应用有效
/// （如 WOW、Movist Pro）；对本来布局就正确的应用（如 IINA、MPV）无影响
/// —— 后者本身不需要修正。详见《探针结论-声道交换.md》§6.3。
public struct ChannelSwapSettings: Codable, Equatable, Hashable, Sendable {

    /// 总开关。关闭时引擎不启动、不占用任何音频设备
    public var isEnabled: Bool

    /// 输入设备（源）的 UID。默认取第一个名字以 "BlackHole" 开头的设备
    public var inputDeviceUID: String?

    /// 输出设备（目标）的 UID。要求：输出声道数 >= `ChannelSwapPlan.minimumChannelCount`
    /// 且不是 BlackHole（即真实播放设备）。为空表示"自动挑选"
    public var outputDeviceUID: String?

    /// 交换的两个声道（**对外 1-based**，用户要求）。
    /// 默认第 3 ↔ 第 4（中置 ↔ 低音）
    public var firstChannel: Int
    public var secondChannel: Int

    /// 是否按输出设备的采样率**对齐输入设备（BlackHole）**。
    ///
    /// 依据（用户确认的策略）：两侧采样率不一致时需要实时重采样，
    /// 而在实时回调里重采样既难写对也不必要 —— BlackHole 是虚拟设备，
    /// 采样率可软件设置，直接对齐即可。
    ///
    /// ⚠️ 这是本功能**唯一**会写设备属性的地方，且**只写输入设备**，
    /// 绝不碰输出设备（避免与格式锁定功能争夺同一字段）。
    public var alignInputSampleRate: Bool

    /// 等待可交换条件的**指数回退**序列（毫秒）。
    /// 依据（用户确认）：1-2-4-8 秒，穷尽后仍不满足则弹告警。
    public var retryBackoffMs: [Int]

    /// 回退穷尽后是否发系统通知
    public var notifyOnGiveUp: Bool

    // MARK: - LFE 混音（与交换共用同一条音频通路，故放在同一份设置里）

    /// 低音混音总开关。
    ///
    /// 定位：**只在目标音响放不出低音时才有意义**（本机 TCL S45H soundbar
    /// 接在显示器 eARC 上、没有独立低音炮，低音声道整条没有声音）。
    /// 对本来正常的设备开启会平白多出低频，所以默认关闭。
    public var mixEnabled: Bool

    /// 混音增益（dB）。默认 −10dB —— LFE 校准惯例 +10dB 的等响补偿。
    ///
    /// 用户要求做成**可调滑杆**而不是写死；安全范围见 `LfeMixPlan.gainRangeDB`。
    public var mixGainDB: Double

    /// **要衰减并从它取低音的输入声道**（**对外 1-based 缓冲区号**）。默认**第 3 声道**。
    ///
    /// ## 为什么让用户选，而不是写死（用户确认）
    ///
    /// 用户实测：第 3 条声道 = LFE 且**整条无声**（没有低音炮），
    /// 第 4 条声道 = 中置且**有声**。所以默认衰减第 3 声道、把它混入第 4 声道。
    ///
    /// **但不能写死**：有些软件会把 C/LFE 的顺序写反，
    /// 那时需要衰减的、以及要搬进的目标都会跟着反。
    /// ⇒ 由用户选择"衰减哪一条"，**配对关系自动推导**（另一条就是目标），
    ///   从而不会出现"衰减 A 却混入别处"这种无意义组合。
    ///
    /// 可选值见 `LfeMixPlan.selectableChannels`（第 3/4 声道）。
    public var mixSourceChannel: Int

    /// **混音目标声道**（对外 1-based）：把衰减后的内容叠加到哪一条。
    ///
    /// ⚠️ 与来源**独立**设置（用户要求，2026-09）。
    /// 早先版本让它"自动配对成另一条"，但实测发现输入侧的情况比预想复杂
    /// （软件可能把 C/LFE 写反、也可能写进别的声道），自动推断反而制造混乱。
    /// ⇒ 交回给用户显式选择。
    ///
    /// 唯一被拒绝的组合是**来源 == 目标**：那会变成 `(1+gain) × 内容`，
    /// 是纯粹的电平翻倍、没有任何意义（见 `LfeMixPlan.unavailableReason`）。
    public var mixTargetChannel: Int

    /// **是否需要跑音频通路**（黑马读入 → 处理 → 目标设备输出）。
    ///
    /// ★ 这是"通路该不该启动"的**唯一**判据，**不是** `isEnabled`。
    ///
    /// 为什么（实测踩到）：混音与交换是互斥的两个功能，但**共用同一条通路**。
    /// 早先通路只由 `isEnabled`（交换开关）驱动，于是"开混音、关交换"时
    /// **通路根本没启动** —— 没人从 BlackHole 读数据、没人往目标设备写，
    /// 结果是**整个链路静音**（用户实测："开启 LFE 混音后所有声道都没有声音了"）。
    ///
    /// ⇒ 只要**任一**功能开着，通路就必须跑起来。
    public var needsAudioPath: Bool { isEnabled || mixEnabled }

    public init(isEnabled: Bool = false,
                inputDeviceUID: String? = nil,
                outputDeviceUID: String? = nil,
                firstChannel: Int = ChannelSwapPlan.defaultFirstChannel,
                secondChannel: Int = ChannelSwapPlan.defaultSecondChannel,
                alignInputSampleRate: Bool = true,
                retryBackoffMs: [Int] = [1000, 2000, 4000, 8000],
                notifyOnGiveUp: Bool = true,
                mixEnabled: Bool = false,
                mixGainDB: Double = LfeMixPlan.defaultGainDB,
                mixSourceChannel: Int = LfeMixPlan.defaultInputChannel,
                mixTargetChannel: Int = LfeMixPlan.defaultOutputChannel) {
        self.isEnabled = isEnabled
        self.inputDeviceUID = inputDeviceUID
        self.outputDeviceUID = outputDeviceUID
        self.firstChannel = firstChannel
        self.secondChannel = secondChannel
        self.alignInputSampleRate = alignInputSampleRate
        self.retryBackoffMs = retryBackoffMs
        self.notifyOnGiveUp = notifyOnGiveUp
        self.mixEnabled = mixEnabled
        self.mixGainDB = mixGainDB
        self.mixSourceChannel = mixSourceChannel
        self.mixTargetChannel = mixTargetChannel
    }
}

// MARK: - 容错解码
//
// 与 AppConfig 同样的思路：新增字段缺失时回落默认值，
// 否则**升级后配置会整份读取失败**（这是 AppConfig.init(from:) 存在的原因）。

extension ChannelSwapSettings {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ChannelSwapSettings()
        self.isEnabled = (try? c.decode(Bool.self, forKey: .isEnabled)) ?? d.isEnabled
        self.inputDeviceUID = (try? c.decode(String?.self, forKey: .inputDeviceUID)) ?? d.inputDeviceUID
        self.outputDeviceUID = (try? c.decode(String?.self, forKey: .outputDeviceUID)) ?? d.outputDeviceUID
        self.firstChannel = (try? c.decode(Int.self, forKey: .firstChannel)) ?? d.firstChannel
        self.secondChannel = (try? c.decode(Int.self, forKey: .secondChannel)) ?? d.secondChannel
        self.alignInputSampleRate = (try? c.decode(Bool.self, forKey: .alignInputSampleRate))
            ?? d.alignInputSampleRate
        self.retryBackoffMs = (try? c.decode([Int].self, forKey: .retryBackoffMs)) ?? d.retryBackoffMs
        self.notifyOnGiveUp = (try? c.decode(Bool.self, forKey: .notifyOnGiveUp)) ?? d.notifyOnGiveUp
        // ★ 新增字段一律 `?? 默认值` —— 否则**升级后整份配置读取失败**，
        //   用户会以为设置全丢了（见本文件顶部说明与交接说明 §13-4）。
        self.mixEnabled = (try? c.decode(Bool.self, forKey: .mixEnabled)) ?? d.mixEnabled
        self.mixGainDB = (try? c.decode(Double.self, forKey: .mixGainDB)) ?? d.mixGainDB
        // 混音目标：**必须区分"没这个键"与"键存在但为 null"**
        //   · 没这个键（老配置）→ 用户没表过态 → nil（跟随交换）
        //   · 键为 null        → 用户显式选择"跟随交换" → nil
        //   两者结果相同，故统一用 decodeIfPresent + nil 合并即可。
        // ★ 兼容：早期版本只存 mixTargetChannel（目标）。
        //   新模型以**来源**为准，所以老配置要把目标映射回来源（取配对中另一条）。
        self.mixSourceChannel = (try? c.decode(Int.self, forKey: .mixSourceChannel))
            ?? d.mixSourceChannel
        // 老配置只存过 mixTargetChannel（目标）：保留它，来源回落默认。
        self.mixTargetChannel = (try? c.decode(Int.self, forKey: .mixTargetChannel))
            ?? d.mixTargetChannel
    }

    /// 手写编码：与 `CodingKeys` 一一对应（显式声明 CodingKeys 后 Swift 不再合成）。
    /// 只写新键；废弃的 `mixTargetChannel` 不再输出。
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(isEnabled, forKey: .isEnabled)
        try c.encodeIfPresent(inputDeviceUID, forKey: .inputDeviceUID)
        try c.encodeIfPresent(outputDeviceUID, forKey: .outputDeviceUID)
        try c.encode(firstChannel, forKey: .firstChannel)
        try c.encode(secondChannel, forKey: .secondChannel)
        try c.encode(alignInputSampleRate, forKey: .alignInputSampleRate)
        try c.encode(retryBackoffMs, forKey: .retryBackoffMs)
        try c.encode(notifyOnGiveUp, forKey: .notifyOnGiveUp)
        try c.encode(mixEnabled, forKey: .mixEnabled)
        try c.encode(mixGainDB, forKey: .mixGainDB)
        try c.encode(mixSourceChannel, forKey: .mixSourceChannel)
        try c.encode(mixTargetChannel, forKey: .mixTargetChannel)
    }

    /// 显式声明全部键。
    ///
    /// 为什么需要手写：`mixTargetChannel` 已从存储属性改为**计算属性**
    /// （它现在由 `mixSourceChannel` 推导），Swift 合成的 `CodingKeys`
    /// 里就没有它了；但**老配置里存着这个键**，解码时要读它做兼容。
    /// 所以这里显式列出，并把老键单独声明。
    enum CodingKeys: String, CodingKey {
        case isEnabled, inputDeviceUID, outputDeviceUID
        case firstChannel, secondChannel
        case alignInputSampleRate, retryBackoffMs, notifyOnGiveUp
        case mixEnabled, mixGainDB
        case mixSourceChannel, mixTargetChannel
    }
}

// MARK: - 派生：交换计划

extension ChannelSwapSettings {
    /// 依据目标设备声道数生成交换计划。
    ///
    /// 返回 `nil` 表示该设备做不了（声道数 < 6）—— 与
    /// `ChannelSwapPlan.canSwap` 的判据一致，有专项单测锁定一致性。
    /// - Parameter identityWhenDisabled: 为 true 时返回**恒等**计划
    ///   （即"不做任何交换，但通路照跑"）。
    ///
    ///   为什么需要这个参数：混音与交换互斥但**共用同一条通路**。
    ///   只开混音时，通路要跑（否则静音），但**不能**顺手按 `firstChannel`/
    ///   `secondChannel` 去交换 —— 那会平白对调 C/LFE，并让混音目标错位。
    public func plan(forOutputChannels channels: Int,
                     identityWhenDisabled: Bool = false) -> ChannelSwapPlan? {
        if identityWhenDisabled {
            // first == second ⇒ swapMap 为恒等 [0..n-1]（见 ChannelSwapPlan.swapMap）
            let identity = ChannelSwapPlan(sourceChannelCount: channels,
                                           firstChannel: 1, secondChannel: 1)
            return identity.swapMap == nil ? nil : identity
        }
        let plan = ChannelSwapPlan(sourceChannelCount: channels,
                                   firstChannel: firstChannel,
                                   secondChannel: secondChannel)
        return plan.swapMap == nil ? nil : plan
    }

    /// 人话描述，例 "中置(第3声道) ↔ 低音(第4声道)"
    public var swapDescription: String {
        ChannelSwapPlan(sourceChannelCount: ChannelSwapPlan.minimumChannelCount,
                        firstChannel: firstChannel,
                        secondChannel: secondChannel).swapDescription
    }

    /// 回退序列的可读描述，例 "1-2-4-8 秒"
    public var backoffDescription: String {
        retryBackoffMs.map { String($0 / 1000) }.joined(separator: "-") + " 秒"
    }
}

// MARK: - 派生：混音计划

extension ChannelSwapSettings {
    /// 生成混音计划。
    ///
    /// - Parameters:
    ///   - channels: 目标设备输出声道数
    ///   - declared: 目标设备**自己声明的**低音/中置声道位置（`nil` = 读不到）
    ///   - swapPlan: 当前交换计划（用于"跟随交换"；`nil` = 交换未启用）
    ///
    /// ## 为什么要传入 `declared`（本项目的一条血泪教训）
    ///
    /// 原先本项目把"第 3 声道 = 中置、第 4 声道 = 低音"当恒真约定，
    /// 但本机 `27C3A Pro` 声明的顺序是 **L R LFE C** —— 正好相反。
    /// 对交换无所谓（对称），对**混音**致命：混错方向 = 混进没有声音的通道，
    /// 且**不会报任何错**。
    ///
    /// ⇒ 因此这里**优先采用设备声明的索引**，读不到时才回落到约定值。
    ///   调用方应把最终采用的值记进日志，方便排查。
    public func mixPlan(forOutputChannels channels: Int,
                        declared: CoreAudioHelpers.ChannelIndices? = nil,
                        swapPlan: ChannelSwapPlan? = nil) -> LfeMixPlan {

        // ⚠️ 两个不同空间的索引，别混（我第一版混过）：
        //   · 来源是**环形缓冲的 plane 索引**（内容在哪条 plane 上）
        //   · 目标是**输出声道位置**
        //   ⇒ 来源与目标现在都由用户显式指定，所以这里不再从 `declared` 推导 ——
        //     设备声明只作为**UI 默认值**的依据（见 `LfeMixPlan.defaultInputChannel`）。

        // ⚠️ 交换与混音**互斥**：走到这里说明配置被外部改成了非法组合。
        //    此时**不做混音**（返回不可用的计划）而不是瞎猜一个目标 ——
        //    宁可显式不做，也不要静默做错。
        if let swap = swapPlan, !swap.isIdentity {
            return LfeMixPlan(channelCount: 0)   // 不可用：与交换互斥
        }

        // ★ 来源与目标**都由用户显式选择**（用户要求）：
        //   输入侧情况复杂（软件可能写反 C/LFE、也可能写别的声道），
        //   自动推断反而制造混乱。设备声明只作为**UI 默认值**的参考。
        return LfeMixPlan(channelCount: channels,
                          inputChannel: mixSourceChannel,
                          outputChannel: mixTargetChannel,
                          gain: LfeMixPlan.gain(fromDB: mixGainDB))
    }

    /// 人话描述，例 "第3声道 → 第4声道，-10dB"
    public func mixDescription(channels: Int,
                               declared: CoreAudioHelpers.ChannelIndices? = nil,
                               swapPlan: ChannelSwapPlan? = nil) -> String {
        mixPlan(forOutputChannels: channels, declared: declared, swapPlan: swapPlan)
            .description()
    }
}
