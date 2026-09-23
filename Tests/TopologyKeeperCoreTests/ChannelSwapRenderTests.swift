// ⚠️ 本文件用 `import AppKit` 而**不是** `import Foundation`：
// 本机只有 CommandLineTools，其 `_Testing_Foundation.framework` 只有二进制、
// 没有 swiftmodule，同一文件里 `import Foundation` 与 `import Testing` 并存
// 必然报 `no such module '_Testing_Foundation'`（详见 LogLevelTests 顶部说明）。
// 架构守护用例需要读源文件（`String(contentsOfFile:)`），AppKit 传递性带来
// Foundation，因此这里用 AppKit。
import AppKit
import Testing

@testable import TopologyKeeperCore

/// `ChannelSwapAudioDriver.copyRingToInterleaved` 的回归测试。
///
/// ## 为什么必须有这个文件（一次真机静音换来的）
///
/// v0.1.3 的真机回归：**只有混音模式出声，交换与直通全静音**。
/// 根因是搬运逻辑外面套着 `if mixGain != 0`，`mixGain == 0` 时整段被跳过，
/// `ioData` 一个样本都没写。它当时 CI 全绿，因为：
///
/// * 那段搬运嵌在**私有**的 `handleOutput` 里，只能由真实音频回调驱动；
/// * 单测注入的是 `ChannelSwapMocks` 的 mock 驱动 ⇒ 真实渲染回调一行都跑不到；
/// * 当时的回绕测试只测缓冲不变量，不问"有没有把样本写进 ioData"。
///
/// ⇒ 现在搬运被抽成 internal 纯函数（`copyRingToInterleaved`），本文件负责锁死：
///   1. **每一帧、每个声道都必须被显式写入**（哨兵 NaN 用例 —— 专治"整段被跳过"）；
///   2. 三种模式（直通 / 交换 / 混音）的取值语义；
///   3. 跨物理回绕点不串声道、不丢帧。
struct ChannelSwapRenderTests {

    // MARK: - 夹具

    /// 样本编码：把"声道号 + 全局帧序号"编码进一个 Float。
    ///
    /// 为什么这样编码：断言时可以用**同一个表达式**算出期望值（比特级相等，
    /// 不受浮点误差影响），同时任何"取错声道 / 取错帧"都会立刻不等。
    private static func sample(_ channel: Int, _ seq: Int) -> Float {
        Float(channel) * 100 + Float(seq) * 0.01 + 0.5
    }

    /// 往 ring 里写入 `count` 帧，帧序号从 `seq` 开始。返回实际写入帧数。
    private func write(_ ring: SwapRingBuffer, channels: Int,
                       from seq: Int, count: Int) -> Int {
        var written = 0
        while written < count {
            let (pos, writable) = ring.beginWrite(count - written)
            guard writable > 0 else { break }
            for c in 0..<channels {
                let plane = ring.plane(c)
                for i in 0..<writable {
                    plane[pos + i] = Self.sample(c, seq + written + i)
                }
            }
            ring.commitWrite(writable)
            written += writable
        }
        return written
    }

    /// 交错输出缓冲，先填满**哨兵 NaN**：
    /// 搬运结束后若还剩 NaN，就说明有帧/声道根本没被写过 —— 这正是 BUG2 的形态。
    private func makeSentinelBuffer(frames: Int, stride: Int) -> UnsafeMutablePointer<Float> {
        let p = UnsafeMutablePointer<Float>.allocate(capacity: frames * stride)
        p.update(repeating: .nan, count: frames * stride)
        return p
    }

    /// 校验一帧：`usable` 内每个声道必须等于"源第 permute[c] 声道"的期望值，
    /// `[usable, stride)` 的余量声道必须为 0。
    /// 只在出错时累计，避免每帧一次 `#expect` 拖慢测试。
    private func check(_ dst: UnsafeMutablePointer<Float>,
                       frames: Int, stride: Int, usable: Int,
                       permute: [Int], firstSeq: Int) -> String? {
        for f in 0..<frames {
            let base = f * stride
            for c in 0..<usable {
                let v = dst[base + c]
                if v.isNaN {
                    return "第 \(f) 帧第 \(c) 声道仍是哨兵 NaN（整段搬运被跳过？）"
                }
                let expected = Self.sample(permute[c], firstSeq + f)
                if v != expected {
                    return "第 \(f) 帧第 \(c) 声道 = \(v)，期望 \(expected)"
                }
            }
            for c in usable..<stride where dst[base + c] != 0 {
                return "第 \(f) 帧余量声道 \(c) = \(dst[base + c])，必须为 0"
            }
        }
        return nil
    }

