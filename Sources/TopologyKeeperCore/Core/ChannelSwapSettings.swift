import CoreAudio
import Foundation

/// 用户可选的两个声道处理功能（交换 / 混音）。
///
/// ⚠️ 与 `ChannelProcessingFunction` 的区别（别混）：
/// * `ChannelProcessingFunction` = **运行模式**：全断 / 直通 / 交换 / 混音，
///   由**引擎**给出（`diagnostics.activeFunction`），是"现在在跑什么"的唯一权威；
/// * 本类型 = **用户想用哪个功能**，只回答"用户上次选的是哪个"，
///   供界面做记忆与恢复（见 `ChannelSwapSettings.lastEnabledFeature`）。
public enum ChannelProcessingFeature: String, Codable, Sendable, Equatable, CaseIterable {

    /// 声道交换
    case swap

    /// LFE 混音
    case mix

    /// 功能全称（界面标题用）
    public var displayName: String {
        switch self {
        case .swap: return "声道交换"
        case .mix:  return "LFE 混音"
        }
    }
}

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
/// —— 后者本身不需要修正。
public struct ChannelSwapSettings: Codable, Equatable, Hashable, Sendable {

    /// ★ **声道处理引擎总开关**（v0.1.1 新增）：本页所有功能的"电源"。
    ///
    /// ## 为什么需要它（用户确认的产品定义）
    ///
    /// 早先"通路该不该跑"由两个功能开关的**并集**决定
    /// （`needsAudioPath = isEnabled || mixEnabled`），于是存在三种状态：
    /// 全断 / 交换 / 混音。而"两个功能都关"时通路**根本没人从 BlackHole 取数据**
    /// —— 用户的系统默认输出是 BlackHole，此时整条链路直接静音。
    /// 那个"全断"态在使用中属于**不正常状态**，不该由"关掉两个功能开关"随手进入。
    ///
    /// ⇒ 现在把"通路要不要跑"上提到本开关：
    ///
    /// | 引擎 | 交换 | 混音 | 模式 | 音频 |
    /// |------|------|------|------|------|
    /// | 关 | — | — | **全断** | 通路不跑（不占用任何设备） |
    /// | 开 | 开 | — | 交换 | 置换后输出 |
    /// | 开 | — | 开 | 混音 | 衰减混入后输出 |
    /// | 开 | — | — | **直通**（被动） | 原样转发（恒等置换） |
    ///
    /// **默认关闭**：全新安装时用户还没装 BlackHole、也还没配设备，
    /// 此时绝不能默默把音频链路接管过去。开启时 UI 会先检查 BlackHole 16ch
    /// 是否存在（见 `AppState`），不存在则提示安装而不是硬开。
    ///
    /// ⚠️ **升级迁移**：老配置里没有这个键，若照抄默认值 `false`，
    /// 已经在用交换/混音的用户升级后会**突然静音**（配置还在、通路不跑）。
    /// 因此解码时对"缺键"的情形按 `isEnabled || mixEnabled` 推导 ——
    /// 见 `init(from:)` 的迁移分支，以及 `ChannelProcessingEngineTests` 的 P1 系列。
    public var engineEnabled: Bool

    /// 声道交换功能开关。**引擎关闭时它不生效**（通路根本不跑）
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

    /// 用户**最近一次启用**的功能（交换 / 混音）。**默认交换**。
    ///
    /// ## 为什么需要这个"记忆"（用户实测反馈，v0.1.1）
    ///
    /// 起因是两个实测问题，根子是同一个 —— 界面上**只有"当前是否开着"这一个信息**，
    /// 一旦两个功能都关（直通），"用户原本用的是哪个"就丢了：
    ///
    /// 1. **标题跳变**：首页卡片若按"当前生效的功能"取名，两个功能一关，
    ///    标题就从「LFE 混音」跳成「直通」。用户原话：
    ///    *"标题栏要记忆保持原先的状态，不要改成直通的标题，只在下面的状态信息提示就行"*。
    /// 2. **重开跳功能（真 bug）**：首页卡片只有一个开关，判断"该开哪个功能"时
    ///    若读当前状态 —— 关闭的那一刻 `mixEnabled` 已经是 `false`，
    ///    于是再打开必然落进"否则开交换"⇒ **无论先前用的是什么，重开都变成交换**。
    ///    实测复现（用户："不管当前模式是交换还是混音，关闭再打开后都切到了交换"）。
    ///
    /// ⇒ 把"用户上次选的功能"显式记下来，两个问题一起消失。
    ///
    /// ⚠️ 它**不是**"当前模式"：当前模式看 `processingMode`（引擎权威，
    ///    可能是全断/直通）。本字段只回答"用户上次用的是哪个功能"。
    /// ⚠️ 维护点唯一：`ConfigStore.update`（GUI 与 `tkctl` 两条写路径的必经之处），
    ///    见 `rememberEnabledFeature()`。
    public var lastEnabledFeature: ChannelProcessingFeature

