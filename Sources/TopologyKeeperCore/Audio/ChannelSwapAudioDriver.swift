import AudioToolbox
import AudioUnit
import CoreAudio
import Dispatch
import Foundation

/// 声道交换的**音频数据通路**（真实实现）。
///
/// 架构与已验证过的探针一致：
///
/// ```
/// 输入单元 H（AUHAL）              输出单元 O（AUHAL）
///   bus1 输入  ──▶ AudioUnitRender 取数据
///      │（回调内必须调用 AudioUnitRender，ioData 不携带音频）
///      ▼  取前 N 声道
///   无锁 SPSC 环形缓冲（Float32，按声道分 plane）
///      │
///      ▼  填入输出缓冲
///   ChannelMap（★ 必须始终设置，否则 HAL 会丢声道）
/// ```
///
/// ## ★ 为什么"交换"由我们自己搬样本，而不是交给 HAL 的 ChannelMap
///
/// 实测（用户真机抓到的现象）：`kAudioOutputUnitProperty_ChannelMap` 在
/// **`DefaultOutput`**（内部带 `AUConverter`）上生效；
/// 但在 **`HALOutput` + 显式绑设备**（直通路径）上，属性**写入与回读都成功、
/// 实际却完全不生效** —— 交换开着与关着一个样。
///
/// 而"目标设备不是系统默认输出"时我们必须用 `HALOutput`（否则写错设备），
/// 所以不能再依赖这个属性。
///
/// 结论：**交换由我们自己在渲染回调里做**（纯数据置换，与单元类型无关）；
/// `ChannelMap` 只写**恒等映射**，用途退化为"防止 HAL 丢声道"
/// （实测不设它时只播出 6 路）。
///
/// 代价：每帧多几次索引访问（8 声道约 1–2% CPU），换来的是行为可预期。
///
/// ## 实时线程纪律（比 TopologyKeeper 既有的 audioQueue 纪律更严）
///
/// 两个回调都跑在 HAL 的**实时线程**上，里面**绝不**：
/// 加锁 / 分配内存 / 写日志 / Dispatch / 调用 `CoreAudioHelpers`。
/// 因此：
/// * 环形缓冲与 `AudioUnitRender` 的目标缓冲都在 `start` 前**预分配**；
/// * 统计量是普通整数（仅在诊断时读取，容忍轻微撕裂，换取实时路径零开销）。
public final class ChannelSwapAudioDriver: ChannelSwapAudioDriving, @unchecked Sendable {

    /// 输入侧最多支持的帧数（用于预分配 `AudioUnitRender` 的目标缓冲）。
    /// 512 是常见值，4096 覆盖绝大多数设备；再大也不至于分配失败。
    private static let maxFrames = 4096

    /// 启动预填充最多等待的回调数（超时兜底：源端异常时不能让链路永久静音）。
    ///
    /// 正常情况下填满目标水位只需几个回调（48kHz 填 1440 帧 = 30ms ≈ 3 个回调），
    /// 200 个回调（≈ 1~2 秒）是极宽裕的上限。
    private static let maxPrefillCallbacks = 200

    /// 运行平均水位的低通分母：一阶低通，时间常数 ≈ 64 个回调 ≈ 0.7 秒。
    ///
    /// 为什么需要平均：水位在一个回调内就会跳 512 帧（10.7ms）—— 刚消费完是 0、
    /// 刚写完是 512。UI 直接显示瞬时值会让人以为"延迟忽大忽小"（真机反馈），
    /// 而**平均水位才是"代表性延迟"**。瞬时值仍有价值，保留在 `tkctl` 诊断里。
    static let fillAverageDivisor = 64

    /// 死区的**最小**毫秒数（实际死区还会被"一个输出回调的帧数"顶上去）。
    ///
    /// ⚠️ 死区**绝不能**做成"某个远离目标的上限"（曾经写成"目标 30ms / 上限 90ms"）：
    ///    那会造成**高位黏滞** —— 真机实测水位停在 3700 帧（77ms）、峰值 96ms
    ///    后再也不动，因为水位只要没超过那个宽上限就永远不被修正。
    ///    判据必须锚定**目标**，见 `resolveLatencyTarget`。
    private static let deadbandMinMs = 8.0

    /// 水位收敛的比例分母：每次回调最多丢掉"超出量"的 1/8。
    /// 越大越平滑、收敛越慢；用比例而非一步到位，是为了不产生可听的跳变。
    static let fillConvergenceDivisor = 8

    /// ★ 下沿微调的节拍：水位落在死区内时，**每这么多个回调丢 1 帧**。
    ///
    /// 为什么必须有（真机实测）：死区 `[目标, 目标+死区]` 内**没有任何控制** ——
    /// 丢旧只在超过上限时动手，欠载 resync 只在下限兜底。于是水位一旦因冲高
    /// 落进这个区间就**永远回不到目标**：实测睡眠唤醒后停在 881（目标 512，
    /// 差 369 帧 ≈ 7.7ms），再也不会自己下来，只能"关掉再打开引擎"才重置。
    ///
    /// 速率：48kHz / 256 帧回调下，每 4 个回调丢 1 帧 ≈ 47 帧/秒 ≈ 0.1%
    /// 速率差（约 1.7 音分），人耳不可闻；从 881 回到 512 约 8 秒。
    /// 单帧丢弃不会产生可听跳变 —— 对比：丢旧一次可能丢几百帧。
    static let lowerTrimInterval = 4

    // MARK: 单元与缓冲

    private var inputUnit: AudioUnit?
    private var outputUnit: AudioUnit?
    private var ring: SwapRingBuffer?
    private var renderPlanes: [UnsafeMutablePointer<Float>] = []
    private var renderABL: UnsafeMutablePointer<AudioBufferList>?
    private var renderABLChannelCount = 0

    /// 实际写入并回读成功的 ChannelMap（API 0-based）
    private var appliedMap: [Int32]?
    /// 取源前几路（= 目标设备声道数）
    private var takeChannels = 0
    /// ★ 预计算的声道置换表：`permute[dst] = src`（**API 0-based**）。
    /// 恒等表示不交换。在渲染回调里按它取数 —— 见文件头"为什么自己换样本"。
    private var permute: [Int] = []
    /// 源设备可读声道数（BlackHole 输入流声道数）
    private var sourceChannels = 0
    private var sampleRate: Double = 48000

    // MARK: LFE 混音（**在渲染回调里零分配完成**）
    //
    // 三个量都在 `start` 时**预计算**成普通整数/浮点，
    // 回调里只做指针算术 —— 实时路径上不做任何分配、不加锁、不查表。
    /// 线性增益；**0 表示混音关闭**（回调据此走无混音的快路径）
    private var mixGain: Float = 0
    /// 低音来源的环形缓冲 plane 索引（API 0-based）
    private var mixSourceIndex = 0
    /// 叠加到哪条输出声道（API 0-based）
    private var mixTargetIndex = -1
    /// ★ 与 `mixSourceIndex` **配对的那条上游**（两条上游是一对：3/4 或 4/3）——
    ///   它直通进 CH-O，不衰减。用户定义："另一条就直接输出到 CH-O"。
    private var mixDirectIndex = -1
    /// ★ **配对中"不是 CH-O"的那条下游声道**（本机 = CH3-O）。
    ///   它不连 ⇒ 静音（用户接线图里 CH3 没有输出线）。
    ///
    ///   ⚠️ 只静音这一条，**不能**把所有其它声道都关掉 ——
    ///   L/R、环绕那几路在原图里是正常直通的。
    private var mixCutIndex = -1

    /// ★ **诊断自测信号**（默认关）。
    ///
    /// 开启后渲染回调**不读环形缓冲**，就地合成：
    ///   · CH-O 上 = 被衰减那条上游（200Hz）× gain + 另一条上游（500Hz 近似）
    ///   · CH-O 之外配对的那条 = 0
    ///
    /// 为什么要它：`tkctl mix verify` 原先依赖"BlackHole 里真的有音频"，
    /// 而命令行二进制读 BlackHole 受 TCC 限制时会**静默读到全 0**，
    /// 于是"到底有没有按预期混音"根本无法判定。自测信号绕开整条上游，
    /// 让输出侧 + 混音逻辑可以被**完全客观地**验证。
    public var selfTestSignal = false
    private var selfTestPhase: Double = 0

    // MARK: 实时统计
    //
    // 只在 HAL 回调线程写、诊断时读。刻意不用锁/原子：
    // 实时路径上任何同步原语都可能造成抖动，而诊断值允许轻微不一致。
    private var sInCallbacks = 0
    private var sOutCallbacks = 0
    private var sFramesIn: Int64 = 0
    private var sFramesOut: Int64 = 0
    private var sUnderruns: Int64 = 0
    private var sRenderFailures: Int64 = 0
    /// ★ 输入回调里**非零**的帧数。
    ///
    /// 用来区分两种都表现为"没声音"的情况：
    ///   · `framesIn` 在涨但 `nonZeroInFrames == 0` → 读到了，但内容是静音
    ///     （典型：没有音频流经 BlackHole）
    ///   · `renderFailures` 在涨            → 根本没读到
    ///     （典型：命令行进程被 TCC 拒绝读输入设备）
    private var sNonZeroInFrames: Int64 = 0

    // MARK: 低目标水位（v0.1.4 修 BUG1）

    /// 要维持的目标水位（帧）。`start()` 按**延迟目标**折算 ——
    /// 见 `resolveLatencyTarget`（那里也说明了为什么实际压不到用户请求的 10ms）。
    private var targetFillFrames = 0
    /// 收敛死区（帧）：水位高于 `目标 + 死区` 即按比例丢最旧数据。
    private var fillDeadbandFrames = 0

    /// 用户在 `start()` 前设置的**延迟目标**（毫秒）。nil = 用配置默认值。
    ///
    /// 为什么用属性而不是 `start(...)` 的参数：`start` 的形参已经很多，
    /// 而这是个可选调参 —— 见 `ChannelSwapAudioDriving.setTargetLatency`。
    private var requestedLatencyMs: Double?

    /// 实际可达到的**最低稳态延迟**（毫秒），供 UI 提示"设不到那么低"。
    private var sMinAchievableLatencyMs: Double = 0