    private var identityPermute: [Int] { Array(0..<8) }

    /// 交换第 3 ↔ 第 4 声道（**API 0-based** ⇒ 索引 2 ↔ 3）
    private var swapPermute: [Int] { [0, 1, 3, 2, 4, 5, 6, 7] }

    // MARK: - ★ 核心回归：搬运绝不能被"功能开关"整体跳过

    @Test("直通（mixGain == 0）必须把每一帧写进 ioData —— BUG2 回归锁")
    func passThroughWritesEverySample() {
        let frames = 512, stride = 8, usable = 8
        let ring = SwapRingBuffer(capacity: 4096, channels: 8)
        _ = write(ring, channels: 8, from: 0, count: frames)
        let dst = makeSentinelBuffer(frames: frames, stride: stride)
        defer { dst.deallocate() }

        ChannelSwapAudioDriver.copyRingToInterleaved(
            ring: ring, dst: dst, stride: stride, usable: usable,
            frames: frames, read: frames, permute: identityPermute, mix: .off)

        let problem = check(dst, frames: frames, stride: stride, usable: usable,
                            permute: identityPermute, firstSeq: 0)
        #expect(problem == nil, "\(problem ?? "")")
    }

    @Test("交换模式必须按置换表写入每一帧（不是静音）")
    func swapWritesEverySample() {
        let frames = 512, stride = 8, usable = 8
        let ring = SwapRingBuffer(capacity: 4096, channels: 8)
        _ = write(ring, channels: 8, from: 0, count: frames)
        let dst = makeSentinelBuffer(frames: frames, stride: stride)
        defer { dst.deallocate() }

        ChannelSwapAudioDriver.copyRingToInterleaved(
            ring: ring, dst: dst, stride: stride, usable: usable,
            frames: frames, read: frames, permute: swapPermute, mix: .off)

        let problem = check(dst, frames: frames, stride: stride, usable: usable,
                            permute: swapPermute, firstSeq: 0)
        #expect(problem == nil, "\(problem ?? "")")
        // 交换的语义再显式钉一次：第 3 输出声道取源第 4 声道
        #expect(dst[2] == Self.sample(3, 0))
        #expect(dst[3] == Self.sample(2, 0))
    }

    @Test("混音模式：CH-O = 直通那条 + 被选中那条 × gain；配对里另一条下游静音")
    func mixWritesExpectedTransferFunction() {
        let frames = 256, stride = 8, usable = 8
        let ring = SwapRingBuffer(capacity: 4096, channels: 8)
        _ = write(ring, channels: 8, from: 0, count: frames)
        let dst = makeSentinelBuffer(frames: frames, stride: stride)
        defer { dst.deallocate() }

        // 用户选中 CH-I=3（索引 2）衰减后混入 CH-O=4（索引 3）；
        // 配对里"另一条上游"= 索引 3（直通），"不连的那条下游"= 索引 2。
        let mix = ChannelSwapAudioDriver.ChannelSwapMixParams(
            gain: 0.5, sourceIndex: 2, targetIndex: 3, directIndex: 3, cutIndex: 2)

        ChannelSwapAudioDriver.copyRingToInterleaved(
            ring: ring, dst: dst, stride: stride, usable: usable,
            frames: frames, read: frames, permute: identityPermute, mix: mix)

        #expect(dst[3] == Self.sample(2, 0) * 0.5 + Self.sample(3, 0))
        #expect(dst[2] == 0, "配对中不连的那条下游必须静音")
        #expect(dst[0] == Self.sample(0, 0), "其余声道必须直通")
        // 逐帧全量校验（含哨兵 NaN 检查）
        var problems: [String] = []
        for f in 0..<frames {
            let base = f * stride
            for c in 0..<usable {
                let v = dst[base + c]
                if v.isNaN { problems.append("第 \(f) 帧第 \(c) 声道是哨兵 NaN"); continue }
                let expected: Float = (c == 3)
                    ? Self.sample(2, f) * 0.5 + Self.sample(3, f)
                    : (c == 2 ? 0 : Self.sample(c, f))
                if v != expected { problems.append("第 \(f) 帧第 \(c) 声道 = \(v) ≠ \(expected)") }
            }
        }
        #expect(problems.isEmpty, "\(problems.prefix(3).joined(separator: "；"))")
    }

