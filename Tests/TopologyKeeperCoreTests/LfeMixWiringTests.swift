import CoreAudio
import Testing
@testable import TopologyKeeperCore

// LFE 混音的**装配层**测试：设置 → 设备声明 → 解析 → 传给驱动。
//
// 为什么单独测这一层：纯逻辑（M 系列）已经证明"算法对"，
// 但真正的风险在于**混音计划有没有真的传到驱动**、
// 以及**交换与混音是否真的互斥**。这两件事错了都会表现为
// "功能开了却没效果"，且日志之外没有任何报错 —— 本项目最怕的静默失效。
//
// 编号：X（assembly）系列。

@Suite("X LFE 混音装配")
struct LfeMixWiringTests {

    private func makeQueue() -> DispatchQueue {
        DispatchQueue(label: "test.mix.\(UUID().uuidString)")
    }

    private func sync(_ q: DispatchQueue, _ body: @escaping @Sendable () -> Void) {
        q.sync(execute: body)
    }

    private func makeSupervisor(resolver: MockSwapResolver,
                                audio: MockSwapAudio,
                                scheduler: FakeScheduler,
                                queue: DispatchQueue) -> ChannelSwapSupervisor {
        ChannelSwapSupervisor(resolver: resolver,
                              audio: audio,
                              queue: queue,
                              executor: scheduler.executor(),
                              notifier: { _ in })
    }

    /// 本机实测的设备声明顺序：L R **LFE C** …（低音在第 3、中置在第 4）
    private var machineDeclared: CoreAudioHelpers.ChannelIndices {
        CoreAudioHelpers.ChannelIndices(lfe: 3, center: 4, descriptionCount: 8)
    }

    /// 不碰 C/LFE 那一对的交换对（隔离用）—— 注意：**仍属"交换已生效"**，
    /// 而交换与混音互斥，所以要测混音时必须 `isEnabled: false`。
    private func nonCollidingSwap() -> (Int, Int) { (5, 6) }

    /// 只开混音、不开交换（用户场景 2：音响没有低音炮）
    private func mixOnlySettings(source: Int = LfeMixPlan.defaultInputChannel) -> ChannelSwapSettings {
        ChannelSwapSettings(isEnabled: false, mixEnabled: true, mixSourceChannel: source)
    }

    // MARK: X1 混音是否真的传到驱动

    @Test("X1a 混音关闭时，传给驱动的是 nil（不产生任何额外开销）")
    func disabledPassesNil() {
        let q = makeQueue()
        let resolver = standardSwapTopology()
        resolver.declaredIndices = machineDeclared
        let audio = MockSwapAudio()
        let sup = makeSupervisor(resolver: resolver, audio: audio,
                                 scheduler: FakeScheduler(), queue: q)

        let pair = nonCollidingSwap()
        sup.apply(ChannelSwapSettings(isEnabled: true,
                                      firstChannel: pair.0, secondChannel: pair.1,
                                      mixEnabled: false))
        sync(q) {}

        #expect(audio.startCount == 1)
        #expect(audio.startMixCalls.first! == nil)
    }

    @Test("X1b 混音计划确实被构造出来，且索引/增益都对")
    func enabledPassesResolvedPlan() {
        // ⚠️ 混音必须"只开混音"才生效（与交换互斥），且此时交换通路不启动，
        //    所以这里校验**解析结果**；"传给驱动"由 X2a 的互斥用例覆盖。
        let resolved = mixOnlySettings()
            .mixPlan(forOutputChannels: 8, declared: machineDeclared, swapPlan: nil)
            .resolved()
        #expect(resolved != nil, "混音计划必须被构造出来，否则功能静默无效")
        // 设备声明低音=3 → 来源 API 索引 2；默认目标第 4 声道 → API 索引 3
        #expect(resolved?.inputAPIIndex == 2)
        #expect(resolved?.outputAPIIndex == 3)
        #expect(abs((resolved?.gain ?? 0) - 0.3162) < 0.001)
    }