    /// 启动预填充的进度：`-1` = 已结束/禁用；`>= 0` = 还在等水位涨到目标（记回调数）。
    ///
    /// 为什么需要它（真机四组对比实测）：装配后水位 = `min(首拍时的写入量, 目标)`，
    /// 而"首拍时的写入量"取决于**输出设备从启动到第一次回调花了多久**
    /// （HDMI/eARC 尤其慢，且每次都不一样）⇒ **同一个设置每次重启 TK 延迟都不同**：
    /// 实测 48kHz/512 帧得到 21ms、192kHz/512 帧只有 13ms，都低于各自的目标 22ms。
    /// 预填充把水位补齐到目标 ⇒ 延迟变成**确定的**。
    private var sPrefillAttempts = -1

    /// ★ **本轮装配**是否还没处理过第一次输出回调（`start()` 置 true，首拍后清零）。
    ///
    /// ⚠️ 这里曾经用累计计数 `sOutCallbacks <= 1` 判断，是个真机 bug：
    ///    驱动实例由引擎持有、**跨装配复用**，`sOutCallbacks` 会一直累加
    ///    ⇒ 那个条件只在 App 启动后的第一次装配成立，之后**每次切换模式都不对齐**，
    ///    启动积压（HDMI 输出设备启动慢造成）就一直跟着链路跑。
    ///    真机实测：水位峰值 117ms、丢旧 3541 帧（≈ 从 117ms 收敛回目标带的量），
    ///    表现正是"切换模式后延迟会变"。
    ///    ⇒ 判据必须是"**每次装配**重置"的标记，不能是进程级累计量。
    private var pendingStartupAlignment = false

    /// 欠载"重新居中"次数（每次都是一次事件性的数据跳变）
    private var sResyncs: Int64 = 0
    /// 为把水位拉回目标而丢弃的**最旧**帧数（低延迟的代价，必须可见）
    private var sDroppedStaleFrames: Int64 = 0
    /// ★ 首次输出回调"把水位对齐到目标"时丢掉的**启动积压**（帧）。
    ///
    /// ⚠️ 必须与 `sDroppedStaleFrames` **分开统计**：两者语义完全不同 ——
    ///    前者只在装配后的第一拍出现一次（输入单元先起、HDMI 输出设备后起，
    ///    这段时间的积压是"陈旧数据"），后者是运行期持续的漂移治理代价。
    ///    混在一起会让用户把"一次性对齐"误读成"一直在丢"。
    private var sStartupAlignedFrames: Int64 = 0
    /// 观测到的水位峰值（帧）—— 用来回答"稳态到底积压了多少"
    private var sPeakFillFrames = 0
    /// ★ 运行**平均**水位（帧，一阶低通）：诊断显示"代表性延迟"用（见 `fillAverageDivisor`）
    private var sAverageFillFrames = 0
    /// ★ 因**数据不足**而被静音填充的帧数。
    ///
    /// 这是长期存在的**诊断盲区**：水位落在 `[frames/2, frames)` 时，每次回调都会把
    /// 缺口 memset 成 0（音频里出现极短的空洞），但既不触发 `underruns`
    /// （那个只在 `< frames/2` 时计数）也不触发 `resync` ⇒ **丢音却看不见**。
    /// 真机观察到"水位长期贴地在 0/512 之间跳"时，必须靠这个数字判断有没有真损伤。
    private var sStarvedFrames: Int64 = 0

    // MARK: 回调节拍诊断（给"水位冲高"归因）

    /// 上一次回调的单调时刻（纳秒；**0 = 未初始化**）。
    ///
    /// 为什么用 0 作哨兵：装配之间（睡眠、停止、重建）会隔很久，
    /// 若不重置，唤醒后第一个回调就会把"睡眠时长"记成一次回调间隔峰值 ——
    /// 那会立刻污染诊断，把一次正常的 5ms 节拍显示成几十秒的洞。
    /// ⇒ `stop()` 里必须清零（装配必然先 stop）。
    private var sLastInputTick: UInt64 = 0
    private var sLastOutputTick: UInt64 = 0
    /// 回调间隔峰值（毫秒）—— 见 `ChannelSwapAudioStats.maxOutputGapMs`。
    ///
    /// 真机实测：装配**之后**水位会从 512 冲到 5616（117ms），而那段时间
    /// **没有任何设备事件**（日志一片空白）。这类"看不见的空洞"只能靠节拍量：
    /// 输出侧有洞 ⇒ 输出停摆、输入空写；输入侧块变大 ⇒ 输入追赶。
    private var sMaxInputGapMs: Double = 0
    private var sMaxOutputGapMs: Double = 0
    /// 单次输入回调的最大帧数（正常 = 设备缓冲帧数）
    private var sMaxInputFrames = 0

    /// 下沿微调的节拍计数（每 `lowerTrimInterval` 个回调丢 1 帧，见 `renderFromRing`）
    private var sLowerTrimCounter = 0
    /// 下沿微调累计丢掉的帧数（与 `sDroppedStaleFrames` 分开计数）
    private var sLowerTrimmedFrames: Int64 = 0

    /// 每路输出的峰值（实时回调里就地取 abs 最大值，无分配）。
    ///
    /// ⚠️ **必须固定容量、只改元素**。曾经写成"按需 `sChannelPeaks = [Float](...)` 重新分配"，
    /// 结果 RT 线程换掉数组存储的同时主线程在读它 → 直接崩：
    ///   `Swift/ContiguousArrayBuffer.swift:703: Fatal error: Index out of range`
    /// 这是"实时路径不能碰 Swift 容器结构"的又一种表现（第二次踩到同一类问题）。
    private static let maxReportChannels = 64
    private var sChannelPeaks = [Float](repeating: 0, count: maxReportChannels)
    // ⚠️ 曾经在这里加过"上游每路峰值"，结果**直接崩溃**（Index out of range）：
    //    在实时回调线程里写 Swift Array，而主线程同时 stats() 读它 ——
    //    数组存储被并发读写。实时路径上**绝不能碰 Swift 容器**，
    //    要统计只能用预分配的固定缓冲 + 原始指针（输出侧峰值就是这么做的，
    //    它在 start 时预分配、之后只写元素不改变容器）。

    public init() {}

    /// 便于制造失败：把"设备实际的输入声道数"覆盖掉（仅测试/诊断用）
    public var overrideSourceChannels: Int?

    /// ★ 诊断自测：忽略真实输入，改为**在输入回调里合成逐段序列**。
    ///
    /// 仅供 `tkctl swap selftest` 使用 —— 目的是"不依赖外部音频源、也不依赖
    /// BlackHole 里真的有音频"就能验证**交换是否生效**。
    ///
    /// 为什么用**逐段序列**（同一时刻只有 1 路出声）而不是多路同时出声：
    /// 实测本机"8 路同时出声"只能播出固定两路，序列形态才能完整播出所有声道。
    public var diagnosticToneEnabled = false
    /// 每段的时长（毫秒）
    public var diagnosticToneSegmentMs = 1200
    private var tonePhase: Int64 = 0

    // MARK: - 启动

    /// 设置**延迟目标**（毫秒）—— 用户滑块的值，`start` 会据此解析水位参数。
    ///
    /// ⚠️ 这个方法必须存在（协议**不给**默认实现）。它曾经缺失过一整轮：
    /// 协议带了个空默认实现、本类忘了覆盖 ⇒ 滑块设置被静默吞掉，
    /// 真机上无论怎么拖滑块，目标水位恒为默认 30ms 对应的 1440 帧。
    /// 现在"忘记实现"会直接编译不过，而不是让功能悄悄失效。
    public func setTargetLatency(_ milliseconds: Double) {
        requestedLatencyMs = milliseconds
    }