    // MARK: - 跨物理回绕点

    @Test("跨回绕点连续搬运 20 轮：不串声道、不丢帧、顺序不变")
    func wraparoundKeepsChannelAndFrameOrder() {
        let channels = 8, capacity = 4096
        // ★ 帧数**必须不整除**容量：512 整除 4096 ⇒ 读游标永远落在整倍数上，
        //   永远撞不到"平面末尾剩余不足一个回调"的窗口 —— 那里 `read` 曾被
        //   错误地按单段截断（真机表现为周期性静音 + 丢旧一直涨）。用 480 才能逼出它。
        let frames = 480
        let stride = 8, usable = 8
        let ring = SwapRingBuffer(capacity: capacity, channels: channels)
        let dst = makeSentinelBuffer(frames: frames, stride: stride)
        defer { dst.deallocate() }

        var writtenSeq = 0
        var consumedSeq = 0
        var problems: [String] = []
        for round in 0..<20 {
            let n = write(ring, channels: channels, from: writtenSeq, count: frames)
            #expect(n == frames, "第 \(round) 轮只写进 \(n) 帧")
            writtenSeq += n

            let available = ring.fillFrames
            #expect(available >= frames, "第 \(round) 轮可读 \(available) < \(frames)")
            let read = min(frames, available)
            #expect(read == frames)

            dst.update(repeating: .nan, count: frames * stride)
            ChannelSwapAudioDriver.copyRingToInterleaved(
                ring: ring, dst: dst, stride: stride, usable: usable,
                frames: frames, read: read, permute: swapPermute, mix: .off)
            if let problem = check(dst, frames: frames, stride: stride, usable: usable,
                                   permute: swapPermute, firstSeq: consumedSeq) {
                problems.append("第 \(round) 轮：\(problem)")
            }
            consumedSeq += read   // 读游标已由 copyRingToInterleaved 逐段提交
        }
        // 让读/写游标都真正越过 4096 的平面边界（否则用例没测到目标路径）
        #expect(consumedSeq > capacity, "总消费 \(consumedSeq) 未越过容量 \(capacity)，用例没覆盖回绕")
        #expect(problems.isEmpty, "\(problems.prefix(3).joined(separator: "；"))")
    }

    @Test("余量声道（stride > usable）必须清零 —— 未初始化内存送进设备会爆音")
    func paddingChannelsAreZeroed() {
        let frames = 128, stride = 10, usable = 8
        let ring = SwapRingBuffer(capacity: 1024, channels: 8)
        _ = write(ring, channels: 8, from: 0, count: frames)
        let dst = makeSentinelBuffer(frames: frames, stride: stride)
        defer { dst.deallocate() }

        ChannelSwapAudioDriver.copyRingToInterleaved(
            ring: ring, dst: dst, stride: stride, usable: usable,
            frames: frames, read: frames, permute: identityPermute, mix: .off)

        let problem = check(dst, frames: frames, stride: stride, usable: usable,
                            permute: identityPermute, firstSeq: 0)
        #expect(problem == nil, "\(problem ?? "")")
    }

    // MARK: - 正常分支（renderFromRing）

    /// ⚠️ **变异验证记录（2026-09，勿删）**：把 `handleOutput` 里的搬运调用
    /// 包回 `if mixGain != 0 { … }`（即 v0.1.3 的原始形态）后重跑本文件：
    /// **只有架构守护用例失败**，本用例与其余"直接驱动 `renderFromRing`"的
    /// 用例**全部通过**。
    ///
    /// ⇒ 结论：直接驱动函数只能锁住**函数内部**，锁不住**调用点**。
    ///   所以 `renderCallIsNotGatedByFeatureSwitch` 不是锦上添花，而是这套
    ///   回归锁里唯一能拦住那次真机静音的一环。
    @Test("直通配置驱动整段正常分支：dst 必须被写满 —— 调用点回归锁")
    func renderFromRingPassThrough() {
        let frames = 512, stride = 8, usable = 8
        let ring = SwapRingBuffer(capacity: 4096, channels: 8)
        _ = write(ring, channels: 8, from: 0, count: frames * 2)
        let dst = makeSentinelBuffer(frames: frames, stride: stride)
        defer { dst.deallocate() }
        var counters = ChannelSwapAudioDriver.RenderCounters()
        var averageFill = 0
        var prefillDisabled = -1   // 既有用例不启用预填充

        let read = ChannelSwapAudioDriver.renderFromRing(
            ring: ring, dst: dst, stride: stride, usable: usable, frames: frames,
            permute: identityPermute, mix: .off,
            targetFillFrames: 1024, deadbandFrames: 2048, isFirstOutputCallback: false, averageFillFrames: &averageFill, prefillAttempts: &prefillDisabled, counters: &counters)

        #expect(read == frames)
        let problem = check(dst, frames: frames, stride: stride, usable: usable,
                            permute: identityPermute, firstSeq: 0)
        #expect(problem == nil, "\(problem ?? "")")
        #expect(counters.droppedStaleFrames == 0, "水位在范围内不得丢数据")
        #expect(ring.fillFrames == frames, "消费一个回调后水位应为 1 个回调")
    }

