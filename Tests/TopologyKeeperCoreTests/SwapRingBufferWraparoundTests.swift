import Testing
@testable import TopologyKeeperCore

/// 环形缓冲的**平面回绕**回归测试。
///
/// ## 背景（这是一次真实缺陷的回归锁）
///
/// `SwapRingBuffer` 是"每声道一个 plane、各 `capacity` 帧"的布局
/// （`plane(c) = store + c*capacity`），而写游标的**平面内偏移**是回绕的
/// （`pos = w & mask`）。旧实现把 `writable` 只按"总剩余空间"截断，
/// 于是 `memcpy(plane(c) + pos, src, writable*4)` 在回绕点：
///
/// * `c < channels-1`：样本写进**下一个 plane 的开头**（声道内容互相污染）；
/// * `c == channels-1`：直接**越过 `store` 的 `capacity*channels` 分配区**（堆越界写）。
///
/// ## 为什么必须用"不整除容量"的帧数测
///
/// 越界需要 `writable > capacity - pos`。当回调帧数**整除** `capacity`
/// （512/1024/2048/4096，含 AUHAL 最常见的 512）时 `pos` 恒落在网格点上、
/// `writable` 总是够用，**永不触发** —— 这正是它长期潜伏的原因。
/// 因此下面的用例刻意用 480（48kHz、容量上取整 16384 的真实组合）来复现。
///
/// 本文件只测缓冲本身的不变量（不触碰音频硬件），可在 CI 稳定运行。
struct SwapRingBufferWraparoundTests {

    /// 按 `SwapRingBuffer` 的容量算法算出真实容量（2 的幂上取整）
    private func capacity(forSampleRate rate: Double) -> Int {
        var cap = 1
        let raw = Int(rate * 0.25)          // 与驱动 start() 一致：约 250ms
        while cap < max(raw, 1) { cap <<= 1 }
        return cap
    }

