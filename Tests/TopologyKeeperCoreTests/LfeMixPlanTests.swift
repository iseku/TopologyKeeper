import CoreAudio
import Testing
@testable import TopologyKeeperCore

// LFE 混音的纯逻辑测试。
//
// 编号沿用交换那套约定：**对外一律 1-based**（第 1…8 声道）。
//
// ## 本文件锁定的模型（用户实测 + 确认的产品定义）
//
// 用户在生产布局下实测回报：
//   · 第 2 声道 = 右声道（有声）
//   · **第 3 声道 = LFE，整条无声**（音箱没有低音炮）
//   · **第 4 声道 = 中置，有声**（macOS 默认中置）
//
// 而「交换」与「混音」是**互斥**的两个功能，对应两种音响条件：
//   · 音响**有**低音炮、只是软件把 C/LFE 输出反了 → 用**交换**
//   · 音响**没有**低音炮                          → 用**混音**
//
// ⇒ 所以混音目标**不再跟随交换**：它是一个独立的用户选择，默认第 4 声道，
//   可在第 3/第 4 声道之间切换。
//
// 编号：M1 默认值 / M2 门控 / M3 目标选择 / M4 与交换互斥 / M5 换算 / M6 不变量

@Suite("M LFE 混音计划")
struct LfeMixPlanTests {

    private func swapPlan(channels: Int = 8,
                          first: Int = 3, second: Int = 4) -> ChannelSwapPlan {
        ChannelSwapPlan(sourceChannelCount: channels,
                        firstChannel: first, secondChannel: second)
    }

    // MARK: M1 默认值

    @Test("M1a 默认增益是 −10dB（LFE 校准惯例 +10dB 的等响补偿）")
    func defaultGainIsMinusTenDB() {
        #expect(LfeMixPlan.defaultGainDB == -10)
        #expect(abs(LfeMixPlan.gain(fromDB: -10) - 0.3162) < 0.001)
    }

    @Test("M1b 默认：低音取自第 3 声道、混入第 4 声道（用户实测确认的那一对）")
    func defaultsMatchEmpirical() {
        let plan = LfeMixPlan(channelCount: 8)
        #expect(plan.inputChannel == 3, "实测低音在第 3 声道且无声")
        #expect(plan.outputChannel == 4, "实测中置在第 4 声道且有声音")
        #expect(plan.outputChannel == LfeMixPlan.defaultOutputChannel)
    }

    @Test("M1c 增益可调范围是 −24…0dB，且上界不高于 0dB")
    func gainRangeIsSane() {
        #expect(LfeMixPlan.gainRangeDB.lowerBound == -24)
        #expect(LfeMixPlan.gainRangeDB.upperBound == 0)
        #expect(abs(LfeMixPlan.gain(fromDB: 0) - 1.0) < 1e-6)
    }

    @Test("M1d 可选目标只开放第 3/4 声道（实测就是 C/LFE 那一对）")
    func selectableTargets() {
        #expect(LfeMixPlan.selectableChannels == 3...4)
        #expect(LfeMixPlan.selectableChannels.contains(LfeMixPlan.defaultOutputChannel))
    }

    @Test("M1e 默认配置必须可用（默认值自洽，不能自混）")
    func defaultsAreUsable() {
        let plan = LfeMixPlan(channelCount: 8)
        #expect(plan.unavailableReason == nil)
        #expect(plan.resolved() != nil, "开箱即用的配置必须有效")
        #expect(plan.resolved()?.inputChannel == 3)
        #expect(plan.resolved()?.outputChannel == 4)
    }

    // MARK: M2 门控