    @Test("X1c 默认解析结果恰好是 --phase4 听感通过的那个组合（回归锚点）")
    func defaultConfigMatchesEmpirical() {
        let resolved = ChannelSwapSettings(mixEnabled: true)
            .mixPlan(forOutputChannels: 8, declared: machineDeclared, swapPlan: nil)
            .resolved()
        // Probe/lfe_mix_probe --phase4 用的就是 0-based 索引 2 → 3
        #expect(resolved?.inputAPIIndex == 2, "环形缓冲 plane 2 = 第 3 声道（低音，实测无声）")
        #expect(resolved?.outputAPIIndex == 3, "输出第 4 声道 = 中置（实测有声）")
    }

    @Test("X1d 读不到设备声明时仍可用（回落到默认来源）")
    func worksWithoutDeclaration() {
        let resolved = mixOnlySettings()
            .mixPlan(forOutputChannels: 8, declared: nil, swapPlan: nil)
            .resolved()
        #expect(resolved != nil, "读不到声明也应能混音")
        #expect(resolved?.inputChannel == LfeMixPlan.defaultInputChannel)
    }

    @Test("X1e 混音目标越界时**不阻断交换**（交换是独立功能，仍要跑起来）")
    func outOfRangeMixDoesNotBlockSwap() {
        let q = makeQueue()
        let resolver = standardSwapTopology()
        resolver.declaredIndices = machineDeclared
        let audio = MockSwapAudio()
        let sup = makeSupervisor(resolver: resolver, audio: audio,
                                 scheduler: FakeScheduler(), queue: q)

        let pair = nonCollidingSwap()
        sup.apply(ChannelSwapSettings(isEnabled: true,
                                      firstChannel: pair.0, secondChannel: pair.1,
                                      mixEnabled: true,
                                      mixSourceChannel: 9))   // 越界
        sync(q) {}

        #expect(audio.startCount == 1, "交换仍须启动")
        #expect(audio.startMixCalls.first! == nil, "不可用的混音不应传给驱动")
    }

    @Test("X1f 回归：只开混音时，**音频通路必须启动**（否则整条链路静音）")
    func mixOnlyStartsAudioPath() {
        // 用户实测踩到的 bug：开混音、关交换后**所有声道都没声音**。
        // 根因：通路只由 `isEnabled`(交换开关) 驱动，于是没人从 BlackHole
        // 读数据、也没人写目标设备 —— 桥接断了。
        // 修法：通路判据改为 `needsAudioPath = isEnabled || mixEnabled`。
        let q = makeQueue()
        let resolver = standardSwapTopology()
        resolver.declaredIndices = machineDeclared
        let audio = MockSwapAudio()
        let sup = makeSupervisor(resolver: resolver, audio: audio,
                                 scheduler: FakeScheduler(), queue: q)

        sup.apply(ChannelSwapSettings(isEnabled: false, mixEnabled: true))
        sync(q) {}

        #expect(audio.startCount == 1, "只开混音也必须启动通路（否则静音）")
        #expect(audio.startMixCalls.first! != nil, "并且混音计划要传下去")
        #expect(sup.state.isRunning, "状态应报「运行中」，而不是已停用")
    }

    @Test("X1g 两个功能都关时才停掉通路")
    func stopOnlyWhenBothDisabled() {
        let q = makeQueue()
        let resolver = standardSwapTopology()
        resolver.declaredIndices = machineDeclared
        let audio = MockSwapAudio()
        let sup = makeSupervisor(resolver: resolver, audio: audio,
                                 scheduler: FakeScheduler(), queue: q)

        sup.apply(ChannelSwapSettings(isEnabled: true, mixEnabled: false))
        sync(q) {}
        #expect(audio.startCount == 1)

        sup.apply(ChannelSwapSettings(isEnabled: false, mixEnabled: false))
        sync(q) {}
        #expect(audio.stopCount >= 1, "两个都关才该停通路")
        #expect(sup.state == .disabled)
    }