    /// ★ 不变量一：`beginWrite` 返回的段**绝不能越过平面边界**。
    ///
    /// 这正是旧实现的越界处 —— 它返回的 `pos + writable` 可以大于 `capacity`。
    /// 用 480 帧跑满多个回绕点，逐次断言。
    @Test("beginWrite 的段不得越过平面边界（480 帧 / 48kHz / 容量 16384）")
    func writeSegmentNeverCrossesPlaneBoundary() {
        let cap = capacity(forSampleRate: 48000)
        #expect(cap == 16384, "48kHz × 0.25s 应上取整为 16384 帧，实际 \(cap)")
        let ring = SwapRingBuffer(capacity: cap, channels: 8)

        let frames = 480                      // ★ 不整除 16384 ⇒ 会命中回绕点
        let callbacks = 400
        var sawWrap = false                   // 是否真的遇到过分段（第二段）

        for _ in 0..<callbacks {
            // 生产者：按驱动 writeToRing 的分段语义写满 frames 帧
            var start = 0
            while start < frames {
                let (pos, writable) = ring.beginWrite(frames, start: start)
                guard writable > 0 else { break }
                #expect(pos + writable <= cap,
                        "第 \(start) 帧起的段越过平面边界：pos=\(pos) + writable=\(writable) > \(cap)")
                if start > 0 { sawWrap = true }        // 出现了第二段 ⇒ 命中回绕点
                ring.commitWrite(writable)
                start += writable
            }

            // 消费者：按驱动 handleOutput 的分段语义消费
            let avail = ring.beginRead(frames, start: 0).available
            var consumed = 0
            while consumed < frames {
                let (pos, _, readable) = ring.beginRead(frames, start: consumed)
                guard readable > 0 else { break }
                #expect(pos + readable <= cap,
                        "读段越过平面边界：pos=\(pos) + readable=\(readable) > \(cap)")
                consumed += readable
            }
            ring.commitRead(consumed)
            if avail < frames / 2 { ring.resync(frames) }
        }

        #expect(sawWrap, "480 帧 / 容量 16384 必然跨过回绕点；没跨过说明用例没测到目标路径")
    }

    /// ★ 不变量二：跨回绕点的写入**不得把样本写进相邻 plane**。
    ///
    /// 编码方式：每个声道一个"基准量"，样本值 = `基准量 + 序号 × 1e-6`
    /// （幅度远小于声道间距 1.0，绝无编码冲突），据此可逐帧还原
    /// "这个样本属于哪个声道"。
    @Test("回绕点不得把样本写进相邻 plane（声道串扰）")
    func noCrossPlaneContamination() {
        let cap = 4096                        // 小容量，便于快速绕满
        let channels = 4
        let frames = 480                      // 不整除 4096 ⇒ 命中回绕点
        let ring = SwapRingBuffer(capacity: cap, channels: channels)
        #expect(ring.capacity == cap)

        /// 声道 c 的第 seq 帧
        @inline(__always) func sample(_ c: Int, _ seq: Int) -> Float {
            Float(c) + 0.5 + Float(seq) * 1e-6
        }
        /// 从样本值还原声道号
        @inline(__always) func channelOf(_ v: Float) -> Int {
            Int((v - 0.5).rounded(.down))
        }

        var written = 0                       // 已写入的总帧数（全局序号）
        var checked = 0
        var sawWrap = false

        for round in 0..<80 {
            // ── 写 ──
            if ring.fillFrames <= (ring.capacity * 3) / 4 {
                var start = 0
                while start < frames {
                    let (pos, writable) = ring.beginWrite(frames, start: start)
                    guard writable > 0 else { break }
                    if start > 0 { sawWrap = true }
                    for c in 0..<channels {
                        for f in 0..<writable {
                            ring.plane(c)[pos + f] = sample(c, written + start + f)
                        }
                    }
                    ring.commitWrite(writable)
                    start += writable
                }
                written += frames
            }

            // ── 读：每两轮才消费一半，制造读写游标错位（回绕点的必要前提）──
            guard round % 2 == 1 else { continue }
            let want = frames / 2
            var consumed = 0
            while consumed < want {
                let (pos, _, readable) = ring.beginRead(want, start: consumed)
                guard readable > 0 else { break }
                for c in 0..<channels {
                    for f in 0..<readable {
                        let v = ring.plane(c)[pos + f]
                        #expect(channelOf(v) == c,
                                "plane \(c) 偏移 \(pos + f) 里出现了声道 \(channelOf(v)) 的样本 → 跨平面串扰")
                        checked += 1
                    }
                }
                consumed += readable
            }
            ring.commitRead(consumed)
        }

        #expect(sawWrap, "本用例必须真的跨过回绕点")
        #expect(checked > 0, "本用例必须真的校验过样本")
    }

    /// ★ 不变量三：跨回绕点读回的样本序列必须**连续、且内容正确**。
    ///
    /// 旧实现在回绕点读到的是**下一个 plane 的开头**，表现为样本值突然跳变。
    ///
    /// 回绕出现的条件是"**已写游标的平面内偏移 > 区内存量**"（此时到平面末尾的
    /// 距离小于本次要写的帧数）。本用例直接构造这个状态：
    /// 先把缓冲区填到 3/4（写游标平面内偏移 = 3072），之后每次写 480 帧都必然
    /// 从"距末尾不足 480 帧"的位置出发而被分成两段。
    ///
    /// ## 值编码（无需参考数组，天然检测覆盖）
    ///
    /// `slot` 的值 = `写入轮次 × capacity + 平面内槽位`。每个槽位每一轮被写的值
    /// 都不同，因此"读到上一轮/下一轮的数据""读到相邻 plane 的数据""读到没写过的
    /// 槽位（= 0）"这三种错误都会被立即识别，且不需要维护任何期望序列。
    @Test("跨回绕点读写的样本序列必须连续（不得跳到下一个 plane）")
    func readAcrossWrapIsContinuous() {
        let cap = 4096
        let channels = 2
        let ring = SwapRingBuffer(capacity: cap, channels: channels)
        #expect(ring.capacity == cap)

        @inline(__always) func value(round: Int, slot: Int) -> Float {
            Float(round * cap + slot)
        }

        let fillTarget = (cap * 3) / 4          // 3072：把写游标平面内偏移推到这里
        let chunk = 480                          // 不整除 cap ⇒ 之后必然跨回绕

        var round = 0                            // 写入轮次（每次成功写入 +1）
        var sawWrapWrite = false
        var sawWrapRead = false
        var readRounds = 0

        /// 写 n 帧，返回实际写入帧数
        @discardableResult
        func write(_ n: Int) -> Int {
            var start = 0
            while start < n {
                let (pos, writable) = ring.beginWrite(n, start: start)
                guard writable > 0 else { break }
                if start > 0 { sawWrapWrite = true }
                #expect(pos + writable <= cap,
                        "写段越过平面边界：pos=\(pos) + writable=\(writable) > \(cap)")
                #expect(start + writable <= n)
                for c in 0..<channels {
                    for f in 0..<writable {
                        ring.plane(c)[pos + f] = value(round: round, slot: pos + f)
                    }
                }
                ring.commitWrite(writable)
                start += writable
            }
            if start > 0 { round += 1 }
            return start
        }

        /// 消费 n 帧并逐帧校验
        func drain(_ n: Int) {
            var done = 0
            while done < n {
                let want = n - done
                let (pos, _, readable) = ring.beginRead(want, start: 0)
                guard readable > 0 else { break }
                if readable < want { sawWrapRead = true }
                for c in 0..<channels {
                    for f in 0..<readable {
                        let v = ring.plane(c)[pos + f]
                        // 第 r 轮写入的槽位 s 的值恒为 r*cap + s；反解出轮次即可判定
                        let gotRound = Int(v) / cap
                        let gotSlot = Int(v) % cap
                        #expect(gotSlot == pos + f,
                                "位置 \(pos + f) 的值为 \(v)（反解槽位 \(gotSlot)）—— 读写位置不一致")
                        #expect(gotRound >= 0 && gotRound < round,
                                "位置 \(pos + f) 的值 \(v) 反解出轮次 \(gotRound)，超出已写入的 0..<\(round)")
                    }
                }
                readRounds += 1
                done += readable
            }
            ring.commitRead(done)
        }

        // ── 第 1 步：填到 3/4 ──
        var written = 0
        while written < fillTarget {
            let want = min(chunk, fillTarget - written)
            written += write(want)
        }
        #expect(ring.fillFrames == fillTarget, "应恰好填到 \(fillTarget)，实际 \(ring.fillFrames)")
        #expect(ring.beginWrite(1, start: 0).pos == fillTarget,
                "写游标的平面内偏移应为 \(fillTarget)，实际 \(ring.beginWrite(1, start: 0).pos)")

        // ── 第 2 步：反复"腾空间 → 写 480 帧"，每次写都跨回绕点 ──
        for _ in 0..<12 {
            let toDrain = max(ring.fillFrames - (cap - chunk), 0)
            if toDrain > 0 { drain(toDrain) }
            let got = write(chunk)
            #expect(got == chunk, "应恰好写入 \(chunk) 帧，实际 \(got) 帧")
        }

        // ── 第 3 步：把剩下的全部读回校验 ──
        drain(ring.fillFrames)

        #expect(sawWrapWrite, "本用例必须真的让**写**跨过回绕点")
        #expect(sawWrapRead, "本用例必须真的让**读**跨过回绕点")
        #expect(readRounds > 0, "本用例必须真的读回数据")
    }
}