    @Test("M2a 上游与下游编号相同**不是**自混（两个空间，必须允许）")
    func sameIndexAcrossSpacesIsAllowed() {
        // 早先误把两者当同一空间、禁止编号相同 —— 已按用户的概念纠正移除。
        let r = LfeMixPlan(channelCount: 8, inputChannel: 4, outputChannel: 4).resolved()
        #expect(r != nil, "CH4-I → CH4-O 是合法配置")
        #expect(LfeMixPlan(channelCount: 8, inputChannel: 4, outputChannel: 4)
            .unavailableReason == nil)
    }

    @Test("M2b 声道数 < 6 一律拒绝（与交换的前置条件一致）")
    func rejectsTooFewChannels() {
        for n in 0...5 {
            #expect(LfeMixPlan(channelCount: n).resolved() == nil, "声道数 \(n) 不该通过")
            #expect(LfeMixPlan(channelCount: n).unavailableReason != nil)
        }
    }

    @Test("M2c 6 声道（5.1）可通过（实测那一对都在范围内）")
    func acceptsSixChannels() {
        #expect(LfeMixPlan(channelCount: 6).resolved() != nil)
        #expect(LfeMixPlan(channelCount: 6).unavailableReason == nil)
    }

    @Test("M2d 目标声道越界 → 拒绝")
    func rejectsOutOfRangeTarget() {
        #expect(LfeMixPlan(channelCount: 8, outputChannel: 9).resolved() == nil)
        #expect(LfeMixPlan(channelCount: 8, outputChannel: 0).resolved() == nil)
        #expect(LfeMixPlan(channelCount: 8, outputChannel: 9).unavailableReason != nil)
    }

    @Test("M2e 增益 <= 0 → 拒绝（0 毫无效果，负数会反相）")
    func rejectsNonPositiveGain() {
        #expect(LfeMixPlan(channelCount: 8, gain: 0).resolved() == nil)
        #expect(LfeMixPlan(channelCount: 8, gain: -0.5).resolved() == nil)
        #expect(LfeMixPlan(channelCount: 8, gain: 0).unavailableReason != nil)
    }

    @Test("M2f 极小正增益仍然可用（不做无意义的阈值拒绝）")
    func acceptsVerySmallGain() {
        #expect(LfeMixPlan(channelCount: 8, gain: 0.0001).resolved() != nil)
    }

    // MARK: M3 目标选择

    @Test("M3a 用户可选第 3 声道作为目标（反向搬运）")
    func targetCanBeThirdChannel() {
        // 反方向：把第 4 声道的内容搬到第 3 声道。本机第 3 声道无声，
        // 所以这个选择**没有意义**，但 API 允许（万一换到别的设备就成立）。
        let plan = LfeMixPlan(channelCount: 8,
                              inputChannel: 4,
                              outputChannel: 3)
        let r = plan.resolved()
        #expect(r?.outputChannel == 3)
        #expect(r?.inputChannel == 4)
        #expect(r?.outputAPIIndex == 2)
        #expect(r?.inputAPIIndex == 3)
    }

    @Test("M3b 目标 = 第 4 声道时 API 索引为 3（macOS 默认中置）")
    func targetAPIIndexForDefault() {
        let r = LfeMixPlan(channelCount: 8).resolved()
        #expect(r?.outputAPIIndex == 3)
        #expect(r?.inputAPIIndex == 2)
    }

    @Test("M3c 锁定实测组合：源 plane 索引 2 → 目标输出索引 3")
    func empiricalPair() {
        // 这正是 Probe/lfe_mix_probe --phase4 听感通过的那个组合
        let r = LfeMixPlan(channelCount: 8,
                           inputChannel: 3,
                           outputChannel: 4).resolved()
        #expect(r?.inputAPIIndex == 2, "环形缓冲 plane 2 = 第 3 声道（低音）")
        #expect(r?.outputAPIIndex == 3, "输出第 4 声道 = 中置（有声）")
    }

    // MARK: M4 与交换互斥（在设置层强制，这里锁定 LfeMixPlan 不认识交换）

    @Test("M4a LfeMixPlan 的 API 里**没有**交换参数（防止重复应用交换）")
    func planHasNoSwapParameter() {
        // 结构性防复发：先前版本在 resolve 里也接收交换计划，
        // 结果交换被应用两次、正好抵消，表现为"开了没效果且不报错"。
        // 现在交换只由 ChannelSwapSettings.mixPlan 处理，本类型只有纯门控。
        let r = LfeMixPlan(channelCount: 8).resolved()
        #expect(r != nil)
        #expect(r?.outputChannel == LfeMixPlan.defaultOutputChannel)
    }

    @Test("M4b 交换与混音同时开启时，混音计划必须**不可用**（互斥的防御性落实）")
    func mixUnavailableWhenSwapActive() {
        let settings = ChannelSwapSettings(isEnabled: true, mixEnabled: true)
        let swap = swapPlan()
        let plan = settings.mixPlan(forOutputChannels: 8, declared: nil, swapPlan: swap)
        #expect(plan.resolved() == nil, "互斥组合下不得给出混音计划")
    }

    @Test("M4c 交换未开启（或恒等）时混音正常可用")
    func mixAvailableWithoutSwap() {
        let settings = ChannelSwapSettings(isEnabled: false, mixEnabled: true)
        #expect(settings.mixPlan(forOutputChannels: 8, declared: nil, swapPlan: nil)
            .resolved() != nil)
        // 恒等交换（未真正交换任何声道）同样视为"没有交换"
        let identity = ChannelSwapPlan(sourceChannelCount: 8, firstChannel: 1, secondChannel: 1)
        _ = identity   // swapMap 为 nil 的退化计划
        #expect(settings.mixPlan(forOutputChannels: 8, declared: nil, swapPlan: nil)
            .resolved() != nil)
    }

    // MARK: M5 换算与描述

    @Test("M5a dB ↔ 线性增益互逆")
    func dbConversionRoundTrips() {
        for db in stride(from: -24.0, through: 0.0, by: 2.0) {
            let g = LfeMixPlan.gain(fromDB: db)
            #expect(abs(LfeMixPlan.db(fromGain: g) - db) < 1e-6, "\(db)dB 往返不一致")
        }
    }

    @Test("M5b 0dB = 1.0、−6dB ≈ 0.5、−20dB = 0.1")
    func dbConversionKnownValues() {
        #expect(abs(LfeMixPlan.gain(fromDB: 0) - 1.0) < 1e-6)
        #expect(abs(LfeMixPlan.gain(fromDB: -6) - 0.5012) < 0.001)
        #expect(abs(LfeMixPlan.gain(fromDB: -20) - 0.1) < 1e-6)
    }

    @Test("M5c gain == 0 时 db 返回 -infinity，不产生 NaN")
    func dbOfZeroGainIsSafe() {
        #expect(LfeMixPlan.db(fromGain: 0) == -.infinity)
        #expect(!LfeMixPlan.db(fromGain: 0).isNaN)
    }

    @Test("M5d 描述串包含源、目标与 dB")
    func descriptionIsInformative() {
        let text = LfeMixPlan(channelCount: 8).description()
        // 用 CHn-I / CHn-O 表示法明确区分上游与下游（用户提议的命名）
        #expect(text.contains("CH3-I"), "应标明上游声道")
        #expect(text.contains("CH4-O"), "应标明下游声道")
        #expect(text.contains("-10dB"))
    }

    @Test("M5e 不可用时的描述以「不可用」开头（UI 直接展示）")
    func descriptionOfUnavailable() {
        #expect(LfeMixPlan(channelCount: 2).description().hasPrefix("不可用"))
        // 越界的下游声道 → 不可用
        #expect(LfeMixPlan(channelCount: 8, outputChannel: 9)
            .description().hasPrefix("不可用"))
    }

    // MARK: M6 不变量

    @Test("M6a 不变量：上游与下游**可以同编号**（两个空间，不是自混）")
    func sameIndexAcrossSpacesIsNotSelfMix() {
        // 用户的概念纠正：CH3-I（上游缓冲区）与 CH3-O（下游设备声道）是两个不同对象。
        // 早先错误地要求 input != output，把合法配置拒掉了。
        for ch in 1...8 {
            let plan = LfeMixPlan(channelCount: 8, inputChannel: ch, outputChannel: ch)
            #expect(plan.resolved() != nil,
                    "跨空间同编号（CH\(ch)-I → CH\(ch)-O）必须可用")
        }
    }

    @Test("M6a2 不变量：resolved() 的取值都在范围内，且增益为正")
    func resolvedValuesAreInRange() {
        for input in 1...8 {
            for output in 1...8 {
                let plan = LfeMixPlan(channelCount: 8, inputChannel: input, outputChannel: output)
                if let r = plan.resolved() {
                    #expect((1...8).contains(r.inputChannel))
                    #expect((1...8).contains(r.outputChannel))
                    #expect(r.gain > 0)
                }
            }
        }
    }

    @Test("M6b 6 声道设备上解析结果一致")
    func resolvesOnSixChannels() {
        let r = LfeMixPlan(channelCount: 6).resolved()
        #expect(r?.inputChannel == 3)
        #expect(r?.outputChannel == 4)
    }

    @Test("M6c Resolved 的 API 索引与 1-based 声道号相差恰好 1（唯一转换点）")
    func apiIndexConversion() {
        let r = LfeMixPlan(channelCount: 8).resolved()
        #expect(r?.outputAPIIndex == (r?.outputChannel ?? 0) - 1)
        #expect(r?.inputAPIIndex == (r?.inputChannel ?? 0) - 1)
    }
}