    /// **是否需要跑音频通路**（BlackHole 读入 → 处理 → 目标设备输出）。
    ///
    /// ★ 这是"通路该不该启动"的**唯一**判据，且它现在**只等于总开关**
    ///   （v0.1.1 起）。
    ///
    /// 演进过程（两轮，都是"静默失效/静默静音"换来的）：
    ///
    /// * **第一轮**：判据是 `isEnabled`（交换开关）。混音与交换**共用同一条通路**，
    ///   于是"开混音、关交换"时通路根本没启动 —— 没人从 BlackHole 读数据、
    ///   没人往目标设备写，**整个链路静音**（用户实测："开启 LFE 混音后所有声道都没声音了"）。
    /// * **第二轮**（本轮）：判据改成两个功能开关的并集后，又冒出**第三种**态：
    ///   两个都关 ⇒ 通路不跑 ⇒ 同样整条链路静音。而这时用户的系统默认输出
    ///   仍是 BlackHole，声音进了 BlackHole 就出不来。用户称之为「全断」，
    ///   并明确指出这在使用中属于**不正常状态**。
    ///
    /// ⇒ 现在的规则很硬：**通路跟着总开关走，功能开关只决定"怎么处理"**。
    ///   引擎开着而两个功能都关时装配**直通**（恒等置换），而不是断掉。
    ///
    /// ⚠️ 因此下面的推论仍然成立并且更强：**任何"该不该启动通路"的判断
    ///   都必须读本属性，不许读 `isEnabled` / `mixEnabled`**。
    public var needsAudioPath: Bool { engineEnabled }

    // MARK: - 派生：当前模式（唯一权威，UI 不许自己推导）

    /// 当前应当装配的**模式**：全断 / 直通 / 交换 / 混音。
    ///
    /// 这是"现在在跑什么"的**唯一**判据，由引擎写进诊断快照供 UI 显示 ——
    /// UI 若自己按 `mixEnabled` 之类推导，迟早与引擎漂移（本项目的既有原则）。
    ///
    /// ## 非法组合（两个功能都开）为何以**交换**为准
    ///
    /// 交换与混音互斥（用户确认的产品定义），`AppState.updateConfig` 与 `tkctl`
    /// 都会强制拆开。万一还是出现了两者皆真的配置：
    /// * 运行期实际行为是**交换**（`mixPlan` 检测到非恒等交换时返回"不可用"，
    ///   `resolvedMix` 为 nil ⇒ 不混音），
    /// * `AppState.updateConfig` 的兜底也是"保留交换、关掉混音"。
    /// ⇒ 本属性与它们保持一致（**交换优先**），否则 UI 会显示成"混音中"
    ///   而实际跑的是交换 —— 那正是本项目最忌讳的"显示的与跑的不是一回事"。
    public var processingMode: ChannelProcessingFunction {
        guard engineEnabled else { return .off }
        if isEnabled { return .swap }
        if mixEnabled { return .mix }
        return .passThrough
    }


    /// - Parameter engineEnabled: **总开关**。传 `nil`（默认）表示
    ///   "跟随功能开关" —— 即 `isEnabled || mixEnabled`。
    ///
    ///   为什么默认值是"跟随"而不是写死的 `false`：
    ///   * **生产**上全新配置走的是 `ChannelSwapSettings()`（两个功能都关）
    ///     ⇒ 推导结果就是 `false`，与"首次使用默认关闭"的要求一致；
    ///   * **既有调用点**（测试、探针）大量形如 `ChannelSwapSettings(isEnabled: true)`，
    ///     它们表达的是"交换开着"，此时通路当然要跑。
    ///     若这里写死 `false`，这些调用点会集体静默退化成"通路不跑"——
    ///     那正是本类型存在理由所要防的事。
    ///   * 要**显式**表达"引擎关掉但功能配置留着"（迁移后的真实状态、
    ///     "全断"用例），传 `engineEnabled: false` 即可。
    public init(engineEnabled: Bool? = nil,
                isEnabled: Bool = false,
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
                mixTargetChannel: Int = LfeMixPlan.defaultOutputChannel,
                lastEnabledFeature: ChannelProcessingFeature? = nil) {
        self.engineEnabled = engineEnabled ?? (isEnabled || mixEnabled)
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
        // 与 `engineEnabled` 同样的"跟随"哲学：不传就按当前开着的功能推断
        // （混音开着 ⇒ 记忆为混音），既有调用点因此不需要改动。
        self.lastEnabledFeature = lastEnabledFeature
            ?? (isEnabled ? .swap : (mixEnabled ? .mix : .swap))
    }