    public func start(plan: ChannelSwapPlan,
                      input: ChannelSwapDeviceInfo,
                      output: ChannelSwapDeviceInfo,
                      outputIsSystemDefault: Bool,
                      mix: LfeMixPlan.Resolved? = nil) throws -> [Int32] {
        // 重复调用先清理，保证幂等
        stop()

        guard let swapMap = plan.swapMap else {
            throw SwapDriverError.planUnusable
        }
        // ★ 置换表在我们这边用；写给 HAL 的 ChannelMap 一律恒等（见文件头说明）
        permute = swapMap.map { Int($0) }

        let take = plan.sourceChannelCount
        let srcChannels = max(overrideSourceChannels ?? input.inputChannels, take)
        guard srcChannels > 0 else { throw SwapDriverError.noInputStream }

        sampleRate = output.nominalSampleRate
        takeChannels = take
        sourceChannels = srcChannels

        // ★ 混音目标解析（上面的 `plan` 已含门控；这里只做范围复核）
        //
        //   为什么在 `start` 里就把三个量拍平成整数：
        //   渲染回调是**实时线程**，不能分配、不能加锁、不能调用可能阻塞的东西，
        //   所以一切"算"都要在此之前做完。
        // ★ **不要**加 `targetAPIIndex != sourceAPIIndex` 这条校验！
        //   上游（plane 索引）与下游（输出声道）是**两个空间**，编号相同完全合法
        //   —— CH-I=3 与 CH-O=3 就是用户明确要求支持的组合
        //   （CH3-O = CH4-I + CH3-I × gain）。
        //
        //   ⚠️ 这条错误校验我犯过两次：先是在 `LfeMixPlan` 的门控里（用户纠正后已删），
        //      却**漏删了驱动这一处** —— 于是 CH-O=3 时混音被静默跳过，
        //      日志只留一行「LFE 混音计划不可用，已跳过混音」，
        //      表现为"衰减完全不生效"，极难定位。
        if let mix, mix.gain > 0,
           mix.targetAPIIndex >= 0, mix.targetAPIIndex < take,
           mix.sourceAPIIndex >= 0, mix.sourceAPIIndex < take {
            mixGain = mix.gain
            mixSourceIndex = mix.sourceAPIIndex
            mixTargetIndex = mix.targetAPIIndex
            // ★★ 直通的那条输入 + 不连的那条下游 —— **推导走 `LfeMixPlan` 的纯函数**。
            //
            //   规律（4 组用例实测得出）：
            //     · 直通的输入  = 与 **CH-I**（上游）配对的那条输入
            //     · 不连的下游  = 与 **CH-O**（下游）配对的那条输出（本机 CH-O=4 ⇒ CH3-O 不连）
            //     · **衰减仍施加在用户选中的那条 CH-I 上**（这是 CH-I 的唯一作用）
            //
            //   | CH-O | CH-I | CH-O 的结果         | 不连  |
            //   |------|------|---------------------|-------|
            //   |  4   |  3   | CH4-I + CH3-I×g     | CH3-O |
            //   |  4   |  4   | CH3-I + CH4-I×g     | CH3-O |
            //   |  3   |  3   | CH4-I + CH3-I×g     | CH4-O |
            //   |  3   |  4   | CH3-I + CH4-I×g     | CH4-O |
            //
            //   ⚠️ 这段"取配对中另一条"的运算此前在本文件、`LfeMixPlan`、
            //      单测（`LfeMixPlanTests.wiring`）、`tkctl mixVerify` **各抄了一份**，
            //      而混音语义已经错过 5 次 —— 其中一次正是把上游与下游两个空间
            //      弄混。更糟的是本文件上面那两句注释曾经**互相矛盾**
            //      （先说直通由 CH-O 定、下面又说由 CH-I 定），把一次外部审计
            //      直接引到了错误的结论上（误判成"驱动与展示不一致"的功能缺陷）。
            //      ⇒ 现在推导只有 `LfeMixPlan.directInputChannel/cutOutputChannel`
            //        一个出处，四处共用；两个空间的参数名也显式区分。
            mixDirectIndex = ChannelSwapPlan.apiIndex(
                forChannel: LfeMixPlan.directInputChannel(forSource: mix.inputChannel))
            mixCutIndex = ChannelSwapPlan.apiIndex(
                forChannel: LfeMixPlan.cutOutputChannel(forTarget: mix.outputChannel))
        } else {
            // 计划不可用/越界/自混 → 静默退回"不混音"，
            // 但**必须**在日志里说明，否则就是本项目最怕的"静默失效"
            mixGain = 0
            mixSourceIndex = 0
            mixTargetIndex = -1
            mixDirectIndex = -1
            mixCutIndex = -1
            if let mix {
                Log.warn("LFE 混音计划不可用，已跳过混音：\(mix.description)")
            }
        }

        // 环形缓冲：约 250ms。够吸收调度抖动，又不至于引入明显延迟。
        // 环形缓冲：容量 0.25s（上取整到 2 的幂 = 48kHz 下 16384 帧），
        // 但**稳态水位**由下面的 target/max 钳制在 30~90ms —— 见 BUG1 的说明。
        let capacityFrames = Int(sampleRate * 0.25)
        ring = SwapRingBuffer(capacity: capacityFrames, channels: take)
        prepareRenderBuffers(channels: srcChannels)

        // ★ 低目标水位：延迟只能在**读侧**靠丢最旧数据降低，
        //   所以这里给出目标与上限，交给 `renderFromRing` 每次回调按比例收敛。
        // 延迟目标 → 水位参数。这里先用**保守估计**的回调帧数算一次；
        // 真正的输出回调帧数要等第一次回调才知道，届时按真实值重算并重新对齐。
        applyLatencyTarget(sampleRate: sampleRate, callbackFrames: Self.conservativeCallbackFrames(rate: sampleRate))
        // 每次装配都重新武装"首拍对齐"与"启动预填充"（详见各自的说明）
        pendingStartupAlignment = true
        sPrefillAttempts = 0

        do {
            try setupInputUnit(device: input, sourceChannels: srcChannels)
            try setupOutputUnit(device: output,
                                isSystemDefault: outputIsSystemDefault,
                                identityMap: (0..<take).map { Int32($0) })
        } catch {
            stop()
            throw error
        }

        // ── 启动：先输入后输出 ─────────────────────────────────
        //    诊断自测时输入单元仍需启动（提供回调节拍），但数据由我们合成
        var status = AudioOutputUnitStart(inputUnit!)
        guard status == noErr else {
            stop()
            throw SwapDriverError.startFailed(phase: "输入单元", status: status)
        }
        status = AudioOutputUnitStart(outputUnit!)
        guard status == noErr else {
            stop()
            throw SwapDriverError.startFailed(phase: "输出单元", status: status)
        }

        appliedMap = swapMap
        Log.info("声道交换音频通路已启动：取源前 \(take) 声道（源 \(srcChannels) 声道），"
                 + "\(Int(sampleRate))Hz，"
                 + "交换=\(plan.swapDescription)，"
                 + "置换表(API 0-based)=\(permute)")
        // ★ 把混音实际采用的索引与完整传递函数**打出来** ——
        //   这块耦合太多，靠读代码推断已经错过 5 次，必须以运行期事实为准。
        if mixGain != 0 {
            // ⚠️ 打印时统一用「API 索引 + 1」得到对外 1-based 声道号。
            //    先前这里对已经转过的值又调了一次 channelNumber()，于是显示的数字
            //    整体错位（日志里出现 "ratePlane=3" 而实际索引是 2）——
            //    诊断信息本身出错比没有诊断更误导，务必与 channelIndices 的定义一致。
            let rateCh = mixSourceIndex + 1
            let directCh = mixDirectIndex + 1
            let targetCh = mixTargetIndex + 1
            let cutCh = mixCutIndex >= 0 ? "\(mixCutIndex + 1)" : "无"
            Log.info("LFE 混音已装配：gain=\(mixGain)"
                     + "，ratePlane(输入声道被衰减)=plane[\(mixSourceIndex)] (CH\(rateCh)-I)"
                     + "，directPlane(输入声道直通)=plane[\(mixDirectIndex)] (CH\(directCh)-I)"
                     + "，targetOutput(CH\(targetCh)-O)=output[\(mixTargetIndex)]"
                     + "，cutOutput=output[\(mixCutIndex)] (CH\(cutCh)-O)")
            Log.info("LFE 混音传递函数：CH\(targetCh)-O = "
                     + "CH\(directCh)-I + CH\(rateCh)-I × \(mixGain)；CH\(cutCh)-O = 0；其余直通")
        }
        return swapMap
    }

    public func stop() {
        // ⚠️ **不要**在这里清 `selfTestSignal`：`start()` 开头会先调 `stop()`
        //    （为了幂等），于是"start 之前设的开关"会被立刻抹掉 ——
        //    现象是"自测已开启却写不出信号"，我为此白查了一轮。
        //    它只是诊断开关，生命周期由调用方管理，不该被 stop() 重置。
        selfTestPhase = 0
        sNonZeroInFrames = 0
        sResyncs = 0
        sDroppedStaleFrames = 0
        sStartupAlignedFrames = 0
        sPeakFillFrames = 0
        sAverageFillFrames = 0
        sStarvedFrames = 0
        // ★ 回调节拍诊断与下沿微调也必须清零：
        //   装配之间隔着睡眠/停止，不重置就会把"睡眠时长"记成回调间隔峰值。
        sLastInputTick = 0
        sLastOutputTick = 0
        sMaxInputGapMs = 0
        sMaxOutputGapMs = 0
        sMaxInputFrames = 0
        sLowerTrimCounter = 0
        sLowerTrimmedFrames = 0
        sPrefillAttempts = -1
        targetFillFrames = 0
        fillDeadbandFrames = 0
        sMinAchievableLatencyMs = 0
        pendingStartupAlignment = false
        for i in 0..<Self.maxReportChannels { sChannelPeaks[i] = 0 }
        if let inputUnit {
            AudioOutputUnitStop(inputUnit)
            AudioUnitUninitialize(inputUnit)
            AudioComponentInstanceDispose(inputUnit)
        }
        if let outputUnit {
            AudioOutputUnitStop(outputUnit)
            AudioUnitUninitialize(outputUnit)
            AudioComponentInstanceDispose(outputUnit)
        }
        inputUnit = nil
        outputUnit = nil

        releaseRenderBuffers()
        ring = nil
        appliedMap = nil
        permute = []
    }

    public func stats() -> ChannelSwapAudioStats {
        ChannelSwapAudioStats(inputCallbackCount: sInCallbacks,
                              outputCallbackCount: sOutCallbacks,
                              framesIn: sFramesIn,
                              framesOut: sFramesOut,
                              underruns: sUnderruns,
                              renderFailures: sRenderFailures,
                              channelPeaks: Array(sChannelPeaks.prefix(max(takeChannels, 0))),
                              nonZeroInFrames: sNonZeroInFrames,
                              // ★ 水位（延迟）必须可观测：BUG1 就是"看不见水位"才拖了这么久。
                              //   这三个量一起看就能回答"现在有多少延迟、有没有在收敛"。
                              fillFrames: ring?.fillFrames ?? 0,
                              fillMilliseconds: sampleRate > 0
                                  ? Double(ring?.fillFrames ?? 0) / sampleRate * 1000 : 0,
                              peakFillFrames: sPeakFillFrames,
                              droppedStaleFrames: sDroppedStaleFrames,
                              startupAlignedFrames: sStartupAlignedFrames,
                              resyncCount: sResyncs,
                              targetFillFrames: targetFillFrames,
                              minAchievableLatencyMs: sMinAchievableLatencyMs,
                              averageFillFrames: sAverageFillFrames,
                              averageFillMilliseconds: sampleRate > 0
                                  ? Double(sAverageFillFrames) / sampleRate * 1000 : 0,
                              sampleRate: sampleRate,
                              starvedFrames: sStarvedFrames,
                              // ★ 下沿微调与回调节拍：前者是"把水位拉回目标"的代价，
                              //   后者是给"水位为何冲高"归因的唯一手段（见字段说明）。
                              lowerTrimmedFrames: sLowerTrimmedFrames,
                              maxOutputGapMs: sMaxOutputGapMs,
                              maxInputGapMs: sMaxInputGapMs,
                              maxInputFrames: sMaxInputFrames)
    }

    // MARK: - 预分配

    private func prepareRenderBuffers(channels: Int) {
        releaseRenderBuffers()
        renderABLChannelCount = channels
        renderPlanes = (0..<channels).map { _ in
            UnsafeMutablePointer<Float>.allocate(capacity: Self.maxFrames)
        }
        // AudioBufferList 是变长结构：n 个 AudioBuffer 需要额外 (n-1) 份
        let size = MemoryLayout<AudioBufferList>.size
            + (channels - 1) * MemoryLayout<AudioBuffer>.size
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        let abl = raw.assumingMemoryBound(to: AudioBufferList.self)
        abl.pointee.mNumberBuffers = UInt32(channels)
        let list = UnsafeMutableAudioBufferListPointer(abl)
        for c in 0..<channels {
            list[c] = AudioBuffer(mNumberChannels: 1,
                                  mDataByteSize: UInt32(Self.maxFrames * 4),
                                  mData: UnsafeMutableRawPointer(renderPlanes[c]))
        }
        renderABL = abl
    }