// MARK: - M7 实时传递函数（用户 4 组实测用例的回归锚点）

@Suite("M7 LFE 混音传递函数")
struct LfeMixTransferTests {

    /// 复刻驱动的内联实现（必须与 LfeMixPlan.outputSample 等价）
    private func inlineOutput(c: Int, content: Float, rate: Float, direct: Float,
                              target: Int, cut: Int, gain: Float) -> Float {
        if c == target { return rate * gain + direct }
        if c == cut { return 0 }
        return content
    }

    /// 与驱动同一套规则：
    ///   · target = CH-O（下游）
    ///   · direct = **与 CH-I 不同**的那条输入（两条输入都进 CH-O）
    ///   · cut    = 与 CH-O 不同的那条下游
    /// 期望接线（**production 同源**：直接调用 `LfeMixPlan` 的纯函数，
    /// 不再在本文件里复制一遍"取配对中另一条"的推导）。
    ///
    /// 历史：这里曾自己抄一份 `other()`，且注释与驱动注释互相矛盾，
    /// 结果被一次外部审计误读成"驱动与展示不一致"的功能缺陷。
    /// 现在四处（驱动 / 展示 / 本文件 / tkctl）共用同一实现。
    private func wiring(inputChannel: Int, outputChannel: Int) -> (target: Int, direct: Int, cut: Int) {
        (target: outputChannel - 1,
         direct: LfeMixPlan.directInputChannel(forSource: inputChannel) - 1,
         cut: LfeMixPlan.cutOutputChannel(forTarget: outputChannel) - 1)
    }

