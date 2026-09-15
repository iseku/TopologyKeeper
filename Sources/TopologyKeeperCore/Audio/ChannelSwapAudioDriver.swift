import AudioToolbox
import AudioUnit
import CoreAudio
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
            // ★★ 直通的那条输入 + 不连的那条下游，**都由 CH-O 决定**（用户实测确认）
            //
            //   规律（4 组用例实测得出）：
            //     · 直通的输入 = 与 CH-O **不同**的那条输入
            //     · 不连的下游 = 与 CH-O **不同**的那条下游（本机 CH-O=4 ⇒ CH3-O 不连）
            //     · **衰减仍施加在用户选中的那条 CH-I 上**（这是 CH-I 的唯一作用）
            //
            //   | CH-O | CH-I | CH-O 的结果         | 不连  |
            //   |------|------|---------------------|-------|
            //   |  4   |  3   | CH4-I + CH3-I×g     | CH3-O |
            //   |  4   |  4   | CH3-I + CH4-I×g     | CH3-O |
            //   |  3   |  3   | CH4-I + CH3-I×g     | CH4-O |
            //   |  3   |  4   | CH3-I + CH4-I×g     | CH4-O |
            //
            //   ⚠️ 我曾把"直通的输入"按 **CH-I** 去算（而非 CH-O），
            //      于是 CH-O=3 的两组全错：用户实测看到"CH3-I 直通 CH3-O、CH4-I 直通 CH4-O"，
            //      即衰减完全没有生效。
            let pair = LfeMixPlan.selectableChannels
            let other = { (ch: Int) in ch == pair.lowerBound ? pair.upperBound : pair.lowerBound }
            // ★ 直通的输入 = **与 CH-I 不同的那条输入**（两条输入都进 CH-O，
            //   被选中的那条衰减、另一条直通）。
            //   ⚠️ 我一度写成 `other(mix.outputChannel)` —— 那是**下游**的配对，
            //      于是 CH-I=3 时"直通"被算成了 CH3-I 自己，
            //      CH4-I 根本没进 CH-O（用户实测："CH4-I 直通 CH4-O" 而非混入）。
            mixDirectIndex = ChannelSwapPlan.apiIndex(forChannel: other(mix.inputChannel))
            // 不连的下游 = 与 CH-O 不同的那条下游（本机 CH-O=4 ⇒ CH3-O 不连）
            mixCutIndex = ChannelSwapPlan.apiIndex(forChannel: other(mix.outputChannel))
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
        let capacityFrames = Int(sampleRate * 0.25)
        ring = SwapRingBuffer(capacity: capacityFrames, channels: take)
        prepareRenderBuffers(channels: srcChannels)

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
                              nonZeroInFrames: sNonZeroInFrames)
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
        guard let ring, let abl = renderABL else { return noErr }

        let frames = min(Int(frameCount), Self.maxFrames)
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
            let (pos, writable) = ring.beginWrite(frames)
            if writable > 0 {
                for c in 0..<min(takeChannels, list.count) {
                    guard let rawSrc = list[c].mData else { continue }
                    let src = rawSrc.assumingMemoryBound(to: Float.self)
                    memcpy(ring.plane(c) + pos, src, writable * MemoryLayout<Float>.size)
                }
                ring.commitWrite(writable)
            }
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

        let (pos, writable) = ring.beginWrite(frames)
        guard writable > 0 else { return noErr }

        let take = min(takeChannels, list.count)
        for c in 0..<take {
            guard let raw = list[c].mData else { continue }
            memcpy(ring.plane(c) + pos, raw, writable * MemoryLayout<Float>.size)
            // 抽样统计非零（每 16 帧取 1，实时线程上不做重活）
            let p = raw.assumingMemoryBound(to: Float.self)
            var nz = 0
            var i = 0
            while i < writable { if abs(p[i]) > 1e-6 { nz += 1 }; i += 16 }
            sNonZeroInFrames += Int64(nz)
        }
        ring.commitWrite(writable)
        sFramesIn += Int64(writable)
        return noErr
    }

    /// 渲染回调：环形缓冲 → 交错输出缓冲（**交换在本回调内按置换表完成**）
    private func handleOutput(frameCount: UInt32,
                              ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
        sOutCallbacks += 1
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

        let (pos, available, read) = ring.beginRead(frames)

        // 水位过低（目标钟快于源）→ 欠载，重新居中避免持续"半空"
        if available < frames / 2 {
            sUnderruns += 1
            if available < frames { ring.resync(frames) }
        }

        if read > 0 {
            // ★ 交换在这里发生：目标第 c 声道取源第 permute[c] 声道
            //   （permute 已预计算，长度 = takeChannels；恒等即不交换）
            if mixGain == 0 {
                // 无混音：按置换表直取（恒等时 permute[c] == c，无需分支）
                for f in 0..<read {
                    let base = f * stride
                    for c in 0..<usable {
                        let srcCh = (c < permute.count) ? permute[c] : c
                        dst[base + c] = (ring.plane(srcCh) + pos)[f]
                    }
                    if usable < stride { for c in usable..<stride { dst[base + c] = 0 } }
                }
            } else {
                // ★★ 混音（LFE → 目标声道）：**零分配**的一次乘加。
                //
                //    为什么能这么简单：环形缓冲是 **planar**（每声道一个 plane），
                //    所以"把低音混进某条声道"就是"读两个 plane 再相加"，
                //    不需要任何中间数组、不 memcpy。
                //
                //    ⚠️ 绝不能在实时回调里构造 Swift 数组（会分配 → 可能加锁/缺页 → 爆音）。
                //    本分支只用指针算术。
                //    ★★ 混音语义（用户明确定义，2026-09）：
                //
                //      CH-I = 被施加衰减的那条**上游**声道（配置项）
                //      CH-O = 下游输出声道；**CH-O 自己那条内容直通、不衰减**，
                //             另条上游（未被选中的那条）也直通、不衰减
                //      两条上游**都进 CH-O**，只是被选中的那条乘 gain、另一条直通。
                //
                //      选 CH-I=3:  CH4-O = CH4-I（直通） + CH3-I × gain
                //      选 CH-I=4:  CH4-O = CH3-I（直通） + CH4-I × gain
                //      CH3-O（非 CH-O 的那条）不连 ⇒ 静音
                //
                //    两个空间（用户提出的命名，勿混）：
                //      上游 plane：CH3-I/CH4-I  ← 只读
                //      下游输出：  CH3-O/CH4-O  ← 只写
                //
                //    传递函数（c = 输出声道序号）：
                //      c == mixTargetIndex : rateIdx 那条 × gain  +  另一条 × 1
                //                            其中另一条 = 与 mixSourceIndex 配对的上游声道
                //      其它声道            : 静音（本次配置下只有 CH-O 出声）
                //
                //    ⚠️ 已走过的四次错误（都被用户逐条纠正）：
                //      ① 用上游索引决定衰减哪条下游声道 → 衰减落错声道；
                //      ② 对下游目标整体再乘增益 → 把该条的直通内容也压小了；
                //      ③ 没切断上游那条的输出 → 未衰减信号从 CH3-O 漏出；
                //      ④ 把"被衰减的"与"直通的"搞反 → 衰减加在了不该加的那条上。
                let mixSourcePlane = ring.plane(mixSourceIndex)
                let mixDirectPlane = ring.plane(mixDirectIndex)
                for f in 0..<read {
                    let base = f * stride
                    for c in 0..<usable {
                        let srcCh = (c < permute.count) ? permute[c] : c
                        if c == mixTargetIndex {
                            // CH-O：被选中那条 × gain  +  另一条 × 1
                            dst[base + c] = (mixSourcePlane + pos)[f] * mixGain
                                + (mixDirectPlane + pos)[f]
                        } else if c == mixCutIndex {
                            // 配对中不是 CH-O 的那条：不连 ⇒ 静音
                            dst[base + c] = 0
                        } else {
                            dst[base + c] = (ring.plane(srcCh) + pos)[f]
                        }
                    }
                    if usable < stride { for c in usable..<stride { dst[base + c] = 0 } }
                }
            }
            // 余量必须清零：绝不能把未初始化内存送进设备（会爆音）
            if read < frames {
                memset(dst + read * stride, 0, (frames - read) * stride * MemoryLayout<Float>.size)
            }
        } else {
            memset(dst, 0, frames * stride * MemoryLayout<Float>.size)
        }


        measurePeaks(frames: read)

        ring.commitRead(read)
        sFramesOut += Int64(read)
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

    @inline(__always) func beginWrite(_ frames: Int) -> (pos: Int, writable: Int) {
        let w = writeIndex.pointee
        let space = capacity - Int(w - readIndex.pointee)
        return (Int(w) & mask, min(frames, space))
    }

    @inline(__always) func commitWrite(_ frames: Int) {
        writeIndex.pointee = writeIndex.pointee &+ Int64(frames)
    }

    @inline(__always) func beginRead(_ frames: Int) -> (pos: Int, available: Int, readable: Int) {
        let r = readIndex.pointee
        let available = Int(writeIndex.pointee - r)
        return (Int(r) & mask, available, min(frames, available))
    }

    @inline(__always) func commitRead(_ frames: Int) {
        readIndex.pointee = readIndex.pointee &+ Int64(frames)
    }

    /// 水位失控后重新居中到"最近的 frames 帧"
    @inline(__always) func resync(_ frames: Int) {
        readIndex.pointee = writeIndex.pointee &- Int64(min(frames, capacity))
    }
}