    private func releaseRenderBuffers() {
        for p in renderPlanes { p.deallocate() }
        renderPlanes = []
        if let abl = renderABL {
            UnsafeMutableRawPointer(abl).deallocate()
            renderABL = nil
        }
        renderABLChannelCount = 0
    }

    // MARK: - 输入单元（读 BlackHole）

    private func setupInputUnit(device: ChannelSwapDeviceInfo, sourceChannels: Int) throws {
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &desc) else {
            throw SwapDriverError.componentNotFound("HALOutput")
        }
        var unit: AudioUnit?
        guard AudioComponentInstanceNew(component, &unit) == noErr, let u = unit else {
            throw SwapDriverError.instanceCreateFailed("输入单元")
        }
        inputUnit = u

        // 只开 bus1 输入；bus0 关闭（我们只读 BlackHole，不往里写）
        var one: UInt32 = 1
        var zero: UInt32 = 0
        var status = AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input, 1, &one, UInt32(MemoryLayout<UInt32>.size))
        guard status == noErr else { throw SwapDriverError.propertyFailed("EnableIO(in,1)", status) }
        status = AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Output, 0, &zero, UInt32(MemoryLayout<UInt32>.size))
        guard status == noErr else { throw SwapDriverError.propertyFailed("EnableIO(out,0)", status) }

        var dev = device.id
        status = AudioUnitSetProperty(u, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { throw SwapDriverError.propertyFailed("CurrentDevice(输入)", status) }

        // 客户端格式：Float32 非交错（每个声道一个 buffer，便于按声道取用）
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
                        | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: UInt32(sourceChannels), mBitsPerChannel: 32, mReserved: 0)
        status = AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output, 1, &asbd, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        guard status == noErr else { throw SwapDriverError.propertyFailed("输入 StreamFormat", status) }

        var callback = AURenderCallbackStruct(
            inputProc: { refCon, _, _, _, frameCount, _ -> OSStatus in
                Unmanaged<ChannelSwapAudioDriver>
                    .fromOpaque(refCon).takeUnretainedValue()
                    .handleInput(frameCount: frameCount)
            },
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        status = AudioUnitSetProperty(u, kAudioOutputUnitProperty_SetInputCallback,
            kAudioUnitScope_Global, 0, &callback,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard status == noErr else { throw SwapDriverError.propertyFailed("SetInputCallback", status) }

        status = AudioUnitInitialize(u)
        guard status == noErr else { throw SwapDriverError.initializeFailed("输入单元", status) }
    }

    // MARK: - 输出单元（写真实设备）

    private func setupOutputUnit(device: ChannelSwapDeviceInfo,
                                 isSystemDefault: Bool,
                                 identityMap: [Int32]) throws {
        // ★ 单元类型选择：
        //   目标设备 == 系统默认输出 → DefaultOutput（该路径已听感确认可用）
        //   否则 → HALOutput + 显式绑设备（DefaultOutput 会写错设备）
        let subtype: OSType = isSystemDefault
            ? kAudioUnitSubType_DefaultOutput
            : kAudioUnitSubType_HALOutput

        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output,
            componentSubType: subtype,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &desc) else {
            throw SwapDriverError.componentNotFound(isSystemDefault ? "DefaultOutput" : "HALOutput")
        }
        var unit: AudioUnit?
        guard AudioComponentInstanceNew(component, &unit) == noErr, let u = unit else {
            throw SwapDriverError.instanceCreateFailed("输出单元")
        }
        outputUnit = u

        var status: OSStatus = noErr
        if !isSystemDefault {
            var one: UInt32 = 1
            var zero: UInt32 = 0
            status = AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO,
                kAudioUnitScope_Output, 0, &one, UInt32(MemoryLayout<UInt32>.size))
            guard status == noErr else { throw SwapDriverError.propertyFailed("EnableIO(out,0)", status) }
            status = AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO,
                kAudioUnitScope_Input, 1, &zero, UInt32(MemoryLayout<UInt32>.size))
            guard status == noErr else { throw SwapDriverError.propertyFailed("EnableIO(in,1)=0", status) }

            var dev = device.id
            status = AudioUnitSetProperty(u, kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0, &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
            guard status == noErr else {
                throw SwapDriverError.propertyFailed("CurrentDevice(输出)", status)
            }
        }

        // 客户端格式：交错 Float32（与探针里听感确认可用的形态一致）
        let channels = UInt32(takeChannels)
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4 * channels, mFramesPerPacket: 1, mBytesPerFrame: 4 * channels,
            mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
        status = AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input, 0, &asbd, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        guard status == noErr else { throw SwapDriverError.propertyFailed("输出 StreamFormat", status) }

        // ★ 声道布局必须显式声明：
        //   头文件明确 kAudioUnitProperty_StreamFormat "cannot specify channel layout"。
        //   缺了它 HAL 不知道这 N 个缓冲对应哪些喇叭（实测表现为丢声道）。
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = ChannelSwapAudioDriver.layoutTag(for: takeChannels)
        layout.mNumberChannelDescriptions = 0
        status = AudioUnitSetProperty(u, kAudioUnitProperty_AudioChannelLayout,
            kAudioUnitScope_Input, 0, &layout, UInt32(MemoryLayout<AudioChannelLayout>.size))
        if status != noErr {
            // 布局失败不致命（部分设备/单元可能不需要），但要记录，便于排查丢声道
            Log.warn("声道交换：设置声道布局失败（\(CoreAudioHelpers.describe(status))），继续")
        }

        // ★★ ChannelMap 必须**始终**设置（这里恒等）—— 依据实测：
        //    不设置时 HAL 会丢弃部分声道（实测只播出 6 路）。
        //    ⚠️ 但它**不负责交换**：HALOutput 直通路径会忽略该属性，
        //       交换由渲染回调里的置换表完成（见文件头）。
        var mutableMap = identityMap
        status = AudioUnitSetProperty(u, kAudioOutputUnitProperty_ChannelMap,
            kAudioUnitScope_Input, 0, &mutableMap,
            UInt32(MemoryLayout<Int32>.size * takeChannels))
        guard status == noErr else {
            throw SwapDriverError.propertyFailed("ChannelMap（不可省略）", status)
        }
        // 回读校验：noErr 不代表生效（只是这里无法再回读"是否真的换了"）
        var readBack = [Int32](repeating: -9, count: takeChannels)
        var size = UInt32(MemoryLayout<Int32>.size * takeChannels)
        status = AudioUnitGetProperty(u, kAudioOutputUnitProperty_ChannelMap,
            kAudioUnitScope_Input, 0, &readBack, &size)
        if status == noErr, readBack != identityMap {
            Log.warn("声道交换：ChannelMap 回读不一致（写入 \(identityMap)，回读 \(readBack)）")
        }

        // 渲染回调
        var callback = AURenderCallbackStruct(
            inputProc: { refCon, _, _, _, frameCount, ioData -> OSStatus in
                Unmanaged<ChannelSwapAudioDriver>
                    .fromOpaque(refCon).takeUnretainedValue()
                    .handleOutput(frameCount: frameCount, ioData: ioData)
            },
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        status = AudioUnitSetProperty(u, kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input, 0, &callback,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard status == noErr else { throw SwapDriverError.propertyFailed("SetRenderCallback", status) }

        status = AudioUnitInitialize(u)
        guard status == noErr else { throw SwapDriverError.initializeFailed("输出单元", status) }
    }

    /// 依声道数选标准布局 tag（1-based 语义：第 3/第 4 声道 = 中置/低音）
    static func layoutTag(for channels: Int) -> AudioChannelLayoutTag {
        switch channels {
        case 8...: return kAudioChannelLayoutTag_MPEG_7_1_C   // L R C LFE Ls Rs Rls Rrs
        case 6...7: return kAudioChannelLayoutTag_MPEG_5_1_A // L R C LFE Ls Rs
        default: return kAudioChannelLayoutTag_DiscreteInOrder
        }
    }

    // MARK: - ★ 实时回调（禁止：加锁 / 分配 / 日志 / Dispatch）

    /// 输入回调：`AudioUnitRender` 取源数据 → 取前 N 声道 → 写入环形缓冲
    private func handleInput(frameCount: UInt32) -> OSStatus {
        sInCallbacks += 1
        // ★ 回调节拍诊断（实时安全：读时钟 + 写整数，不加锁、不分配、不写日志）。
        //   ⚠️ 绝不能用 `print`/`Log` 在这里输出 —— 见文件头的实时线程纪律。
        let inTick = DispatchTime.now().uptimeNanoseconds
        if sLastInputTick != 0 {
            let gapMs = Double(inTick &- sLastInputTick) / 1_000_000
            if gapMs > sMaxInputGapMs { sMaxInputGapMs = gapMs }
        }
        sLastInputTick = inTick
        guard let ring, let abl = renderABL else { return noErr }

        let frames = min(Int(frameCount), Self.maxFrames)
        if frames > sMaxInputFrames { sMaxInputFrames = frames }
        guard frames > 0 else { return noErr }

        let list = UnsafeMutableAudioBufferListPointer(abl)
        for c in 0..<list.count {
            list[c].mDataByteSize = UInt32(frames * 4)
            list[c].mNumberChannels = 1
        }

        if diagnosticToneEnabled {
            // 诊断自测：合成逐段序列（第 i 段只有第 i 个声道出声，频率 200+100*i）
            let segFrames = max(Int(sampleRate * Double(diagnosticToneSegmentMs) / 1000), 1)
            for f in 0..<frames {
                let absFrame = tonePhase + Int64(f)
                let seg = Int(absFrame / Int64(segFrames)) % max(takeChannels, 1)
                for c in 0..<min(takeChannels, list.count) {
                    guard let rawPlane = list[c].mData else { continue }
                    let p = rawPlane.assumingMemoryBound(to: Float.self)
                    if c == seg {
                        let freq = 200.0 + 100.0 * Double(c)
                        let t = Double(absFrame) / sampleRate
                        var v = sin(2 * .pi * freq * t) * 0.5
                        // 段内首尾 30ms 淡入淡出，避免切换爆音
                        let posInSeg = Double(absFrame % Int64(segFrames)) / sampleRate * 1000
                        if posInSeg < 30 { v *= posInSeg / 30 }
                        p[f] = Float(v)
                    } else {
                        p[f] = 0
                    }
                }
            }
            tonePhase += Int64(frames)
            sFramesIn += Int64(frames)
            // 直接写入环形缓冲（跳过读设备）
            if ring.fillFrames > (ring.capacity * 3) / 4 { return noErr }
            writeToRing(frames, from: list)
            return noErr
        }

        // ★ 必须调用 AudioUnitRender：输入回调的 ioData 不携带音频
        var timestamp = AudioTimeStamp()
        let status = AudioUnitRender(inputUnit!, nil, &timestamp, 1, UInt32(frames), abl)
        guard status == noErr else {
            sRenderFailures += 1
            return noErr
        }

        // 水位过高（源钟快于目标）→ 丢掉整块让消费者追上，避免无限积压
        if ring.fillFrames > (ring.capacity * 3) / 4 { return noErr }

        writeToRing(frames, from: list)
        return noErr
    }

    /// 把上游各 plane 的样本写入环形缓冲（**按平面分段**，至多两段）。
    ///
    /// ## 为什么必须分段（本文件修过的越界缺陷）
    ///
    /// 环形缓冲是"每声道一个 plane、容量各 `capacity` 帧"的布局
    /// （`plane(c) = store + c*capacity`），而写游标的**平面内偏移**是回绕的
    /// （`pos = w & mask`）。所以一次回调跨过回绕点时，`[pos, capacity)` 与
    /// `[0, 余量)` 是**两段互不连续**的内存：
    ///
    /// 旧实现直接 `memcpy(plane(c) + pos, src, writable * 4)`，而 `writable`
    /// 只被"总剩余空间"限制、没有考虑 `pos + writable ≤ capacity`，于是在回绕点：
    /// * 前几个声道把样本写进了**下一个 plane 的开头**（声道内容互相污染）；
    /// * 最后一个声道直接**越过 `store` 的 `capacity*channels` 分配区**（堆越界写）。
    ///
    /// 触发条件是"回调帧数不整除 `capacity`"（例如 48kHz 下 `capacity=16384`
    /// 而回调 480 帧）—— 512 等 2 的幂帧数恰好不触发，所以它长期潜伏。
    ///
    /// ## 实时线程纪律
    ///
    /// 只用指针算术与定长局部元组，**不分配、不加锁、不查表**。
    @inline(__always)
    private func writeToRing(_ frames: Int, from list: UnsafeMutableAudioBufferListPointer) {
        guard let ring else { return }
        let take = min(takeChannels, list.count)
        guard take > 0 else { return }

        // 分段：每写满一段就 `commitWrite`（写游标随之推进到下一段起点），
        // 再带**剩余待写量**调下一段 —— 与 `beginWrite` 的新语义配套，不需要偏移参数。
        var remaining = frames
        var isFirstSegment = true
        while remaining > 0 {
            let (pos, writable) = ring.beginWrite(remaining)
            guard writable > 0 else { break }
            // 源缓冲里的本段起点 = 总帧数 − 剩余量
            let offset = frames - remaining
            for c in 0..<take {
                guard let raw = list[c].mData else { continue }
                memcpy(ring.plane(c) + pos, raw + offset * MemoryLayout<Float>.size,
                       writable * MemoryLayout<Float>.size)
                if isFirstSegment {
                    // 抽样统计非零（每 16 帧取 1，实时线程上不做重活）。
                    // ⚠️ 只在首段统计：第二段与首段是同一批帧的两半，两段都算会重复计入。
                    let p = raw.assumingMemoryBound(to: Float.self)
                    var nz = 0
                    var i = 0
                    while i < writable { if abs(p[i]) > 1e-6 { nz += 1 }; i += 16 }
                    sNonZeroInFrames += Int64(nz)
                }
            }
            ring.commitWrite(writable)
            sFramesIn += Int64(writable)
            remaining -= writable
            isFirstSegment = false
        }
    }

    /// 渲染回调用的**混音装配参数**（值类型，按值传递）。
    ///
    /// 为什么单独成型：渲染回调与搬运实现之间要传 5 个标量，
    /// 散着传容易漏（本项目已因"参数散落各处"错过多次）；打包成值类型后
    /// 实时线程上零引用计数、零分配。
    struct ChannelSwapMixParams: Equatable, Sendable {
        /// 线性增益；**0 表示混音关闭**（此时其余字段无意义）
        var gain: Float
        /// 被衰减的那条上游的 plane 索引（API 0-based）
        var sourceIndex: Int
        /// 叠加目标输出声道（API 0-based）；−1 = 无
        var targetIndex: Int
        /// 与 `sourceIndex` 配对的那条上游（直通进 CH-O、不衰减）；−1 = 无
        var directIndex: Int
        /// 配对中"不是 CH-O"的那条下游声道（不连 ⇒ 静音）；−1 = 无
        var cutIndex: Int

        /// 不混音（交换 / 直通 / 混音计划不可用）
        static let off = ChannelSwapMixParams(gain: 0, sourceIndex: 0,
                                             targetIndex: -1, directIndex: -1, cutIndex: -1)
    }

    /// ★★ 环形缓冲 → 交错输出缓冲的**唯一**搬运实现（交换与混音共用）。
    ///
    /// ## 为什么必须独立成函数（这是一次真机静音回归换来的）
    ///
    /// 在此之前的写法是"两个分支各自遍历"：`if mixGain == 0 { 按置换表直取 }
    /// else { 混音 }`。`ed3cc8e` 那次重构想把两条分支合并成同一套分段遍历，
    /// 于是把无混音的搬运逻辑塞进了 `else` 内部 —— 但外层守卫 `mixGain != 0`
    /// **忘了拆掉**。后果：`mixGain == 0`（交换 / 直通）时整段被跳过，
    /// `ioData` 一个样本都没被写过 ⇒ **只有混音模式出声，交换与直通全静音**。
    ///
    /// 当时没人拦住的直接原因：`handleOutput` 是私有的、只能由真实音频回调驱动，
    /// 单测（走 `ChannelSwapMocks`）根本走不到这段 ⇒ CI 全绿、真机哑。
    ///
    /// ⇒ 现在唯一实现是本函数（internal + 纯参数 ⇒ 单测可直接调），
    ///   并有 `ChannelSwapRenderTests` 的"哨兵"用例锁死
    ///   **每一帧、每个声道都必须被显式写入**。
    ///
    /// ⚠️ 因此这里**不允许**再出现任何"按功能开关整体跳过搬运"的分支：
    ///   功能开关只能决定**每个声道怎么取值**，不能决定**要不要写**。
    ///
    /// ## 分段（物理回绕）
    ///
    /// 一次 `beginRead` 可能跨过平面回绕点，此时 `[pos, capacity)` 与 `[0, 余量)`
    /// 是两段互不连续的内存。旧实现把 `read` 帧当一段连续内存去读
    /// `plane(c) + pos`，回绕点读到的是**下一个 plane 的开头**（声道内容错位）。
    ///
    /// ## 实时线程纪律
    ///
    /// 只用指针算术与按值传递的值类型，**不分配、不加锁、不写日志、不查表**。
    @inline(__always)
    static func copyRingToInterleaved(ring: SwapRingBuffer,
                                      dst: UnsafeMutablePointer<Float>,
                                      stride: Int,
                                      usable: Int,
                                      frames: Int,
                                      read: Int,
                                      permute: [Int],
                                      mix: ChannelSwapMixParams) {
        // 混音只在装配成功时才有 plane；`gain == 0` 时两者均为 nil ⇒ 走直取分支。
        //
        // ★ 与 `sourceIndex` 配对的那条上游（直通、不衰减）：
        //   仅当它与被衰减那条确实是**不同**的 plane 时才叠加 —— 否则
        //   `a×g + a` 会变成纯电平翻倍（配对相同本身就是配置错误）。
        let mixSourcePlane: UnsafeMutablePointer<Float>? =
            mix.gain != 0 ? ring.plane(mix.sourceIndex) : nil
        let mixDirectPlane: UnsafeMutablePointer<Float>? =
            (mix.gain != 0 && mix.directIndex >= 0 && mix.directIndex != mix.sourceIndex)
            ? ring.plane(mix.directIndex) : nil

        // ★★ 混音语义（用户明确定义，2026-09）：
        //
        //   CH-I = 被施加衰减的那条**上游**声道（配置项）
        //   CH-O = 下游输出声道；**CH-O 自己那条内容直通、不衰减**，
        //          另条上游（未被选中的那条）也直通、不衰减
        //   两条上游**都进 CH-O**，只是被选中的那条乘 gain、另一条直通。
        //
        //   选 CH-I=3:  CH4-O = CH4-I（直通） + CH3-I × gain
        //   选 CH-I=4:  CH4-O = CH3-I（直通） + CH4-I × gain
        //   CH3-O（非 CH-O 的那条）不连 ⇒ 静音
        //
        // 两个空间（用户提出的命名，勿混）：
        //   上游 plane：CH3-I/CH4-I  ← 只读
        //   下游输出：  CH3-O/CH4-O  ← 只写
        //
        // ⚠️ 已走过的四次错误（都被用户逐条纠正）：
        //   ① 用上游索引决定衰减哪条下游声道 → 衰减落错声道；
        //   ② 对下游目标整体再乘增益 → 把该条的直通内容也压小了；
        //   ③ 没切断上游那条的输出 → 未衰减信号从 CH3-O 漏出；
        //   ④ 把"被衰减的"与"直通的"搞反 → 衰减加在了不该加的那条上。
        // 分段：每读满一段就 `commitRead`（读游标随之推进到下一段起点），
        // 再带剩余待读量调下一段 —— 与 `writeToRing` 完全对称。
        var remaining = read
        while remaining > 0 {
            let seg = ring.beginRead(remaining)
            guard seg.readable > 0 else { break }
            let pos = seg.pos
            let count = seg.readable
            // 本段在 dst 里的起始帧 = 总帧数 − 剩余量
            let baseFrame = read - remaining
            for f in 0..<count {
                let base = (baseFrame + f) * stride
                for c in 0..<usable {
                    // ★ 交换在这里发生：目标第 c 声道取源第 permute[c] 声道
                    //   （permute 已预计算，长度 = takeChannels；恒等即不交换）
                    let srcCh = (c < permute.count) ? permute[c] : c
                    if mix.gain != 0, c == mix.targetIndex, let src = mixSourcePlane {
                        // CH-O：被选中那条 × gain  +  另一条 × 1
                        let rate = (src + pos)[f] * mix.gain
                        var direct: Float = 0
                        if let dp = mixDirectPlane { direct = (dp + pos)[f] }
                        dst[base + c] = rate + direct
                    } else if mix.gain != 0, c == mix.cutIndex {
                        // 配对中不是 CH-O 的那条：不连 ⇒ 静音
                        dst[base + c] = 0
                    } else {
                        // ★ 无混音（交换 / 直通）：按置换表直取。
                        //   ⚠️ 这条分支**必须**在 mixGain == 0 时也执行 ——
                        //      它一度被外层 `if mixGain != 0` 挡住，见函数头注释。
                        dst[base + c] = (ring.plane(srcCh) + pos)[f]
                    }
                }
                if usable < stride { for c in usable..<stride { dst[base + c] = 0 } }
            }
            ring.commitRead(count)
            remaining -= count
        }
    }

    /// 渲染回调"正常分支"的统计输出（值类型，栈上传递、零分配）。
    struct RenderCounters: Equatable, Sendable {
        /// 欠载次数（目标钟快于源）
        var underruns: Int64 = 0
        /// 欠载后"重新居中"的实际次数（每次都是一次数据跳变）
        var resyncs: Int64 = 0
        /// 为把水位拉回目标而丢弃的最旧帧数
        var droppedStaleFrames: Int64 = 0
        /// ★ 下沿微调丢掉的帧数（死区内每 N 个回调丢 1 帧，与 `droppedStaleFrames` 分开）
        var lowerTrimmedFrames: Int64 = 0
        /// 首次回调对齐水位时丢掉的启动积压（帧）
        var startupAlignedFrames: Int64 = 0
        /// 因数据不足被静音填充的帧数
        var starvedFrames: Int64 = 0
        /// 本次观测到的水位峰值（帧）
        var peakFillFrames: Int = 0
    }

    /// ★★ 渲染回调**正常分支的主体**（`internal` ⇒ 单测可直接驱动）。
    ///
    /// 职责：水位收敛 → 取数 → 欠载兜底 → 搬进 `dst` → 余量清零 → 提交读游标。
    ///
    /// ## 为什么把整段都放进来（而不是只抽"搬运"）
    ///
    /// v0.1.3 的静音回归形态是"**搬运调用点**被 `if mixGain != 0` 包住"。
    /// 只把搬运抽成内部函数、测试直接调它，**抓不到"调用点被守卫"这类回归**。
    /// ⇒ 因此这里连水位判定与 `commitRead` 一起纳入，测试驱动的是整段正常路径。
    /// `handleOutput` 只剩下"自测分支 vs 正常分支"的选择与逐路峰值测量。
    ///
    /// ## 低目标水位（BUG1 的修法）
    ///
    /// 延迟只能靠**推进读游标**降低：写侧丢新块只能阻止水位继续上涨，
    /// 永远无法把已经积压的延迟收回来。因此：
    /// * 水位超过 `目标 + 死区` 时，按比例丢弃**最旧**数据（分多个回调缓慢收敛，
    ///   而不是一步跳回目标 ⇒ 不产生可听的跳变）；
    /// * **首次输出回调**把水位一次性对齐到目标，丢掉启动期积压（见下方说明）；
    /// * 水位在目标附近时**不动手**（死区），否则会追着噪声调。
    @discardableResult
    @inline(__always)
    static func renderFromRing(ring: SwapRingBuffer,
                               dst: UnsafeMutablePointer<Float>,
                               stride: Int,
                               usable: Int,
                               frames: Int,
                               permute: [Int],
                               mix: ChannelSwapMixParams,
                               targetFillFrames: Int,
                               deadbandFrames: Int,
                               isFirstOutputCallback: Bool,
                               averageFillFrames: inout Int,
                               prefillAttempts: inout Int,
                               lowerTrimCounter: inout Int,
                               counters: inout RenderCounters) -> Int {
        counters.peakFillFrames = max(counters.peakFillFrames, ring.fillFrames)

        // ★ 运行平均水位（一阶低通，只在 RT 线程写）：诊断用它显示"代表性延迟"，
        //   避免把"一个回调内的 512 帧锯齿"当成延迟在忽大忽小。
        // ⚠️ 必须**四舍五入**而不是直接截断整除：整数低通在接近目标时增量会被截断成 0，
        //    平均水位会永远停在距真实水位最多 `divisor-1` 帧的地方（实测停滞在 961/1024，
        //    偏差 63 帧）。四舍五入后偏差 ≤ divisor/2（约 0.7ms，诊断足够精确）。
        let fillDelta = ring.fillFrames - averageFillFrames
        averageFillFrames += (fillDelta + (fillDelta >= 0 ? fillAverageDivisor / 2
                                                          : -(fillAverageDivisor / 2)))
            / fillAverageDivisor

        // ★★ 首次输出回调：把水位**一次性对齐到目标**。
        //
        //   为什么必须做：输入单元先启动、输出设备后启动，而 HDMI/eARC 设备
        //   从 start 到第一次回调可能慢几十毫秒 —— 这段时间输入已经把 ring
        //   灌到几十甚至上百毫秒的水位（真机实测峰值 96ms）。
        //   此刻**还没有任何音频播出**，直接对齐不会产生可听的不连续；
        //   放任不管的话，这段积压会一直跟着整条链路（真机实测：
        //   切换模式后延迟从 30ms 跳到 77~96ms，而且再也不会自己回来）。
        //
        //   ⚠️ 对齐量单独计入 `startupAlignedFrames`（与运行期收敛的
        //      `droppedStaleFrames` 分开）：它确实是"被丢掉的数据"、必须可见，
        //      但语义完全不同 —— **只在装配后的第一拍出现一次、之后不增长**。
        if isFirstOutputCallback, targetFillFrames > 0 {
            let before = ring.fillFrames
            ring.resync(targetFillFrames)
            let aligned = before - ring.fillFrames
            if aligned > 0 { counters.startupAlignedFrames += Int64(aligned) }
        }

        // ── 启动预填充：水位还没到目标就先静音等待、**不消费** ────────────
        //
        //   不消费是必须的：消费就等于把刚积累的数据立刻读走，水位永远填不满。
        //   代价是装配后多几十毫秒静音 —— 但切换模式本来就有短暂中断，
        //   用户对这一小段无感知；换来的是"每次装配后的延迟都等于目标"。
        if prefillAttempts >= 0, targetFillFrames > 0 {
            if ring.fillFrames >= targetFillFrames {
                prefillAttempts = -1                       // 达标：开始正常消费
            } else if prefillAttempts < Self.maxPrefillCallbacks {
                prefillAttempts += 1
                // 不计数 `starvedFrames`：这是**主动等待**，不是数据不足造成的损伤
                memset(dst, 0, frames * stride * MemoryLayout<Float>.size)
                return 0
            } else {
                // 超时兜底：源端异常/漂移极大时永远填不满 —— 宁可带着偏低的水位跑，
                // 也不能把链路永久静音（那是"静默失效"里最严重的一种）
                prefillAttempts = -1
            }
        }

        let fill = ring.fillFrames
        if targetFillFrames > 0, fill > targetFillFrames + deadbandFrames {
            let drop = Self.staleDropFrames(fill: fill,
                                            target: targetFillFrames,
                                            deadband: deadbandFrames,
                                            limit: frames)
            if drop > 0 {
                counters.droppedStaleFrames += Int64(ring.discardStale(drop))
            }
        }

        // ★★ 下沿微调：水位落在死区内时，**每 `lowerTrimInterval` 个回调丢 1 帧**。
        //
        //   为什么必须有：死区 `[目标, 目标+死区]` 内**没有任何控制** —— 丢旧只在
        //   超过上限时动手，欠载 resync 只在下限兜底。于是水位一旦因冲高落进这个
        //   区间，就**永远回不到目标**。真机实测（两次独立复现，2026-09-26）：
        //     · 睡眠唤醒后停在 881 / 923（目标 512，差值 ≈ 7.7~9ms）；
        //     · 此后丢旧不再增长，水位就是不动，只能"关掉再打开引擎"才重置。
        //
        //   速率"每 4 个回调丢 1 帧" ≈ 0.1% 速率差（约 1.7 音分）、约 8 秒回到目标：
        //   既听不出来，也不会像丢旧那样一次跳几十上百帧。
        //   超过死区仍交给丢旧（更快）；两者**互斥**，否则同一次回调会叠两次丢弃。
        if targetFillFrames > 0,
           fill > targetFillFrames,
           fill <= targetFillFrames + deadbandFrames {
            lowerTrimCounter += 1
            if lowerTrimCounter >= Self.lowerTrimInterval {
                lowerTrimCounter = 0
                let trimmed = ring.discardStale(1)
                if trimmed > 0 { counters.lowerTrimmedFrames += Int64(trimmed) }
            }
        } else {
            // 水位不在死区内（偏低、或高到该走丢旧）→ 节拍重新开始
            lowerTrimCounter = 0
        }

        // ⚠️⚠️ 可读总量必须取 `fillFrames`（= 写游标 − 读游标）。
        //      **不能**用 `beginRead` 的第三个返回值 —— 那是"**单段**可读帧数"
        //      （被 `capacity - pos` 截断），而它曾被当成总长用（`ed3cc8e` 改签名时
        //      留下的语义错位），后果是：
        //        · 本次只消费了 `capacity - pos` 帧，其余被 memset 清零 ⇒ **周期性静音**；
        //        · 消费量长期少于写入量 ⇒ 水位持续上涨 ⇒ 低水位收敛不停丢旧数据。
        //      真机表现："声音有规律断续 + 丢旧一直涨，切换几次又好了"。
        //
        //      为什么"切换几次又好"：`frames` 整除 `capacity` 时（512 | 16384）
        //      读游标永远落在 512 的整数倍上，`capacity - pos ≥ frames` 恒成立 ⇒ 从不截断；
        //      一旦低水位收敛用**非对齐步长**推进过读游标，相位被打乱，
        //      此后每个容量周期都会撞进那个窗口。重新装配会重建 ring（相位归零）⇒ 暂时正常。
        let available = ring.fillFrames
        let read = min(frames, available)

        // 水位过低（目标钟快于源）→ 欠载，重新居中避免持续"半空"
        if available < frames / 2 {
            counters.underruns += 1
            if available < frames {
                ring.resync(frames)
                counters.resyncs += 1
            }
        }

        if read > 0 {
            // ★★ 搬运只有这一处实现（`copyRingToInterleaved`），交换与混音共用。
            //
            //   ⚠️ 绝不能再在这里加 `if mixGain != 0` 这类"按功能开关整体跳过"的守卫：
            //      交换/直通模式下 `mixGain == 0`，那样写会让 dst 一个样本都不写
            //      ⇒ **整条链路静音**。v0.1.3 的真机回归就是这么来的
            //      （用户实测："只有混音模式出声，交换与直通都没有声音"）。
            copyRingToInterleaved(ring: ring,
                                  dst: dst,
                                  stride: stride,
                                  usable: usable,
                                  frames: frames,
                                  read: read,
                                  permute: permute,
                                  mix: mix)
            // 余量必须清零：绝不能把未初始化内存送进设备（会爆音）
            if read < frames {
                // ★ 这段静音是"数据不足"的真实损伤，必须计数（见 `sStarvedFrames`）
                counters.starvedFrames += Int64(frames - read)
                memset(dst + read * stride, 0, (frames - read) * stride * MemoryLayout<Float>.size)
            }
        } else {
            // ★ 整块静音（连一帧数据都没有）**同样必须计数**。
            //   早先这里漏了：于是"欠载重置 N 次"看起来"静音填充 0 帧"，
            //   而每次欠载实际都是一整块（512 帧）静音 —— 真机在 192kHz 下
            //   出现 4 次重置时就是把 4 块静音显示成了 0。丢音不能因为走的是
            //   else 分支就隐形。
            counters.starvedFrames += Int64(frames)
            memset(dst, 0, frames * stride * MemoryLayout<Float>.size)
        }

        // 读游标已由 `copyRingToInterleaved` 逐段提交（见那里的说明）
        return read
    }

    /// 按延迟目标解析出水位参数（并记录"实际可达最低延迟"）。
    ///
    /// ⚠️ 必须在**首拍**用真实的输出回调帧数再算一次：水位至少要装得下一个
    ///    输出回调（否则每次回调都欠载），而回调帧数只有运行时才知道。
    private func applyLatencyTarget(sampleRate rate: Double, callbackFrames: Int) {
        let r = resolveCurrentLatencyTarget(sampleRate: rate, callbackFrames: callbackFrames)
        targetFillFrames = r.target
        fillDeadbandFrames = r.deadband
        sMinAchievableLatencyMs = r.minAchievableMs
    }

    /// 用**当前请求值**（`setTargetLatency` 写入的值）解析水位参数。
    ///
    /// ⚠️ 独立成 `internal` 方法**只为可测**：`setTargetLatency` → 这里 → 水位参数
    /// 是真机上曾经整段断掉的那条链路（协议给了空默认实现，本类忘了覆盖），
    /// 而当时没有任何测试覆盖它 —— 纯函数测试再绿也发现不了。
    func resolveCurrentLatencyTarget(sampleRate rate: Double, callbackFrames: Int)
        -> (target: Int, deadband: Int, minAchievableMs: Double) {
        let requested = requestedLatencyMs ?? ChannelSwapSettings.defaultTargetLatencyMs
        return Self.resolveLatencyTarget(sampleRate: rate,
                                         requestedMs: requested,
                                         callbackFrames: callbackFrames)
    }

    /// 把"延迟目标"解析成水位参数（**纯函数 ⇒ 可单测**）。
    ///
    /// 三条约束决定了实际能压到多低：
    /// 1. **死区 ≥ 一个输出回调**：一个回调就一次性读走整个缓冲，死区比它小
    ///    会让水位在正常抖动下反复穿越阈值、把丢弃碎片化；
    /// 2. **水位 ≥ 2 个回调**：低于此值几乎每次回调都贴着欠载边缘；
    /// 3. 稳态延迟 ≈ **目标水位 + 死区**（丢弃把水位压在阈值下方一点点）。
    ///
    /// ⇒ **实际最低平均延迟 = 2×回调 / 采样率**（水位下沿没有控制，
    ///   稳态平均水位就贴在目标水位 = 2×回调 上；死区只决定"上沿多久丢一次"，
    ///   不决定平均延迟）。本机 512 帧回调、48kHz 下 ≈ **21ms**；
    ///   把设备缓冲改成 256 帧则 ≈ **11ms**。
    ///
    /// - Returns: `target`（目标水位帧）、`deadband`（死区帧）、
    ///   `minAchievableMs`（实际最低稳态延迟）
    static func resolveLatencyTarget(sampleRate: Double,
                                     requestedMs: Double,
                                     callbackFrames: Int)
        -> (target: Int, deadband: Int, minAchievableMs: Double) {
        let rate = max(sampleRate, 1)
        let callback = max(callbackFrames, 1)
        let requested = min(max(requestedMs, ChannelSwapSettings.latencyRangeMs.lowerBound),
                            ChannelSwapSettings.latencyRangeMs.upperBound)
        let deadband = max(callback, Int(rate * deadbandMinMs / 1000))
        let minFill = 2 * callback
        // ★ 目标水位**直接**对应请求的延迟（"设多少就是多少"）。
        //   ⚠️ 这里曾经是 `请求 − 死区`，于是用户设 30ms 实际只得到 22ms 的水位目标，
        //      再叠加"装配时水位可能填不满"，就用真机出现了
        //      "设 30ms 实际 13ms/21ms、改缓冲也没反应"这种无法解释的现象。
        //      死区只决定**上沿多久丢一次**，不该参与"目标是多少"。
        let target = max(Int(rate * requested / 1000), minFill)
        // ★ 可达的**平均**延迟基准是"目标水位"，不是"目标 + 死区"：
        //   死区只是**丢弃阈值（上沿）**，水位并不会停在它那里 ——
        //   下沿没有任何控制，稳态平均水位就贴在目标水位附近。
        //   早期按"目标 + 死区"算，于是 UI 显示"设备最低 32ms"而真机实测 21ms，
        //   又是一次"显示的与跑的不是一回事"。
        let minAchievableMs = Double(minFill) / rate * 1000
        return (target, deadband, minAchievableMs)
    }

    /// 首拍之前用的**保守**回调帧数估计（约 10.7ms：常见设备缓冲）。
    static func conservativeCallbackFrames(rate: Double) -> Int {
        max(Int(rate * 0.011), 1)
    }

    /// 低水位收敛策略（**纯函数 ⇒ 可单测**）：本次回调应当丢弃多少**最旧**帧。
    ///
    /// * 水位未超过 `目标 + 死区` → 0（死区：目标附近绝不动作，否则会追噪声）
    /// * 否则丢掉"超出目标部分"的 `1/fillConvergenceDivisor`，
    ///   至少 1 帧、至多 `limit` 帧 —— 分多个回调缓慢收敛，避免一次跳变。
    ///
    /// ⚠️ 判据是 **`目标 + 死区`**，不是"某个远离目标的上限"：用后者会高位黏滞 ——
    ///    水位只要没超过那个上限就永远不被修正（真机实测停在 77ms 不动）。
    static func staleDropFrames(fill: Int, target: Int, deadband: Int, limit: Int) -> Int {
        guard target >= 0, deadband >= 0, limit > 0 else { return 0 }
        guard fill > target + deadband else { return 0 }
        let excess = fill - target
        guard excess > 0 else { return 0 }
        let proportional = excess / fillConvergenceDivisor
        return min(max(proportional, 1), limit)
    }

    /// 渲染回调：环形缓冲 → 交错输出缓冲（**交换在本回调内按置换表完成**）
    private func handleOutput(frameCount: UInt32,
                              ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
        sOutCallbacks += 1
        // ★ 回调节拍诊断：输出侧的"洞"就是水位冲高的直接来源
        //   （洞期间输入照写、输出不读 ⇒ 水位上涨）。
        let outTick = DispatchTime.now().uptimeNanoseconds
        if sLastOutputTick != 0 {
            let gapMs = Double(outTick &- sLastOutputTick) / 1_000_000
            if gapMs > sMaxOutputGapMs { sMaxOutputGapMs = gapMs }
        }
        sLastOutputTick = outTick
        guard let ring, let ioData else { return noErr }
        let frames = Int(frameCount)

        let list = UnsafeMutableAudioBufferListPointer(ioData)
        guard list.count > 0, let rawOut = list[0].mData else { return noErr }
        let dst = rawOut.assumingMemoryBound(to: Float.self)
        // 交错：一个缓冲里含 mNumberChannels 个声道；用 mNumberChannels 决定步长
        let stride = max(Int(list[0].mNumberChannels), 1)
        let usable = min(stride, takeChannels)

        // ★ 逐路峰值测量：**自测分支与正常分支都要调用**。
        //   先前它只写在函数末尾，而自测分支里提前 return 了 ⇒ 自测写了音频却量不到，
        //   表现为"回调在跑、帧数在涨、峰值全是 0"，白查了一轮。
        func measurePeaks(frames: Int) {
            for c in 0..<min(usable, Self.maxReportChannels) {
                var peak = sChannelPeaks[c]
                for f in 0..<frames {
                    let v = abs(dst[f * stride + c])
                    if v > peak { peak = v }
                }
                sChannelPeaks[c] = peak
            }
        }

        // ── 诊断自测：就地合成，不读上游 ──────────────────────
        if selfTestSignal {
            let inc200 = 2.0 * Double.pi * 200.0 / sampleRate
            for f in 0..<frames {
                // 两条上游的合成值（速率由相位累加器决定；此处简化用同一相位）
                let rate = Float(sin(selfTestPhase))          // 200Hz
                let direct = Float(cos(selfTestPhase * 2.5))  // 500Hz 近似
                selfTestPhase += inc200
                if selfTestPhase > 2 * Double.pi { selfTestPhase -= 2 * Double.pi }
                let base = f * stride
                for c in 0..<usable {
                    var v: Float = 0
                    if c == mixTargetIndex {
                        v = rate * mixGain + direct
                    } else if c == mixCutIndex {
                        v = 0
                    } else if mixGain == 0 {
                        // 未混音时：所有声道都给一个 200Hz，便于验证直通
                        v = rate
                    }
                    dst[base + c] = v
                }
                if usable < stride { for c in usable..<stride { dst[base + c] = 0 } }
            }
            sFramesOut += Int64(frames)
            measurePeaks(frames: frames)
            return noErr
        }

        // ★★ 正常分支整体交给 `renderFromRing`（internal ⇒ 单测可直接驱动）。
        //
        //   为什么连"取水位 / 欠载判定 / 提交读游标"都搬进去、而不是只搬"取样本"：
        //   v0.1.3 的静音回归形态是**搬运调用点被 `if mixGain != 0` 包住**。
        //   只把搬运抽成函数、测试直接调它，抓不到"调用点被守卫"这类回归 ——
        //   必须让测试驱动**整段正常分支**才算锁住。
        // ★ 首拍对齐按"每次装配"判断：`start()` 置位，这里消费一次。
        //   ⚠️ 绝不要改回 `sOutCallbacks <= 1`（跨装配累加 ⇒ 只生效一次）。
        let isFirstOutputCallback = pendingStartupAlignment
        pendingStartupAlignment = false

        // ★ 首拍：用**真实**的输出回调帧数重算水位参数。
        //   水位至少要装得下一个回调，而回调帧数运行时才知道 ⇒
        //   这里重算一次，然后由 `renderFromRing` 的首次对齐按新目标归位。
        if isFirstOutputCallback {
            applyLatencyTarget(sampleRate: sampleRate, callbackFrames: frames)
        }

        var counters = RenderCounters()
        let read = Self.renderFromRing(ring: ring,
                                      dst: dst,
                                      stride: stride,
                                      usable: usable,
                                      frames: frames,
                                      permute: permute,
                                      mix: ChannelSwapMixParams(gain: mixGain,
                                                                sourceIndex: mixSourceIndex,
                                                                targetIndex: mixTargetIndex,
                                                                directIndex: mixDirectIndex,
                                                                cutIndex: mixCutIndex),
                                      targetFillFrames: targetFillFrames,
                                      deadbandFrames: fillDeadbandFrames,
                                      isFirstOutputCallback: isFirstOutputCallback,
                                      averageFillFrames: &sAverageFillFrames,
                                      prefillAttempts: &sPrefillAttempts,
                                      lowerTrimCounter: &sLowerTrimCounter,
                                      counters: &counters)
        sUnderruns += counters.underruns
        sResyncs += counters.resyncs
        sDroppedStaleFrames += counters.droppedStaleFrames
        sLowerTrimmedFrames += counters.lowerTrimmedFrames
        sStartupAlignedFrames += counters.startupAlignedFrames
        sStarvedFrames += counters.starvedFrames
        if counters.peakFillFrames > sPeakFillFrames { sPeakFillFrames = counters.peakFillFrames }
        sFramesOut += Int64(read)
        measurePeaks(frames: read)
        return noErr
    }
}