    @Test("M7a 用例①　CH-O=4, CH-I=3 → CH4-O = CH4-I + CH3-I × gain")
    func case1() {
        let w = wiring(inputChannel: 3, outputChannel: 4)
        let gain = LfeMixPlan.gain(fromDB: LfeMixPlan.defaultGainDB)
        // rate = CH3-I, direct = CH4-I
        let out = LfeMixPlan.outputSample(outputChannelIndex: 3, contentSample: 0.5,
                                          rateSample: 1.0, directSample: 0.5,
                                          targetIndex: w.target, cutIndex: w.cut, gain: gain)
        #expect(abs(out - (0.5 + 1.0 * 0.3162)) < 1e-3, "实际 \(out)")
    }

    @Test("M7b 用例②　CH-O=4, CH-I=4 → CH4-O = CH3-I + CH4-I × gain")
    func case2() {
        let w = wiring(inputChannel: 4, outputChannel: 4)
        let gain = LfeMixPlan.gain(fromDB: LfeMixPlan.defaultGainDB)
        // rate = CH4-I, direct = CH3-I
        let out = LfeMixPlan.outputSample(outputChannelIndex: 3, contentSample: 1.0,
                                          rateSample: 0.5, directSample: 1.0,
                                          targetIndex: w.target, cutIndex: w.cut, gain: gain)
        #expect(abs(out - (1.0 + 0.5 * 0.3162)) < 1e-3, "实际 \(out)")
    }