    @Test("低水位收敛：超上限时丢**最旧**数据（不是丢新块）")
    func staleDropTakesOldestFrames() {
        let frames = 512, stride = 8, usable = 8
        let ring = SwapRingBuffer(capacity: 4096, channels: 8)
        _ = write(ring, channels: 8, from: 0, count: 3000)
        let dst = makeSentinelBuffer(frames: frames, stride: stride)
        defer { dst.deallocate() }
        var counters = ChannelSwapAudioDriver.RenderCounters()
        var averageFill = 0
        var prefillDisabled = -1   // 既有用例不启用预填充

        // 水位 3000 > 上限 2000；超出目标(1000)共 2000 帧，按 1/8 收敛 ⇒ 本次丢 250 帧
        let read = ChannelSwapAudioDriver.renderFromRing(
            ring: ring, dst: dst, stride: stride, usable: usable, frames: frames,
            permute: identityPermute, mix: .off,
            targetFillFrames: 1000, deadbandFrames: 1000, isFirstOutputCallback: false, averageFillFrames: &averageFill, prefillAttempts: &prefillDisabled, counters: &counters)

        #expect(counters.droppedStaleFrames == 250)
        #expect(read == frames)
        // ★ 丢的是最旧的那批 ⇒ 本次读到的第 0 帧应当是序号 250
        #expect(dst[0] == Self.sample(0, 250), "丢弃必须发生在读侧、且丢最旧")
        #expect(dst[usable] == Self.sample(0, 251))
    }

    @Test("水位在死区内绝不丢数据（否则会追着噪声调）")
    func noDropInsideDeadband() {
        let frames = 256, stride = 8
        let ring = SwapRingBuffer(capacity: 4096, channels: 8)
        _ = write(ring, channels: 8, from: 0, count: 2000)
        let dst = makeSentinelBuffer(frames: frames, stride: stride)
        defer { dst.deallocate() }
        var counters = ChannelSwapAudioDriver.RenderCounters()
        var averageFill = 0
        var prefillDisabled = -1   // 既有用例不启用预填充

        _ = ChannelSwapAudioDriver.renderFromRing(
            ring: ring, dst: dst, stride: stride, usable: stride, frames: frames,
            permute: identityPermute, mix: .off,
            targetFillFrames: 1900, deadbandFrames: 100, isFirstOutputCallback: false, averageFillFrames: &averageFill, prefillAttempts: &prefillDisabled, counters: &counters)

        #expect(counters.droppedStaleFrames == 0, "水位恰好等于上限时属于死区，不得动作")
    }

    @Test("欠载且数据不足一个回调：读游标不得为负、水位不得虚高")
    func resyncNeverGoesNegative() {
        let frames = 512, stride = 8
        let ring = SwapRingBuffer(capacity: 4096, channels: 8)
        _ = write(ring, channels: 8, from: 0, count: 100)     // 远少于一个回调
        let dst = makeSentinelBuffer(frames: frames, stride: stride)
        defer { dst.deallocate() }
        var counters = ChannelSwapAudioDriver.RenderCounters()
        var averageFill = 0
        var prefillDisabled = -1   // 既有用例不启用预填充

        let read = ChannelSwapAudioDriver.renderFromRing(
            ring: ring, dst: dst, stride: stride, usable: stride, frames: frames,
            permute: identityPermute, mix: .off,
            targetFillFrames: 1024, deadbandFrames: 2048, isFirstOutputCallback: false, averageFillFrames: &averageFill, prefillAttempts: &prefillDisabled, counters: &counters)

        #expect(counters.underruns == 1)
        #expect(counters.resyncs == 1)
        #expect(read == 100, "只有 100 帧可读")
        // 旧实现：readIndex = 100 - 512 = -412 ⇒ 消费后 fillFrames 虚高成 412
        #expect(ring.fillFrames == 0, "100 帧全部消费后水位必须归零，不得虚高")
        #expect(dst[0] == Self.sample(0, 0))
        #expect(dst[100 * stride] == 0, "余量必须清零（未初始化内存送进设备会爆音）")
    }