// MARK: - 错误

public enum SwapDriverError: Error, CustomStringConvertible {
    case planUnusable
    case noInputStream
    case componentNotFound(String)
    case instanceCreateFailed(String)
    case propertyFailed(String, OSStatus)
    case initializeFailed(String, OSStatus)
    case startFailed(phase: String, status: OSStatus)

    public var description: String {
        switch self {
        case .planUnusable:
            return "交换计划不可用（声道数不足或声道号越界）"
        case .noInputStream:
            return "输入设备没有可读的输入声道"
        case .componentNotFound(let name):
            return "找不到音频组件 \(name)"
        case .instanceCreateFailed(let phase):
            return "创建\(phase)失败"
        case .propertyFailed(let name, let status):
            return "设置\(name)失败（\(CoreAudioHelpers.describe(status))）"
        case .initializeFailed(let phase, let status):
            return "\(phase) AudioUnitInitialize 失败（\(CoreAudioHelpers.describe(status))）"
        case .startFailed(let phase, let status):
            return "\(phase) 启动失败（\(CoreAudioHelpers.describe(status))）"
        }
    }
}

// MARK: - 无锁 SPSC 环形缓冲
//
// 与探针 `e2e_swap.swift` 里的实现一致：容量取 2 的幂，用 `& mask` 代替取模；
// 单调递增的 Int64 读写索引；单生产者（输入回调）单消费者（输出回调），
// 因此不需要 CAS，只需要正确的顺序（写入样本 → 提交索引）。