    /// 记住"用户刚启用了哪个功能"（供界面在功能全关时保持标题、并在重开时恢复）。
    ///
    /// 语义：**只有开启才更新**；两个都关时保持原值 —— 那正是"记忆"的意义。
    /// 非法组合（两个都开）以**交换**为准，与 `processingMode` 保持一致。
    ///
    /// ⚠️ 调用点唯一：`ConfigStore.update`（GUI 与 `tkctl` 两条写路径的必经之处）。
    ///    刻意不散落在各个界面动作里 —— 本项目已因"两条写路径各自维护"踩过坑
    ///    （`tkctl` 改配置而 App 看不见）。
    public mutating func rememberEnabledFeature() {
        if isEnabled { lastEnabledFeature = .swap }
        else if mixEnabled { lastEnabledFeature = .mix }
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
        //   用户会以为设置全丢了（见本文件顶部说明）。
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

        // ★★ 总开关的**升级迁移**（v0.1.1 新增字段，必须区分三种情形）：
        //
        //   · 键**不存在**（老配置）→ 用户没表过态 → 按现有功能开关推导：
        //     已经在用交换/混音的配置 ⇒ 引擎视为开启。
        //     ⚠️ 这一步不能省：若照抄默认值 `false`，老用户升级后
        //        配置里功能还开着、通路却不跑，**表现为突然全断（无声）**，
        //        而且界面上功能开关看起来还是"已启用" —— 极难自查。
        //   · 键存在且为 `true` → 尊重（引擎开着，可能是直通模式）。
        //   · 键存在且为 `false` → 尊重（用户主动关过引擎，不许自动打开）。
        //
        //   真正"全新安装"的情形根本不走这里：那时压根没有配置文件，
        //   直接 `AppConfig()` ⇒ `ChannelSwapSettings()` ⇒ 总开关为 false，
        //   正是"首次使用默认关闭"。
        let storedEngine = (try? c.decodeIfPresent(Bool.self, forKey: .engineEnabled)) ?? nil
        if let storedEngine {
            self.engineEnabled = storedEngine
        } else {
            self.engineEnabled = self.isEnabled || self.mixEnabled
        }

        // ★ "最近一次启用的功能"同样要迁移：
        //   老配置里**混音开着**的话，用户最近用的显然就是混音 ——
        //   若不迁移就会默认成交换，于是首页卡片标题与实际不符，
        //   而且"关掉再打开"会跳到交换（实测复现的 bug）。
        let storedFeature = (try? c.decodeIfPresent(ChannelProcessingFeature.self,
                                                   forKey: .lastEnabledFeature)) ?? nil
        if let storedFeature {
            self.lastEnabledFeature = storedFeature
        } else {
            self.lastEnabledFeature = self.isEnabled ? .swap : (self.mixEnabled ? .mix : .swap)
        }
    }

    /// 手写编码：与 `CodingKeys` 一一对应（显式声明 CodingKeys 后 Swift 不再合成）。
    /// 只写新键；废弃的 `mixTargetChannel` 不再输出。
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(engineEnabled, forKey: .engineEnabled)
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
        try c.encode(lastEnabledFeature, forKey: .lastEnabledFeature)
    }

    /// 显式声明全部键。
    ///
    /// 为什么需要手写：`mixTargetChannel` 已从存储属性改为**计算属性**
    /// （它现在由 `mixSourceChannel` 推导），Swift 合成的 `CodingKeys`
    /// 里就没有它了；但**老配置里存着这个键**，解码时要读它做兼容。
    /// 所以这里显式列出，并把老键单独声明。
    enum CodingKeys: String, CodingKey {
        case engineEnabled
        case isEnabled, inputDeviceUID, outputDeviceUID
        case firstChannel, secondChannel
        case alignInputSampleRate, retryBackoffMs, notifyOnGiveUp
        case mixEnabled, mixGainDB
        case mixSourceChannel, mixTargetChannel
        case lastEnabledFeature
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