    @Test("X1h 只开混音时，交换计划退化为恒等（不做任何声道交换）")
    func mixOnlyHasIdentitySwap() {
        let q = makeQueue()
        let resolver = standardSwapTopology()
        resolver.declaredIndices = machineDeclared
        let audio = MockSwapAudio()
        let sup = makeSupervisor(resolver: resolver, audio: audio,
                                 scheduler: FakeScheduler(), queue: q)

        sup.apply(ChannelSwapSettings(isEnabled: false,
                                      firstChannel: 3, secondChannel: 4,
                                      mixEnabled: true))
        sync(q) {}

        // 配置里 first/second 仍是 3/4，但交换**功能关闭** →
        // 通路里不应做任何交换（恒等映射），否则会与混音互相干扰
        let map = audio.startCalls.first?.channelMap ?? []
        #expect(map == (0..<map.count).map { Int32($0) },
                "只开混音时 ChannelMap 必须是恒等映射，实际为 \(map)")
    }

    // MARK: X2 交换与混音互斥（用户确认的产品定义）

    @Test("X2a 交换与混音同时开启 → 混音不生效（互斥）")
    func swapAndMixAreMutuallyExclusive() {
        let q = makeQueue()
        let resolver = standardSwapTopology()
        resolver.declaredIndices = machineDeclared
        let audio = MockSwapAudio()
        let sup = makeSupervisor(resolver: resolver, audio: audio,
                                 scheduler: FakeScheduler(), queue: q)

        // 两个都开（非法组合；正常路径下 UI/CLI 会自动关掉一个）
        sup.apply(ChannelSwapSettings(isEnabled: true,
                                      firstChannel: 3, secondChannel: 4,
                                      mixEnabled: true))
        sync(q) {}

        #expect(audio.startCount == 1, "交换要照常启动")
        #expect(audio.startMixCalls.first! == nil, "互斥：交换生效时不得混音")
    }

    @Test("X2b 只开混音时，解析结果可用（场景 2：音响没有低音炮）")
    func mixOnlyResolves() {
        let resolved = ChannelSwapSettings(isEnabled: false, mixEnabled: true)
            .mixPlan(forOutputChannels: 8, declared: machineDeclared, swapPlan: nil)
            .resolved()
        #expect(resolved != nil)
        #expect(resolved?.outputChannel == 4)
    }

    @Test("X2c 交换涉及 C/LFE 时也不会产生「自己混自己」（互斥已挡住）")
    func neverSelfMixes() {
        let q = makeQueue()
        let resolver = standardSwapTopology()
        resolver.declaredIndices = machineDeclared
        let audio = MockSwapAudio()
        let sup = makeSupervisor(resolver: resolver, audio: audio,
                                 scheduler: FakeScheduler(), queue: q)

        sup.apply(ChannelSwapSettings(isEnabled: true,
                                      firstChannel: 3, secondChannel: 4,
                                      mixEnabled: true))
        sync(q) {}

        if let mix = audio.startMixCalls.first! {
            #expect(mix.outputChannel != mix.inputChannel, "绝不允许自混")
        }
    }

    // MARK: X3 状态暴露（诊断/UI 用）

    @Test("X3a 混音关闭时 mixDescription 为 nil")
    func mixDescriptionNilWhenDisabled() {
        let q = makeQueue()
        let resolver = standardSwapTopology()
        resolver.declaredIndices = machineDeclared
        let audio = MockSwapAudio()
        let sup = makeSupervisor(resolver: resolver, audio: audio,
                                 scheduler: FakeScheduler(), queue: q)

        let pair = nonCollidingSwap()
        sup.apply(ChannelSwapSettings(isEnabled: true,
                                      firstChannel: pair.0, secondChannel: pair.1))
        sync(q) {}

        #expect(sup.mixDescription == nil)
    }

    @Test("X3b 混音开启且可用时，描述串说明源/目标与增益")
    func mixDescriptionWhenEnabled() {
        let text = mixOnlySettings()
            .mixDescription(channels: 8, declared: machineDeclared, swapPlan: nil)
        #expect(text.contains("CH3-I"), "应标明上游声道")
        #expect(text.contains("CH4-O"), "应标明下游声道")
        #expect(text.contains("-10dB"))
    }

    @Test("X3c 通路停止后混音描述被清掉")
    func mixDescriptionClearedOnStop() {
        let q = makeQueue()
        let resolver = standardSwapTopology()
        resolver.declaredIndices = machineDeclared
        let audio = MockSwapAudio()
        let sup = makeSupervisor(resolver: resolver, audio: audio,
                                 scheduler: FakeScheduler(), queue: q)

        // 只开交换：通路会启动，且混音（互斥）不生效 → 描述应为 nil
        let pair = nonCollidingSwap()
        sup.apply(ChannelSwapSettings(isEnabled: true,
                                      firstChannel: pair.0, secondChannel: pair.1))
        sync(q) {}
        #expect(sup.mixDescription == nil)

        sup.stop()
        sync(q) {}
        #expect(sup.mixDescription == nil)
    }

    @Test("X3d 互斥组合下 mixDescription 必须明说「不可用」（不能报成正常）")
    func mixDescriptionReportsUnavailableUnderSwap() {
        let q = makeQueue()
        let resolver = standardSwapTopology()
        resolver.declaredIndices = machineDeclared
        let audio = MockSwapAudio()
        let sup = makeSupervisor(resolver: resolver, audio: audio,
                                 scheduler: FakeScheduler(), queue: q)

        sup.apply(ChannelSwapSettings(isEnabled: true,
                                      firstChannel: 3, secondChannel: 4,
                                      mixEnabled: true))
        sync(q) {}

        #expect((sup.mixDescription ?? "").contains("不可用"),
                "互斥组合必须显式说明，而不是显示成正常混音")
    }

    // MARK: X4 诊断快照的功能感知（UI 状态栏直接消费）

    @Test("X4a 只开混音时诊断报 mix，状态文案与映射都不得是「交换」那套")
    func diagnosticsReportMixWhenOnlyMixEnabled() {
        let q = makeQueue()
        let resolver = standardSwapTopology()
        resolver.declaredIndices = machineDeclared
        let audio = MockSwapAudio()
        let sup = makeSupervisor(resolver: resolver, audio: audio,
                                 scheduler: FakeScheduler(), queue: q)

        sup.apply(mixOnlySettings())
        sync(q) {}

        let d = sup.diagnostics()
        #expect(d.state == .running)
        // 回归点：先前 UI 拿到的 activeFunction 恒为 swap，
        // 于是状态栏显示"交换中"、映射显示"恒等映射"。
        #expect(d.activeFunction == .mix)
        #expect(d.statusText == "混音中")
        // 状态栏「映射」= 传递函数首行，必须与配置页「当前传递函数」首行**逐字一致**
        #expect(d.mappingDescription == "CH4-O = CH4-I + CH3-I × 0.316")
        #expect(!d.mappingDescription.contains("恒等映射"),
                "混音不写 ChannelMap —— 回落成恒等映射会让用户以为没生效")
    }

    @Test("X4b 只开交换时诊断仍报 swap，映射走 ChannelMap 描述")
    func diagnosticsReportSwapWhenOnlySwapEnabled() {
        let q = makeQueue()
        let resolver = standardSwapTopology()
        resolver.declaredIndices = machineDeclared
        let audio = MockSwapAudio()
        let sup = makeSupervisor(resolver: resolver, audio: audio,
                                 scheduler: FakeScheduler(), queue: q)

        let pair = nonCollidingSwap()
        sup.apply(ChannelSwapSettings(isEnabled: true,
                                      firstChannel: pair.0, secondChannel: pair.1))
        sync(q) {}

        let d = sup.diagnostics()
        #expect(d.state == .running)
        #expect(d.activeFunction == .swap)
        #expect(d.statusText == "交换中")
        // 输入在前：交换 5↔6 ⇒ "CH6-I → CH5-O、CH5-I → CH6-O"
        #expect(d.mappingDescription.contains("CH\(pair.1)-I → CH\(pair.0)-O"))
    }
}