final class SwapRingBuffer: @unchecked Sendable {
    let capacity: Int
    let channels: Int
    private let store: UnsafeMutablePointer<Float>
    private let writeIndex: UnsafeMutablePointer<Int64>
    private let readIndex: UnsafeMutablePointer<Int64>
    private let mask: Int

    init(capacity: Int, channels: Int) {
        var cap = 1
        while cap < max(capacity, 1) { cap <<= 1 }
        self.capacity = cap
        self.channels = channels
        self.mask = cap - 1
        self.store = .allocate(capacity: cap * channels)
        self.store.initialize(repeating: 0, count: cap * channels)
        self.writeIndex = .allocate(capacity: 1); self.writeIndex.initialize(to: 0)
        self.readIndex = .allocate(capacity: 1);  self.readIndex.initialize(to: 0)
    }

    deinit {
        store.deallocate()
        writeIndex.deallocate()
        readIndex.deallocate()
    }

    @inline(__always) var fillFrames: Int { Int(writeIndex.pointee - readIndex.pointee) }
    @inline(__always) func plane(_ channel: Int) -> UnsafeMutablePointer<Float> {
        store + channel * capacity
    }

    /// 开始写入一段：返回**回绕后**的起点与这一段的帧数上限。
    ///
    /// - Parameter frames: **这一段**最多想写多少帧（传"本次回调的剩余待写量"）
    ///
    /// ⚠️ 返回的 `writable` 被两件事截断：总剩余空间，以及**起点到平面末尾的距离**。
    ///    写满这一段后**必须** `commitWrite`，再带着新的剩余量调用下一段；
    ///    绝不能拿 `pos + writable` 当作连续内存（那正是本文件修过的越界缺陷）。
    ///
    /// ⚠️⚠️ 这里曾经带一个 `start:`（"已处理帧数"）参数，但**写侧每段都会
    ///    `commitWrite`**、读侧又**不**逐段 `commitRead` —— 两侧语义相反，
    ///    于是 `pos = (游标 & mask) + start` 在回绕点必然算错：
    ///      · 写侧：游标已推进，再加 `start` ⇒ 第二段写到了**错误位置**；
    ///      · 读侧：`pos` 可能等于 `capacity` ⇒ `capacity - pos == 0`
    ///        ⇒ 那一段被判成"没有可读数据"而**静默丢弃**（真机表现为
    ///        周期性静音 + 丢旧帧数一直涨）。
    ///    ⇒ 现在两侧统一为"**每段提交、只传剩余量**"，游标本身就是下一段的起点，
    ///      `pos = 游标 & mask` 在任何相位下都成立。
    @inline(__always) func beginWrite(_ frames: Int) -> (pos: Int, writable: Int) {
        let w = writeIndex.pointee
        let space = capacity - Int(w - readIndex.pointee)
        let want = min(frames, space)
        guard want > 0 else { return (0, 0) }
        let pos = Int(w) & mask
        return (pos, min(want, capacity - pos))
    }

