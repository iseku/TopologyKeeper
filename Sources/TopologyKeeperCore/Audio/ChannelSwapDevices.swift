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

    // MARK: - IO 缓冲帧数（延迟的**唯一**绝对下限杠杆）

    /// 读设备当前的 **IO 缓冲帧数**（`kAudioDevicePropertyBufferFrameSize`）。
    ///
    /// ## 为什么需要它（这是延迟下限的乘数）
    ///
    /// 本通路的稳态延迟下限 = `2 × 缓冲帧数 / 采样率` —— 水位至少要装得下
    /// **两个输出回调**（一个用于本次消费、一个留作调度抖动余量）。
    /// 于是：
    ///
    /// | 采样率 | 缓冲 | 实际最低平均延迟 |
    /// | --- | --- | --- |
    /// | 48kHz | 512 帧 | 21.3ms |
    /// | 48kHz | **256 帧** | **10.7ms** |
    /// | 192kHz | 512 帧 | 5.3ms |
    ///
    /// ⇒ 想把延迟压到 ~11ms，**换小缓冲是唯一不动重采样就能做到的手段**。
    func bufferFrameSize(of device: ChannelSwapDeviceInfo) -> Int?

    /// 设备支持的缓冲帧数范围（写入前校验 + 给用户提示用）。
    func bufferFrameSizeRange(of device: ChannelSwapDeviceInfo) -> ClosedRange<Int>?

    /// 写设备的 IO 缓冲帧数。
    ///
    /// ⚠️ **只应在通路启动之前调用**：改缓冲会打断该设备上正在跑的音频流。
    /// ⚠️ 这是**全局设备属性**（BlackHole 还是系统默认输出）⇒ 退出时必须恢复原值，
    ///    这条纪律与"接管 BlackHole 可调时钟"完全相同。
    func setBufferFrameSize(_ frames: Int, on device: ChannelSwapDeviceInfo) -> OSStatus

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

    /// 默认实现：能力探测类接口，Mock / 探针可以不支持（返回 nil = 读不到、
    /// 写不动）。这与 `devicesDisappeared` 那类"必须表态"的方法不同 ——
    /// 忽略它的后果是"少了一个可调项"，而不是"静默失效"。
    func bufferFrameSize(of device: ChannelSwapDeviceInfo) -> Int? { nil }
    func bufferFrameSizeRange(of device: ChannelSwapDeviceInfo) -> ClosedRange<Int>? { nil }
    func setBufferFrameSize(_ frames: Int, on device: ChannelSwapDeviceInfo) -> OSStatus {
        kAudioHardwareUnsupportedOperationError
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

    /// 设置**延迟目标**（毫秒）。在 `start` 之前调用。
    ///
    /// ⚠️ **刻意不给协议扩展默认实现** —— 这里有过一次血债（真机实测发现）：
    /// 最初它带了一个空的默认实现，而 `ChannelSwapAudioDriver` **忘了覆盖**，
    /// 于是"延迟目标滑块"从上线起就没生效过：supervisor 的调用被空实现吞掉，
    /// 驱动永远用默认 30ms ⇒ 真机表现是「无论怎么拖滑块、怎么换缓冲，
    /// 目标水位恒为 1440 帧（30ms @48kHz）」。
    ///
    /// 这正是本项目注释里反复警告的那类写法：**协议默认实现 = 静默失效**。
    /// ⇒ 与 `devicesDisappeared` 一样，要求每个实现显式表态（编译器强制）。
    func setTargetLatency(_ milliseconds: Double)

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

/// 水位（延迟）文案的**唯一出处**。
///
/// 为什么抽成独立函数：`ChannelSwapAudioStats`（驱动层）与
/// `ChannelSwapDiagnostics`（UI 层）都要展示同一件事，而本项目已多次因
/// "同一件事两种写法"导致误判（配置页显示传递函数、状态栏显示装配摘要）。
/// 水位是新概念，一开始就只留一个实现。
public enum ChannelSwapFillText {

    /// 延迟主行，例 `"延迟 平均 16ms（水位 768 帧，目标 1024）"`。
    ///
    /// ⚠️ 传进来的必须是**平均**水位：瞬时水位在一个回调内就跳 512 帧，
    ///    拿它当"延迟"显示会显得忽大忽小（真机反馈过）。瞬时值留给 `tkctl` 诊断。
    public static func describe(averageFillFrames: Int, averageMilliseconds: Double,
                                targetFillFrames: Int) -> String {
        guard averageFillFrames > 0 || targetFillFrames > 0 else { return "未装配" }
        return "延迟 平均 \(Int(averageMilliseconds.rounded()))ms"
            + "（水位 \(averageFillFrames) 帧，目标 \(targetFillFrames)）"
    }

    /// 水位治理的"代价与事件"一行：峰值水位 + 丢旧帧数 + 欠载重置次数。
    ///
    /// 判读口径（写在这里，避免各处自行解读）：
    /// * `droppedStaleFrames` 平稳且很小 → 低目标水位工作在预期内；
    /// * 它**持续快速增长** → 两端时钟漂移偏大，靠丢数据换低延迟不划算，
    ///   该评估 PLL（用 BlackHole 的可调时钟做闭环），而不是继续丢；
    /// * `resyncCount` 增长 → 源慢于目标，属于事件性跳变，听感上可能有一次轻微顿挫。
    ///
    /// ⚠️ 峰值的毫秒数**必须直接用采样率换算**，不要借道瞬时水位。
    ///    曾经的写法是 `peakFillFrames * fillMilliseconds / fillFrames`（比例换算），
    ///    数学上等价，却在 `fillFrames == 0` 时被兜成 0ms —— 而瞬时水位在一个
    ///    回调内就会掉到 0（刚读完、输入还没写进来），水位越低越容易撞上。
    ///    真机现场：水位掉到 287 帧后，面板显示"水位峰值 0ms"，
    ///    而真实峰值是 6480 帧（135ms）—— 又一次"显示的与跑的不是一回事"。
    public static func maintenance(sampleRate: Double,
                                   peakFillFrames: Int,
                                   droppedStaleFrames: Int64,
                                   startupAlignedFrames: Int64,
                                   starvedFrames: Int64,
                                   resyncCount: Int64,
                                   targetFillFrames: Int,
                                   lowerTrimmedFrames: Int64,
                                   maxOutputGapMs: Double,
                                   maxInputGapMs: Double,
                                   maxInputFrames: Int) -> String {
        let peakMs = sampleRate > 0
            ? Int((Double(peakFillFrames) / sampleRate * 1000).rounded())
            : 0
        // 「启动对齐」与「丢旧」分开显示：前者只在装配后第一拍出现一次
        // （HDMI 输出设备启动慢造成的积压），后者是运行期的治理代价。
        // 「静音填充」= 因数据不足被 memset 成 0 的帧数（水位偏浅的真实损伤）。
        // 它与 `underruns`/`resyncCount` 不同：水位在 [frames/2, frames) 时
        // 会持续产生静音却完全不计数 —— 所以必须单列，否则"丢音却看不见"。
        var text = "水位峰值 \(peakMs)ms　丢旧 \(droppedStaleFrames) 帧"
            + "　启动对齐 \(startupAlignedFrames) 帧"
            + "　静音填充 \(starvedFrames) 帧　欠载重置 \(resyncCount) 次"
        // ★ 以下三项**只在异常时追加**：正常态这一行保持原样 ——
        //   诊断行一旦常驻无用信息，就会稀释真正要看的那几个数。
        if lowerTrimmedFrames > 0 {
            text += "　下沿微调 \(lowerTrimmedFrames) 帧"
        }
        if maxOutputGapMs >= gapAlertMs {
            text += "　输出间隔峰值 \(Int(maxOutputGapMs.rounded()))ms"
        }
        // 名义回调帧数 = 目标水位 / 2（目标 = 2 × 回调，见 `resolveLatencyTarget`）
        let nominalCallback = targetFillFrames / 2
        if nominalCallback > 0, maxInputFrames > nominalCallback {
            text += "　输入最大块 \(maxInputFrames) 帧"
        }
        if maxInputGapMs >= gapAlertMs {
            text += "　输入间隔峰值 \(Int(maxInputGapMs.rounded()))ms"
        }
        return text
    }

    /// 回调间隔超过它就值得报出来（正常回调间隔是 5.3ms @48k/256）。
    /// 取 30ms：既高于任何正常调度抖动，又远低于真机看到的 ~100ms 空洞。
    public static let gapAlertMs: Double = 30
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

    // MARK: - 水位（延迟）

    /// 当前环形缓冲水位（帧）＝ 已积压、尚未播出的音频量。
    ///
    /// ★ 这是**延迟的直接度量**：它除以采样率就是本通路额外引入的延迟。
    /// 为什么必须暴露：BUG1（"偶尔零点几秒延迟"）拖了很久才定位，
    /// 根因之一就是水位从来不可见 —— 只能靠代码推理，无法用事实反驳。
    public var fillFrames: Int

    /// 当前水位折算的毫秒（`fillFrames / sampleRate`）。
    public var fillMilliseconds: Double

    /// 观测到的水位峰值（帧）—— 回答"稳态到底积压了多少"。
    public var peakFillFrames: Int

    /// 为把水位拉回目标而丢弃的**最旧**帧数。
    ///
    /// ★ 这是低目标水位的**代价**：靠丢最旧数据换低延迟。它应当很小且平稳；
    /// 若持续快速增长，说明时钟漂移较大，该考虑用 PLL（见文档）而不是继续丢。
    public var droppedStaleFrames: Int64

    /// ★ 首次输出回调把水位对齐到目标时丢掉的**启动积压**（帧）。
    ///
    /// 与 `droppedStaleFrames` 分开：它只在装配后的**第一拍**出现一次
    /// （输入单元先启动、HDMI 输出设备后启动造成的积压），而后者是运行期的治理代价。
    /// 混在一起会让用户把"一次性对齐"误读成"一直在丢"。
    public var startupAlignedFrames: Int64

    /// ★ 运行**平均**水位（帧）。
    ///
    /// 为什么单列：瞬时水位在一个回调内就跳 512 帧（刚消费完 0、刚写完 512），
    /// 直接当"延迟"展示会显得忽大忽小。**平均水位才是代表性延迟**。
    public var averageFillFrames: Int

    /// 平均水位折算的毫秒
    public var averageFillMilliseconds: Double

    /// 当前通路的采样率（Hz）。
    ///
    /// 诊断需要它是因为**延迟下限同时取决于缓冲帧数与采样率**：
    /// `下限 = 2 × 缓冲 ÷ 采样率`（同一档"256 帧"在 48kHz 是 10.7ms、
    /// 在 192kHz 只有 2.7ms）。UI 用它把每个档位的真实下限算给用户看。
    public var sampleRate: Double

    /// ★ 因**数据不足**被静音填充的帧数 —— "丢音却看不见"的那部分。
    ///
    /// 水位落在 `[frames/2, frames)` 时每次回调都会静音一小段，但既不计数
    /// `underruns` 也不 `resync`。它持续增长 ⇒ 水位长期偏浅，该抬高目标水位。
    public var starvedFrames: Int64

    /// 欠载"重新居中"次数（每次都是一次事件性的数据跳变）。
    public var resyncCount: Int64

    /// ★ **下沿微调**丢掉的帧数 —— 水位落在死区内、被缓慢拉回目标所丢的帧。
    ///
    /// 与 `droppedStaleFrames`（上限治理，一次丢几十到几百帧）**必须分开计数**：
    /// 这里是每 N 个回调丢 1 帧的微调，速率约 0.1%（≈1.7 音分），人耳不可闻。
    /// 混在一起会让"丢旧"看起来在异常增长，把一次正常收敛误读成漂移偏大。
    public var lowerTrimmedFrames: Int64

    /// ★ 输出回调的**最大间隔**（毫秒）—— 用于给"水位冲高"归因。
    ///
    /// 存在理由（真机实测）：装配**之后**水位仍会从 512 冲到 5616（117ms），
    /// 而那段时间**没有任何设备事件**（日志一片空白），光看日志无法归因。
    /// 这类"看不见的空洞"只能靠回调节拍量出来：
    ///   · 输出间隔出现 ~100ms 的洞 ⇒ 输出侧停摆，输入侧在空写；
    ///   · 输入间隔正常但单次帧数远超名义值 ⇒ 输入侧在"追赶"。
    public var maxOutputGapMs: Double

    /// 输入回调的最大间隔（毫秒）—— 与输出侧对照，区分"谁停摆了"。
    public var maxInputGapMs: Double

    /// 单次输入回调的**最大帧数** —— 输入突发时远大于名义回调帧数。
    public var maxInputFrames: Int

    /// 目标水位（帧）—— 稳态期望值，诊断时用来判断"现在偏高还是偏低"。
    public var targetFillFrames: Int

    /// 本设备**实际可达到的最低**稳态延迟（毫秒）。
    ///
    /// ★ 存在的唯一理由：用户请求的延迟目标可能低于物理下限（受音频设备的
    ///   IO 缓冲限制）—— UI 必须显示这个值，否则"设了 10ms 却跑 32ms"
    ///   就成了一次"显示的与跑的不是一回事"。
    public var minAchievableLatencyMs: Double


    public init(inputCallbackCount: Int = 0, outputCallbackCount: Int = 0,
                framesIn: Int64 = 0, framesOut: Int64 = 0,
                underruns: Int64 = 0, renderFailures: Int64 = 0,
                channelPeaks: [Float] = [],
                nonZeroInFrames: Int64 = 0,
                fillFrames: Int = 0,
                fillMilliseconds: Double = 0,
                peakFillFrames: Int = 0,
                droppedStaleFrames: Int64 = 0,
                startupAlignedFrames: Int64 = 0,
                resyncCount: Int64 = 0,
                targetFillFrames: Int = 0,
                minAchievableLatencyMs: Double = 0,
                averageFillFrames: Int = 0,
                averageFillMilliseconds: Double = 0,
                sampleRate: Double = 0,
                starvedFrames: Int64 = 0,
                lowerTrimmedFrames: Int64 = 0,
                maxOutputGapMs: Double = 0,
                maxInputGapMs: Double = 0,
                maxInputFrames: Int = 0) {
        self.inputCallbackCount = inputCallbackCount
        self.outputCallbackCount = outputCallbackCount
        self.framesIn = framesIn
        self.framesOut = framesOut
        self.underruns = underruns
        self.renderFailures = renderFailures
        self.channelPeaks = channelPeaks
        self.nonZeroInFrames = nonZeroInFrames
        self.fillFrames = fillFrames
        self.fillMilliseconds = fillMilliseconds
        self.peakFillFrames = peakFillFrames
        self.droppedStaleFrames = droppedStaleFrames
        self.startupAlignedFrames = startupAlignedFrames
        self.resyncCount = resyncCount
        self.targetFillFrames = targetFillFrames
        self.minAchievableLatencyMs = minAchievableLatencyMs
        self.averageFillFrames = averageFillFrames
        self.averageFillMilliseconds = averageFillMilliseconds
        self.sampleRate = sampleRate
        self.starvedFrames = starvedFrames
        self.lowerTrimmedFrames = lowerTrimmedFrames
        self.maxOutputGapMs = maxOutputGapMs
        self.maxInputGapMs = maxInputGapMs
        self.maxInputFrames = maxInputFrames
    }

    /// 延迟主行（文案与 UI 共用同一出处）—— 用**平均**水位，避免显示锯齿
    public var latencyText: String {
        ChannelSwapFillText.describe(averageFillFrames: averageFillFrames,
                                     averageMilliseconds: averageFillMilliseconds,
                                     targetFillFrames: targetFillFrames)
    }

    /// 水位治理行（丢旧帧数 / 欠载重置 / 峰值水位）
    public var fillMaintenanceText: String {
        ChannelSwapFillText.maintenance(sampleRate: sampleRate,
                                        peakFillFrames: peakFillFrames,
                                        droppedStaleFrames: droppedStaleFrames,
                                        startupAlignedFrames: startupAlignedFrames,
                                        starvedFrames: starvedFrames,
                                        resyncCount: resyncCount,
                                        targetFillFrames: targetFillFrames,
                                        lowerTrimmedFrames: lowerTrimmedFrames,
                                        maxOutputGapMs: maxOutputGapMs,
                                        maxInputGapMs: maxInputGapMs,
                                        maxInputFrames: maxInputFrames)
    }
}