    @Test("读游标落在平面末尾不足一个回调时，必须消费满一个回调（不得截断 ⇒ 不得周期性静音）")
    func readIsNotTruncatedAtRingTail() {
        let channels = 8, capacity = 4096, frames = 480
        let stride = 8
        let ring = SwapRingBuffer(capacity: capacity, channels: channels)
        let dst = makeSentinelBuffer(frames: frames, stride: stride)
        defer { dst.deallocate() }
        var counters = ChannelSwapAudioDriver.RenderCounters()
        var averageFill = 0
        var prefillDisabled = -1   // 既有用例不启用预填充

        var seq = 0, consumed = 0
        var problem: String?
        var truncatedAt = -1
        for round in 0..<20 {
            _ = write(ring, channels: channels, from: seq, count: frames)
            seq += frames
            let read = ChannelSwapAudioDriver.renderFromRing(
                ring: ring, dst: dst, stride: stride, usable: stride, frames: frames,
                permute: identityPermute, mix: .off,
                targetFillFrames: 100_000, deadbandFrames: 100_000, isFirstOutputCallback: false, averageFillFrames: &averageFill, prefillAttempts: &prefillDisabled, counters: &counters)
            if read != frames {
                truncatedAt = round
                problem = "第 \(round) 轮回调只消费了 \(read) 帧（应为 \(frames)）—— 读游标在平面末尾被截断"
                break
            }
            if let p = check(dst, frames: frames, stride: stride, usable: stride,
                             permute: identityPermute, firstSeq: consumed) {
                problem = "第 \(round) 轮：\(p)"
                break
            }
            consumed += read
        }
        #expect(problem == nil, "\(problem ?? "")（截断发生在第 \(truncatedAt) 轮）")
        // 相位必须真的跨过容量末尾，否则用例没测到目标窗口
        #expect(consumed > capacity, "只消费了 \(consumed) 帧，未跨过容量 \(capacity)")
    }