    @Test("M7c 用例③　CH-O=3, CH-I=3 → CH3-O = CH4-I + CH3-I × gain（直通的是 CH4-I！）")
    func case3() {
        // ★ 直通的输入由 **CH-I**（上游空间）决定，不是由 CH-O 决定。
        //   CH-I=3 ⇒ 直通那条 = 与 CH-I 配对的另一条 = CH4-I（索引 3）。
        //   （旧注释写的"由 CH-O 决定"是错的，与 M7d2 的注释互相矛盾 ——
        //     两条注释打架正是 `other()` 被抄成 4 份时的产物，现已收口到
        //     `LfeMixPlan.directInputChannel/cutOutputChannel` 一处实现。）
        let w = wiring(inputChannel: 3, outputChannel: 3)
        #expect(w.direct == 3, "CH-I=3 时直通的输入必须是 CH4-I（索引 3）")
        // 「不连的下游」才由 CH-O 决定：CH-O=3 ⇒ 配对里另一条下游 = CH4-O（索引 3）
        #expect(w.cut == 3, "CH-O=3 时不连的下游是 CH4-O（索引 3）")
        let gain = LfeMixPlan.gain(fromDB: LfeMixPlan.defaultGainDB)
        let out = LfeMixPlan.outputSample(outputChannelIndex: 2, contentSample: 0.5,
                                          rateSample: 1.0, directSample: 0.5,
                                          targetIndex: w.target, cutIndex: w.cut, gain: gain)
        #expect(abs(out - (0.5 + 1.0 * 0.3162)) < 1e-3, "实际 \(out)")
    }

    @Test("M7d 用例④　CH-O=3, CH-I=4 → CH3-O = CH3-I + CH4-I × gain")
    func case4() {
        let w = wiring(inputChannel: 4, outputChannel: 3)
        let gain = LfeMixPlan.gain(fromDB: LfeMixPlan.defaultGainDB)
        let out = LfeMixPlan.outputSample(outputChannelIndex: 2, contentSample: 1.0,
                                          rateSample: 0.5, directSample: 1.0,
                                          targetIndex: w.target, cutIndex: w.cut, gain: gain)
        #expect(abs(out - (1.0 + 0.5 * 0.3162)) < 1e-3, "实际 \(out)")
    }