    @inline(__always) func commitWrite(_ frames: Int) {
        writeIndex.pointee = writeIndex.pointee &+ Int64(frames)
    }

    /// 开始读取一段：返回回绕后的起点、**当前**可读总量与这一段的帧数上限。
    ///
    /// - Parameter frames: **这一段**最多想读多少帧（传"本次回调的剩余待读量"）
    ///
    /// ⚠️ 与 `beginWrite` 完全对称：读满这段后 `commitRead`，再带新的剩余量调用下一段。
    ///    详见 `beginWrite` 里关于 `start:` 参数为何被删掉的说明。
    ///
    /// ⚠️ 第二个返回值是**这一刻**的可读总量（`写游标 − 读游标`）；第三个才是
    ///    这一段的上限（可能被平面末尾截断）。**求"本次能消费多少"要用前者**，
    ///    历史上错用过后者（见 `renderFromRing` 的说明）。
    @inline(__always) func beginRead(_ frames: Int) -> (pos: Int, available: Int, readable: Int) {
        let r = readIndex.pointee
        let available = Int(writeIndex.pointee - r)
        let want = min(frames, available)
        guard want > 0 else { return (0, available, 0) }
        let pos = Int(r) & mask
        return (pos, available, min(want, capacity - pos))
    }

    @inline(__always) func commitRead(_ frames: Int) {
        readIndex.pointee = readIndex.pointee &+ Int64(frames)
    }