    @Test("数据不足时必须计入「静音填充」帧数（水位偏浅的真实损伤不能隐形）")
    func starvationIsCounted() {
        let frames = 512, stride = 8
        let ring = SwapRingBuffer(capacity: 4096, channels: 8)
        _ = write(ring, channels: 8, from: 0, count: 300)     // 比一个回调少 212 帧
        let dst = makeSentinelBuffer(frames: frames, stride: stride)
        defer { dst.deallocate() }
        var counters = ChannelSwapAudioDriver.RenderCounters()
        var averageFill = 0
        var prefillDisabled = -1   // 既有用例不启用预填充

        let read = ChannelSwapAudioDriver.renderFromRing(
            ring: ring, dst: dst, stride: stride, usable: stride, frames: frames,
            permute: identityPermute, mix: .off,
            targetFillFrames: 200_000, deadbandFrames: 100_000,
            isFirstOutputCallback: false, averageFillFrames: &averageFill, prefillAttempts: &prefillDisabled, counters: &counters)

        #expect(read == 300, "只有 300 帧可读")
        // ★ 缺口 212 帧被 memset 成 0（音频里一段空洞）—— 必须计数。
        //   早先它什么都没记：`underruns` 只在 < frames/2 时计数、`resync` 同理，
        //   于是水位落在 [frames/2, frames) 时**持续丢音却完全不可见**。
        #expect(counters.starvedFrames == 212,
                "缺口 212 帧必须计入静音填充，实际 \(counters.starvedFrames)")
    }

    @Test("连一帧数据都没有时的**整块**静音也必须计数（否则丢音会隐形）")
    func wholeBlockStarvationIsCounted() {
        let frames = 512, stride = 8
        let ring = SwapRingBuffer(capacity: 4096, channels: 8)   // 一帧都没写
        let dst = makeSentinelBuffer(frames: frames, stride: stride)
        defer { dst.deallocate() }
        var counters = ChannelSwapAudioDriver.RenderCounters()
        var averageFill = 0
        var prefillDisabled = -1   // 既有用例不启用预填充

        let read = ChannelSwapAudioDriver.renderFromRing(
            ring: ring, dst: dst, stride: stride, usable: stride, frames: frames,
            permute: identityPermute, mix: .off,
            targetFillFrames: 1024, deadbandFrames: 512,
            isFirstOutputCallback: false, averageFillFrames: &averageFill, prefillAttempts: &prefillDisabled, counters: &counters)

        #expect(read == 0)
        // ★ 真机 192kHz 下出现过"欠载重置 4 次 + 静音填充 0 帧"这种自相矛盾的读数：
        //   每次欠载（available == 0）都是一整块静音，却走了不计数的 else 分支。
        #expect(counters.starvedFrames == Int64(frames),
                "整块静音 \(frames) 帧必须计数，实际 \(counters.starvedFrames)")
        #expect(counters.resyncs == 1, "available(0) < frames ⇒ 触发一次重新居中")
    }

    @Test("启动预填充：水位不足目标时静音等待且**不消费**（让延迟变成确定的）")
    func prefillWaitsUntilTargetReached() {
        let frames = 512, stride = 8
        let ring = SwapRingBuffer(capacity: 4096, channels: 8)
        let dst = makeSentinelBuffer(frames: frames, stride: stride)
        defer { dst.deallocate() }
        var counters = ChannelSwapAudioDriver.RenderCounters()
        var averageFill = 0
        var prefill = 0                                   // 0 = 启用（start() 的初值）
        let target = 1024

        // 1) 水位不足目标：应静音等待、**不消费**（消费就永远填不满）
        _ = write(ring, channels: 8, from: 0, count: 300)
        let read1 = ChannelSwapAudioDriver.renderFromRing(
            ring: ring, dst: dst, stride: stride, usable: stride, frames: frames,
            permute: identityPermute, mix: .off,
            targetFillFrames: target, deadbandFrames: 512,
            isFirstOutputCallback: false, averageFillFrames: &averageFill,
            prefillAttempts: &prefill, counters: &counters)
        #expect(read1 == 0, "预填充期间不得消费")
        #expect(ring.fillFrames == 300, "水位必须原样保留才能积累")
        #expect(dst[0] == 0 && dst[stride] == 0, "预填充输出静音（不是未初始化内存）")
        #expect(counters.starvedFrames == 0, "主动等待不算「数据不足」的损伤")
        #expect(prefill > 0, "仍在等待中")

        // 2) 填够之后照常开跑
        _ = write(ring, channels: 8, from: 300, count: 1400)
        let read2 = ChannelSwapAudioDriver.renderFromRing(
            ring: ring, dst: dst, stride: stride, usable: stride, frames: frames,
            permute: identityPermute, mix: .off,
            targetFillFrames: target, deadbandFrames: 512,
            isFirstOutputCallback: false, averageFillFrames: &averageFill,
            prefillAttempts: &prefill, counters: &counters)
        #expect(read2 == frames, "达标后应正常消费一个回调")
        #expect(prefill == -1, "预填充应已结束")
    }

    @Test("预填充超时兜底：永远填不满时也必须开跑（不得把链路永久静音）")
    func prefillTimesOutInsteadOfSilencingForever() {
        let frames = 512, stride = 8
        let ring = SwapRingBuffer(capacity: 4096, channels: 8)
        let dst = makeSentinelBuffer(frames: frames, stride: stride)
        defer { dst.deallocate() }
        var counters = ChannelSwapAudioDriver.RenderCounters()
        var averageFill = 0
        var prefill = 0
        // 水位永远远低于目标（模拟源端异常）：写到 2000 帧但目标要 100000
        _ = write(ring, channels: 8, from: 0, count: 2000)

        var readTotal = 0
        for _ in 0..<400 {
            readTotal += ChannelSwapAudioDriver.renderFromRing(
                ring: ring, dst: dst, stride: stride, usable: stride, frames: frames,
                permute: identityPermute, mix: .off,
                targetFillFrames: 100_000, deadbandFrames: 50_000,
                isFirstOutputCallback: false, averageFillFrames: &averageFill,
                prefillAttempts: &prefill, counters: &counters)
        }
        #expect(prefill == -1, "必须在有限次回调内放弃等待")
        #expect(readTotal > 0, "超时后必须开始消费，否则就是永久静音")
    }

    @Test("平均水位收敛到实际水位：诊断显示的是它，而不是一个回调内的锯齿")
    func averageConvergesToActualFill() {
        let frames = 512, stride = 8
        let ring = SwapRingBuffer(capacity: 4096, channels: 8)
        _ = write(ring, channels: 8, from: 0, count: frames)     // 初始水位 = 1 个回调
        var seq = frames
        let dst = makeSentinelBuffer(frames: frames, stride: stride)
        defer { dst.deallocate() }
        var counters = ChannelSwapAudioDriver.RenderCounters()
        var averageFill = 0
        var prefillDisabled = -1   // 既有用例不启用预填充

        // 每轮"写 512 → 观测 → 读 512"，水位稳定在 2 个回调（= 1024 帧）
        for _ in 0..<300 {
            _ = write(ring, channels: 8, from: seq, count: frames)
            seq += frames
            _ = ChannelSwapAudioDriver.renderFromRing(
                ring: ring, dst: dst, stride: stride, usable: stride, frames: frames,
                permute: identityPermute, mix: .off,
                targetFillFrames: 100_000, deadbandFrames: 100_000,
                isFirstOutputCallback: false, averageFillFrames: &averageFill, prefillAttempts: &prefillDisabled, counters: &counters)
        }
        // 一阶低通收敛到观测点（写后、读前）的水位 1024。
        // ⚠️ 容差取 divisor/2 + 1：低通用四舍五入，**直接截断会永远差最多 divisor-1 帧**
        //    （实测停在 961，正是这条断言先失败暴露出来）。
        #expect(abs(averageFill - 1024) <= ChannelSwapAudioDriver.fillAverageDivisor / 2 + 1,
                "平均水位 \(averageFill) 应贴近实际水位 1024")
        #expect(ChannelSwapAudioDriver.fillAverageDivisor == 64,
                "低通分母决定平滑程度（时间常数 ≈ 0.7 秒），改动需同步文档")
    }

    @Test("staleDropFrames：死区内为 0、超死区按比例、受 limit 截断")
    func staleDropPolicy() {
        // 水位未超过「目标 + 死区」（100 + 1900 = 2000）→ 不动手
        #expect(ChannelSwapAudioDriver.staleDropFrames(
            fill: 1000, target: 100, deadband: 1900, limit: 512) == 0)
        // 超过 1000/8 = 125
        #expect(ChannelSwapAudioDriver.staleDropFrames(
            fill: 2000, target: 1000, deadband: 500, limit: 512) == 125)
        // 刚越过死区：至少丢 1 帧，否则永远收敛不动
        #expect(ChannelSwapAudioDriver.staleDropFrames(
            fill: 1501, target: 1500, deadband: 0, limit: 512) == 1)
        // 超大积压时每次不超过一个回调，避免一次跳变
        #expect(ChannelSwapAudioDriver.staleDropFrames(
            fill: 9000, target: 1000, deadband: 1000, limit: 512) == 512)
        // 非法输入不得动手
        #expect(ChannelSwapAudioDriver.staleDropFrames(
            fill: 9000, target: 1000, deadband: 1000, limit: 0) == 0)
    }

    /// ★ 真机第二轮反馈的回归锁：水位一旦高于「目标 + 死区」，必须**逐轮回落到目标带**，
    /// 不能像旧实现那样"没超过某个远离目标的上限就永不修正"（实测停在 77ms 不动）。
    @Test("水位高于 目标+死区 时逐轮收敛，不得黏滞在高位")
    func fillConvergesInsteadOfSticking() {
        let target = 1440, deadband = 720          // 30ms 目标 + 15ms 死区（48kHz）
        var fill = 4440                            // 起始 92ms：一次切换后的典型冲击水位
        var rounds = 0
        var firstDrop = 0
        while rounds < 500 {
            let drop = ChannelSwapAudioDriver.staleDropFrames(
                fill: fill, target: target, deadband: deadband, limit: 512)
            if drop == 0 { break }
            if rounds == 0 { firstDrop = drop }
            fill -= drop
            rounds += 1
        }
        #expect(fill <= target + deadband,
                "收敛后水位 \(fill) 应落进目标带（≤ \(target + deadband)）")
        #expect(fill < 4440, "水位必须真的下降（旧实现会永远停在原地）")
        #expect(rounds > 1, "必须分多轮收敛（一轮跳回目标会产生可听跳变）")
        #expect(firstDrop <= 512, "单轮丢弃不得超过一个回调")
        // 目标带内不再动手
        #expect(ChannelSwapAudioDriver.staleDropFrames(
            fill: target + deadband, target: target, deadband: deadband, limit: 512) == 0)
    }

    // MARK: - 架构守护（覆盖"调用点被守卫"这种回归形态）

    /// 定位驱动源文件（由 `#filePath` 推导，不写死绝对路径）
    private static func driverSourcePath() -> String {
        var parts = #filePath.split(separator: "/").map(String.init)
        parts.removeLast()          // ChannelSwapRenderTests.swift
        parts.removeLast()          // TopologyKeeperCoreTests
        parts.removeLast()          // Tests
        return "/" + parts.joined(separator: "/")
            + "/Sources/TopologyKeeperCore/Audio/ChannelSwapAudioDriver.swift"
    }

    @Test("架构守护：首拍对齐必须按「每次装配」判断，不得依赖进程级累计计数")
    func startupAlignmentIsPerStartNotPerProcess() throws {
        let text = try String(contentsOfFile: Self.driverSourcePath(), encoding: .utf8)
        // ① 必须把本轮的标记传下去
        #expect(text.contains("isFirstOutputCallback: isFirstOutputCallback"),
                "handleOutput 必须传递本轮的 `pendingStartupAlignment`（见该字段说明）")
        // ② 不得用跨装配累加的计数判断 —— 那会让对齐只在 App 首次装配时生效
        #expect(!text.contains("isFirstOutputCallback: sOutCallbacks"),
                "sOutCallbacks 跨装配累加 ⇒ 用它判断会让首拍对齐只生效一次（真机实测：切换模式后延迟变、丢旧 3541 帧）")
        // ③ start() 必须为每次装配重新置位
        #expect(text.contains("pendingStartupAlignment = true"),
                "start() 必须为每次装配重新武装首拍对齐")
        // ④ stop() 必须清掉（避免装配失败后残留）
        #expect(text.contains("pendingStartupAlignment = false"),
                "stop() 必须清除该标记")
    }

    @Test("架构守护：正常分支的搬运调用不得被任何功能开关包裹（v0.1.3 回归形态）")
    func renderCallIsNotGatedByFeatureSwitch() throws {
        let text = try String(contentsOfFile: Self.driverSourcePath(), encoding: .utf8)

        // ① 调用点唯一：正常分支只有一处搬运入口（混音与交换共用）
        let callCount = text.components(separatedBy: "Self.renderFromRing(").count - 1
        #expect(callCount == 1, "正常分支应只有一处 renderFromRing 调用，实际 \(callCount)")

        guard let start = text.range(of: "private func handleOutput("),
              let end = text.range(of: "// MARK: - 错误", range: start.upperBound..<text.endIndex) else {
            Issue.record("无法定位 handleOutput 函数体，架构守护失效（请检查源文件结构）")
            return
        }
        let rawBody = String(text[start.lowerBound..<end.lowerBound])
        // ★ 先剥离注释行，再检查**代码**形态。
        //   为什么：本项目的注释就是踩坑史，`handleOutput` 的注释里**正当地**
        //   引用了 `if mixGain != 0` 这个回归形态（那是最有价值的记录）。
        //   守护要防的是代码把搬运包起来，不是文档提及它。
        let body = rawBody.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        // ② 精确形态：`if mixGain != 0 { 搬运 }` —— 这正是 v0.1.3 的静音回归。
        //    ⚠️ 不能用宽泛的 `if mixGain` 匹配：自测分支里有 `else if mixGain == 0`
        //       （那是给合成信号选值，不控制"要不要写"），宽匹配会误报。
        for forbidden in ["if mixGain != 0", "if mix.gain != 0", "if self.mixGain != 0"] {
            #expect(!body.contains(forbidden),
                    "handleOutput 里出现了 `\(forbidden)`：搬运一旦被功能开关包住，交换/直通就会整段跳过、全链路静音（v0.1.3 回归）")
        }

        // ③ 上下文：调用点不得落在任何条件/循环块里 ——
        //    看它前面最近的一个非空行是不是块的开头（`if ... {` 之类）。
        guard let call = body.range(of: "Self.renderFromRing(") else {
            Issue.record("handleOutput 内找不到搬运调用（架构守护失效）")
            return
        }
        let linesBefore = body[body.startIndex..<call.lowerBound]
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let lastLine = linesBefore.last ?? ""
        #expect(!lastLine.hasPrefix("if "),
                "搬运调用被 `\(lastLine)` 包住了 —— 交换/直通会整段跳过")
        #expect(!lastLine.hasSuffix("{"),
                "搬运调用被包进了一个块（上一行 `\(lastLine)`）")
    }
}