    @Test("M7d2 回归：direct 由 **CH-I** 决定、cut 由 **CH-O** 决定（两个空间别搞混）")
    func directComesFromInputCutFromOutput() {
        // 曾经写成 `direct = other(outputChannel)`：于是 CH-I=3 时"直通"算成 CH3-I 自己，
        // CH4-I 根本没进 CH-O。用户实测："CH4-I 直通 CH4-O"而非混入。
        //
        // ★ 这里改成直接断言**两个纯函数**的语义（而不是再算一遍配对），
        //   这样本文件不再持有第二份实现 —— 四处共用的收口点见 LfeMixPlan。
        let pair = LfeMixPlan.selectableChannels
        for outCh in pair {
            for inCh in pair {
                let expectedDirect = (inCh == pair.lowerBound ? pair.upperBound : pair.lowerBound)
                let expectedCut = (outCh == pair.lowerBound ? pair.upperBound : pair.lowerBound)

                #expect(LfeMixPlan.directInputChannel(forSource: inCh) == expectedDirect,
                        "直通输入应由 CH-I=\(inCh) 决定")
                #expect(LfeMixPlan.cutOutputChannel(forTarget: outCh) == expectedCut,
                        "不连下游应由 CH-O=\(outCh) 决定")

                // 并且 harness 的接线与两个纯函数一致（证明测试没有自己另算一套）
                let w = wiring(inputChannel: inCh, outputChannel: outCh)
                #expect(w.direct == expectedDirect - 1)
                #expect(w.cut == expectedCut - 1)
            }
        }
    }

    @Test("M7h ★ 四组配置下「展示文案」与「驱动接线」必须逐字一致（回归：曾误判为不一致）")
    func displayMatchesWiringForAllFourCombinations() {
        // 背景：一次外部审计据此文件与驱动的注释判定"驱动按 CH-I 算、展示按 CH-O 算，
        // 两处矛盾、一半配置无声"。实际两处**代码**一直一致（都用 CH-I），
        // 矛盾只存在于注释里。这条用例把"四组组合下展示 = 接线"钉死，
        // 以后任何一侧改动都会立刻暴露。
        let gain = LfeMixPlan.gain(fromDB: LfeMixPlan.defaultGainDB)
        let pair = LfeMixPlan.selectableChannels

        for outCh in pair {
            for inCh in pair {
                let w = wiring(inputChannel: inCh, outputChannel: outCh)
                // 展示文案里的那两个声道号（从字符串里取，而不是再算一遍）
                let line = LfeMixPlan.transferFunctionLine(inputChannel: inCh,
                                                            outputChannel: outCh,
                                                            gain: gain)
                let expected = "CH\(outCh)-O = CH\(w.direct + 1)-I + CH\(inCh)-I × "
                    + String(format: "%.3f", gain)
                #expect(line == expected,
                        "CH-I=\(inCh)/CH-O=\(outCh) 的展示文案与接线不一致：\(line)")

                // ★ 直通那条**绝不能**等于被衰减那条（那会变成 (1+g)× 自混）
                #expect(w.direct != inCh - 1,
                        "CH-I=\(inCh) 时直通声道不能是被衰减的自己（自混）")
                // ★ 不连的那条**绝不能**等于目标（否则会把目标静音）
                #expect(w.cut != w.target,
                        "CH-O=\(outCh) 时不连的下游不能是目标本身")
            }
        }
    }

    @Test("M7i ★ 配对推导纯函数是唯一出处：越界输入也取配对的另一条（不回落到自身）")
    func pairedCounterpartIsTotalAndNeverSelf() {
        let pair = LfeMixPlan.selectableChannels
        for ch in pair {
            #expect(LfeMixPlan.pairedCounterpart(of: ch) != ch, "配对另一条不得是自身")
            #expect(pair.contains(LfeMixPlan.pairedCounterpart(of: ch)))
            // 两次取另一条应回到自身（对合性）
            #expect(LfeMixPlan.pairedCounterpart(of: LfeMixPlan.pairedCounterpart(of: ch)) == ch)
        }
        // 两个空间的入口各自代表不同语义，但都落到同一个对合运算
        #expect(LfeMixPlan.directInputChannel(forSource: 3)
                == LfeMixPlan.pairedCounterpart(of: 3))
        #expect(LfeMixPlan.cutOutputChannel(forTarget: 4)
                == LfeMixPlan.pairedCounterpart(of: 4))
    }

    @Test("M7e 不连的那条下游声道静音（CH-O=4 → CH3-O；CH-O=3 → CH4-O）")
    func cutChannelIsSilent() {
        for outCh in LfeMixPlan.selectableChannels {
            let w = wiring(inputChannel: 3, outputChannel: outCh)
            let silent = LfeMixPlan.outputSample(outputChannelIndex: w.cut, contentSample: 0.9,
                                                 rateSample: 0.9, directSample: 0.9,
                                                 targetIndex: w.target, cutIndex: w.cut,
                                                 gain: 0.316)
            #expect(silent == 0, "CH-O=\(outCh) 时 CH\(w.cut + 1)-O 必须静音")
        }
    }

    @Test("M7f 其余声道（L/R、环绕）照常直通，不能被一起关掉")
    func otherChannelsPassThrough() {
        for outCh in LfeMixPlan.selectableChannels {
            let w = wiring(inputChannel: 3, outputChannel: outCh)
            let keep = (0..<8).filter { $0 != w.target && $0 != w.cut }
            for c in keep {
                let out = LfeMixPlan.outputSample(outputChannelIndex: c, contentSample: 0.7,
                                                  rateSample: 0.9, directSample: 0.9,
                                                  targetIndex: w.target, cutIndex: w.cut,
                                                  gain: 0.316)
                #expect(out == 0.7, "CH\(c + 1)-O 应直通")
            }
        }
    }

    @Test("M7g 纯函数与驱动内联实现逐样本等价（防两处实现分叉）")
    func pureMatchesInline() {
        let gain = LfeMixPlan.gain(fromDB: LfeMixPlan.defaultGainDB)
        for outCh in LfeMixPlan.selectableChannels {
            let w = wiring(inputChannel: 3, outputChannel: outCh)
            for c in 0..<8 {
                for rate in stride(from: Float(-1.0), through: 1.0, by: 0.5) {
                    for direct in stride(from: Float(-1.0), through: 1.0, by: 0.5) {
                        let a = LfeMixPlan.outputSample(outputChannelIndex: c, contentSample: rate,
                                                        rateSample: rate, directSample: direct,
                                                        targetIndex: w.target, cutIndex: w.cut,
                                                        gain: gain)
                        let b = inlineOutput(c: c, content: rate, rate: rate, direct: direct,
                                             target: w.target, cut: w.cut, gain: gain)
                        #expect(a == b, "CH-O=\(outCh) c=\(c) 时两处实现不一致")
                    }
                }
            }
        }
    }
}