    /// 丢弃 `frames` 帧**最旧**数据（推进读游标），返回实际丢弃帧数。
    ///
    /// 低水位收敛用它：降低延迟的唯一方向是"让消费者跳过已积压的旧数据"，
    /// 而写侧丢新块只能阻止水位继续上涨。丢弃量由
    /// `ChannelSwapAudioDriver.staleDropFrames` 按比例给出，不会一步跳回目标。
    @discardableResult
    @inline(__always) func discardStale(_ frames: Int) -> Int {
        let n = min(max(frames, 0), fillFrames)
        guard n > 0 else { return 0 }
        readIndex.pointee = readIndex.pointee &+ Int64(n)
        return n
    }

    /// 水位失控后重新居中到"最近的 frames 帧"。
    ///
    /// ⚠️ 必须用 `max(_, 0)` 兜底 —— 这是本轮顺带补上的边界缺陷：
    /// 启动初期"写入总量还不到 frames"时（输出单元启动后的第一次回调就要 512 帧，
    /// 而输入侧可能只填了几十帧），直接做减法会把**读游标推到 0 之前**（负数）。
    /// 负游标不会崩（`& mask` 仍落在分配区内，读到的是初始化的 0），
    /// 但 `fillFrames = write - read` 会虚高成 `write + |负数|`
    /// ⇒ 水位统计与低水位收敛判断全部建立在错数上。
    /// 这又是一次"看起来在跑、数值是假的"，因此宁可在这里显式夹住。
    @inline(__always) func resync(_ frames: Int) {
        let target = Int64(min(frames, capacity))
        readIndex.pointee = max(writeIndex.pointee &- target, 0)
    }
}