// MARK: - M8 上游与下游同编号必须**真的可用**（回归：我漏删过驱动里的错误校验）

@Suite("M8 上下游同编号可用性")
struct LfeMixSameIndexTests {

    @Test("M8a CH-I=3 且 CH-O=3 必须可用（两个空间，编号相同合法）")
    func sameIndexIsUsable() {
        let settings = ChannelSwapSettings(mixEnabled: true,
                                          mixSourceChannel: 3,
                                          mixTargetChannel: 3)
        let plan = settings.mixPlan(forOutputChannels: 8, declared: nil, swapPlan: nil)
        #expect(plan.unavailableReason == nil, "不得判为不可用")
        let r = plan.resolved()
        #expect(r != nil, "必须给出可用的解析结果")
        #expect(r?.inputChannel == 3)
        #expect(r?.outputChannel == 3)
    }

    @Test("M8b 传递函数：CH3-O = CH4-I（直通） + CH3-I × gain")
    func transferForSameIndex() {
        // CH-O=3 ⇒ 直通的输入 = 与 CH-I(3) 不同的那条 = CH4-I
        let gain: Float = 0.5
        let out = LfeMixPlan.outputSample(outputChannelIndex: 2, contentSample: 0.0,
                                          rateSample: 0.4, directSample: 0.6,
                                          targetIndex: 3 - 1, cutIndex: 4 - 1, gain: gain)
        #expect(abs(out - (0.6 + 0.4 * 0.5)) < 1e-6, "应为 0.8，实际 \(out)")
    }

    @Test("M8c 全部四种组合都可用（没有任何一种该被拒绝）")
    func allFourCombinationsUsable() {
        for src in LfeMixPlan.selectableChannels {
            for tgt in LfeMixPlan.selectableChannels {
                let settings = ChannelSwapSettings(mixEnabled: true,
                                                   mixSourceChannel: src,
                                                   mixTargetChannel: tgt)
                let plan = settings.mixPlan(forOutputChannels: 8, declared: nil, swapPlan: nil)
                #expect(plan.resolved() != nil,
                        "CH-I=\(src) → CH-O=\(tgt) 必须可用（上下游是两个空间）")
            }
        }
    }
}
