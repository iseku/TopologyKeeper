import CoreAudio
import Testing
@testable import TopologyKeeperCore

// 声道处理**引擎总开关**与「直通」模式（v0.1.1）。
//
// 这一组锁定的都是**用户确认的行为约定**，改坏了会直接体现为
// "升级后突然没声音""点了开关没反应"或"直通被做成了静音"：
//
//   * 全新安装默认**关闭**（不擅自接管音频链路）；
//   * 老配置（没有该键）按已有功能开关**迁移** ⇒ 升级不会突然全断；
//   * 总开关关闭 = **全断**：通路完全不跑、不占用任何音频设备；
//   * 总开关开启 + 两个功能都关 = **直通**：通路**必须跑**（恒等置换），
//     否则音频进了 BlackHole 出不来，整条链路静音；
//   * 状态文案四种模式各不相同：直通中 / 交换中 / 混音中 / 未启用。
//
// 编号：P（processing engine）系列。

@Suite("P 声道处理引擎总开关与直通")
struct ChannelProcessingEngineTests {

    // MARK: 夹具（与 S2 / X 两套同构；夹具是 private，故此处自带一份）

    private func makeQueue() -> DispatchQueue {
        DispatchQueue(label: "test.engine.\(UUID().uuidString)")
    }

    private func sync(_ q: DispatchQueue, _ body: @escaping @Sendable () -> Void) {
        q.sync(execute: body)
    }

    private func makeSupervisor(resolver: MockSwapResolver,
                                audio: MockSwapAudio,
                                queue: DispatchQueue,
                                notified: ValueBox<String>? = nil) -> ChannelSwapSupervisor {
        ChannelSwapSupervisor(resolver: resolver,
                              audio: audio,
                              queue: queue,
                              executor: FakeScheduler().executor(),
                              notifier: { message in notified?.value = message })
    }

    /// 本机实测的设备声明顺序：L R **LFE C** …（低音在第 3、中置在第 4）
    private var machineDeclared: CoreAudioHelpers.ChannelIndices {
        CoreAudioHelpers.ChannelIndices(lfe: 3, center: 4, descriptionCount: 8)
    }

    private func roundTrip(_ settings: ChannelSwapSettings) throws -> ChannelSwapSettings {
        let data = try JSONEncoder().encode(settings)
        return try JSONDecoder().decode(ChannelSwapSettings.self, from: data)
    }

    // MARK: P1 默认值与升级迁移
    //
    // ★ 这一组是本轮**最贵**的一条约定：迁移写错的表现是
    //   "配置看着没问题、功能开关也都还开着，但一点声音都没有"。

    @Test("P1a 全新配置：总开关默认关闭，且不占用通路（首次使用不擅自接管音频）")
    func engineDefaultsOff() {
        let s = ChannelSwapSettings()
        #expect(s.engineEnabled == false, "首次使用必须默认关闭（用户要求）")
        #expect(s.needsAudioPath == false, "关闭时不跑通路")
        #expect(s.processingMode == .off, "关闭即全断")
    }

    @Test("P1b 老配置（无 engineEnabled 键）且交换已启用 → 迁移为开启（升级不会突然静音）")
    func legacyConfigWithSwapMigratesToEngineOn() throws {
        let legacy = """
        {"isEnabled":true,"firstChannel":3,"secondChannel":4,
         "alignInputSampleRate":true,"retryBackoffMs":[1000,2000],"notifyOnGiveUp":true}
        """
        let s = try JSONDecoder().decode(ChannelSwapSettings.self, from: Data(legacy.utf8))
        #expect(s.isEnabled == true, "老字段照常解出")
        #expect(s.engineEnabled == true, "老配置里功能开着 ⇒ 引擎视为开启")
        #expect(s.needsAudioPath == true, "否则升级后通路不跑 = 全断（无声）")
    }

    @Test("P1c 老配置且混音开着 → 同样迁移为开启")
    func legacyConfigWithMixMigratesToEngineOn() throws {
        let legacy = """
        {"isEnabled":false,"mixEnabled":true,"mixGainDB":-10,
         "mixSourceChannel":3,"mixTargetChannel":4}
        """
        let s = try JSONDecoder().decode(ChannelSwapSettings.self, from: Data(legacy.utf8))
        #expect(s.engineEnabled == true)
        #expect(s.processingMode == .mix)
    }

    @Test("P1d 老配置且两个功能都没开 → 迁移为关闭（这才是真正的「首次使用」语义）")
    func legacyConfigWithoutFeaturesStaysOff() throws {
        let legacy = """
        {"isEnabled":false,"mixEnabled":false,"firstChannel":3,"secondChannel":4}
        """
        let s = try JSONDecoder().decode(ChannelSwapSettings.self, from: Data(legacy.utf8))
        #expect(s.engineEnabled == false)
        #expect(s.processingMode == .off)
    }

    @Test("P1e 配置里显式写着 false → 尊重用户的选择，绝不自动打开")
    func explicitFalseIsRespected() throws {
        let json = """
        {"engineEnabled":false,"isEnabled":true,"mixEnabled":false}
        """
        let s = try JSONDecoder().decode(ChannelSwapSettings.self, from: Data(json.utf8))
        #expect(s.engineEnabled == false,
                "用户主动关过引擎（功能开关还开着）—— 迁移逻辑不得覆盖它")
        #expect(s.isEnabled == true, "功能开关原样保留，重开引擎即恢复")
    }

    @Test("P1f ★ 直通配置必须能原样往返（否则重开 App 会掉回全断）")
    func passThroughConfigRoundTrips() throws {
        // 用户手动开的引擎 + 两个功能都关 = 直通。这条组合是**新引入**的，
        // 若编码漏了 engineEnabled，重启后就会静默退回"全断"。
        let back = try roundTrip(ChannelSwapSettings(engineEnabled: true))
        #expect(back.engineEnabled == true)
        #expect(back.processingMode == .passThrough)
        #expect(back.needsAudioPath == true)
    }

    @Test("P1g 关闭引擎后重开：功能开关原样保留（不丢配置）")
    func engineTogglePreservesFeatureConfig() throws {
        var s = ChannelSwapSettings(engineEnabled: true, isEnabled: true)
        s.engineEnabled = false
        let back = try roundTrip(s)
        #expect(back.engineEnabled == false)
        #expect(back.isEnabled == true, "功能配置不许被引擎开关顺手清掉")
    }

    // MARK: P2 四种模式的判定

    @Test("P2a 模式表：全断 / 直通 / 交换 / 混音")
    func processingModeTable() {
        #expect(ChannelSwapSettings().processingMode == .off)
        #expect(ChannelSwapSettings(engineEnabled: true).processingMode == .passThrough)
        #expect(ChannelSwapSettings(engineEnabled: true, isEnabled: true).processingMode == .swap)
        #expect(ChannelSwapSettings(engineEnabled: true, mixEnabled: true).processingMode == .mix)
        #expect(ChannelSwapSettings(engineEnabled: false, isEnabled: true).processingMode == .off,
                "引擎关着时，功能开关再开着也只是「全断」")
    }

    @Test("P2b 非法组合（两个功能都开）以**交换**为准，与运行期实际行为一致")
    func illegalCombinationPrefersSwap() {
        // 运行期：mixPlan 检测到非恒等交换会返回"不可用" ⇒ 实际只交换；
        // AppState 的兜底也是"保留交换、关掉混音"。模式判定必须同上，
        // 否则界面会显示成"混音中"而实际跑的是交换。
        let s = ChannelSwapSettings(engineEnabled: true, isEnabled: true, mixEnabled: true)
        #expect(s.processingMode == .swap)
    }

    @Test("P2c 便捷构造：给功能开关就等于给引擎开关（既有调用点的语义不变）")
    func convenienceInitFollowsFeatureFlags() {
        #expect(ChannelSwapSettings(isEnabled: true).engineEnabled == true)
        #expect(ChannelSwapSettings(mixEnabled: true).engineEnabled == true)
        #expect(ChannelSwapSettings(isEnabled: false, mixEnabled: false).engineEnabled == false)
        // 显式传值优先于推导
        #expect(ChannelSwapSettings(engineEnabled: false, isEnabled: true).engineEnabled == false)
        #expect(ChannelSwapSettings(engineEnabled: true).engineEnabled == true)
    }

    // MARK: P3 真实装配行为（Mock 驱动）

    @Test("P3a ★ 总开关关闭 = 全断：通路完全不启动，不占用任何音频设备")
    func engineOffKeepsPathStopped() {
        let q = makeQueue()
        let resolver = standardSwapTopology()
        let audio = MockSwapAudio()
        let sup = makeSupervisor(resolver: resolver, audio: audio, queue: q)

        // 功能开关开着，但引擎关着 ⇒ 一切都不该发生
        sup.apply(ChannelSwapSettings(engineEnabled: false, isEnabled: true))
        sync(q) {}

        #expect(audio.startCount == 0, "全断时不得占用设备")
        #expect(sup.state == .disabled)
        #expect(sup.diagnostics().activeFunction == .off)
        #expect(sup.diagnostics().statusText == "未启用")
    }

    @Test("P3b ★ 总开关开 + 两个功能都关 = 直通：通路必须跑，且是恒等映射")
    func passThroughStartsIdentityPath() {
        // 这条是本轮的核心：早先"两个功能都关"会让通路停掉，
        // 而用户的系统默认输出是 BlackHole ⇒ 音频进了虚拟设备出不来，整条链路静音。
        let q = makeQueue()
        let resolver = standardSwapTopology()
        resolver.declaredIndices = machineDeclared
        let audio = MockSwapAudio()
        let sup = makeSupervisor(resolver: resolver, audio: audio, queue: q)

        sup.apply(ChannelSwapSettings(engineEnabled: true))
        sync(q) {}

        #expect(audio.startCount == 1, "直通也必须跑通路，否则音频出不来")
        let map = audio.startCalls.first?.channelMap ?? []
        #expect(map == (0..<map.count).map { Int32($0) },
                "直通必须是恒等映射，实际为 \(map)")
        #expect(audio.startMixCalls.first! == nil, "直通不做混音")

        let d = sup.diagnostics()
        #expect(sup.state == .running)
        #expect(d.activeFunction == .passThrough)
        #expect(d.statusText == "直通中", "用户要求：直通时显示「直通中」")
        #expect(d.mappingDescription.contains("直通"),
                "映射一行必须说明「直通」，不能与「未设置」混淆")
        #expect(d.mappingDescription.contains("8 声道"))
    }

    @Test("P3c 直通模式下交换计划恒等 —— 不得顺手按配置里的 3↔4 去换")
    func passThroughDoesNotSwap() {
        let q = makeQueue()
        let resolver = standardSwapTopology()
        let audio = MockSwapAudio()
        let sup = makeSupervisor(resolver: resolver, audio: audio, queue: q)

        // 配置里 first/second 仍是默认的 3/4，但交换功能是关的
        sup.apply(ChannelSwapSettings(engineEnabled: true, firstChannel: 3, secondChannel: 4))
        sync(q) {}

        let plan = audio.startCalls.first?.plan
        #expect(plan?.isIdentity == true, "直通必须是恒等计划，实际为 \(String(describing: plan))")
    }

    @Test("P3d ★ 从交换切到直通（只关交换、引擎保持开）→ 通路不停，改为恒等装配")
    func switchingFromSwapToPassThroughKeepsPathRunning() {
        let q = makeQueue()
        let resolver = standardSwapTopology()
        resolver.declaredIndices = machineDeclared
        let audio = MockSwapAudio()
        let sup = makeSupervisor(resolver: resolver, audio: audio, queue: q)

        sup.apply(ChannelSwapSettings(engineEnabled: true, isEnabled: true))
        sync(q) {}
        #expect(audio.startCount == 1)

        let stopBefore = audio.stopCount
        sup.apply(ChannelSwapSettings(engineEnabled: true, isEnabled: false))
        sync(q) {}

        #expect(audio.startCount == 2, "设置变了必须重新装配（否则改了配置没反应）")
        #expect(audio.stopCount == stopBefore, "直通**不是**停止通路，不该出现「停再起」")
        #expect(sup.state == .running)
        #expect(sup.diagnostics().activeFunction == .passThrough)
        #expect(sup.diagnostics().statusText == "直通中")
    }

    @Test("P3e 关闭总开关 → 停通路并回到全断（功能开关保持开着也不跑）")
    func turningEngineOffStopsPath() {
        let q = makeQueue()
        let resolver = standardSwapTopology()
        resolver.declaredIndices = machineDeclared
        let audio = MockSwapAudio()
        let sup = makeSupervisor(resolver: resolver, audio: audio, queue: q)

        sup.apply(ChannelSwapSettings(engineEnabled: true, isEnabled: true))
        sync(q) {}
        #expect(audio.startCount == 1)

        sup.apply(ChannelSwapSettings(engineEnabled: false, isEnabled: true))
        sync(q) {}

        #expect(audio.stopCount >= 1, "全断必须释放设备")
        #expect(sup.state == .disabled)
        #expect(sup.diagnostics().activeFunction == .off)
    }

    @Test("P3f 引擎关着时，设备事件不会偷偷把通路拉起来")
    func devicesChangedIsGatedWhenEngineOff() {
        let q = makeQueue()
        let resolver = standardSwapTopology()
        let audio = MockSwapAudio()
        let sup = makeSupervisor(resolver: resolver, audio: audio, queue: q)

        sup.apply(ChannelSwapSettings(engineEnabled: false, isEnabled: true))
        sync(q) {}

        // 设备拓扑变化 / 设备被销毁 —— 两条入口都不该绕开总开关
        sup.devicesChanged()
        sync(q) {}
        sup.devicesDisappeared()
        sync(q) {}

        #expect(audio.startCount == 0, "全断期间设备事件不得启动通路")
        #expect(sup.state == .disabled)
    }

    // MARK: P4 状态文案（首页 / 配置页 / 菜单栏共用）

    @Test("P4a 直通的状态文案是「直通中」，不是「未启用」")
    func passThroughStatusText() {
        #expect(ChannelSwapDiagnostics(state: .running,
                                       activeFunction: .passThrough).statusText == "直通中")
    }

    @Test("P4b 全断（引擎关闭）的状态文案仍是「未启用」")
    func offStatusText() {
        #expect(ChannelSwapDiagnostics(state: .disabled,
                                       activeFunction: .off).statusText == "未启用")
    }

    @Test("P4c 直通的映射描述写明「直通 + 声道数」")
    func passThroughMappingDescription() {
        let d = ChannelSwapDiagnostics(state: .running,
                                       appliedChannelMap: [0, 1, 2, 3, 4, 5, 6, 7],
                                       activeFunction: .passThrough)
        #expect(d.mappingDescription == "直通（恒等映射，8 声道）")
    }

    @Test("P4d 四种模式的短名与全名唯一（CLI 与界面共用同一份，不许各写一套）")
    func modeNamesAreStable() {
        #expect(ChannelProcessingFunction.off.shortName == "全断")
        #expect(ChannelProcessingFunction.passThrough.shortName == "直通")
        #expect(ChannelProcessingFunction.swap.shortName == "交换")
        #expect(ChannelProcessingFunction.mix.shortName == "混音")
        #expect(ChannelProcessingFunction.passThrough.runningText == "直通中")
        #expect(ChannelProcessingFunction.swap.runningText == "交换中")
        #expect(ChannelProcessingFunction.mix.runningText == "混音中")
        #expect(ChannelProcessingFunction.off.runningText == "未启用")
    }

    // MARK: P5 "最近使用的功能"记忆
    //
    // 两个用户实测问题同源 —— 界面原先只有"当前是否开着"这一个信息，
    // 两个功能一关，"用户原本用的是哪个"就丢了：
    //   ① 首页卡片标题从「LFE 混音」跳成「直通」（用户要求：标题保持、状态行提示即可）；
    //   ② 卡片开关"关掉再打开"总是变成交换（真 bug：关闭时 mixEnabled 已是 false，
    //      重开就落进"否则开交换"）。

    @Test("P5a 开启功能即建立记忆（开混音 ⇒ 记忆为混音）")
    func memoryIsSetWhenEnabling() {
        var s = ChannelSwapSettings()
        s.engineEnabled = true
        s.mixEnabled = true
        s.rememberEnabledFeature()
        #expect(s.lastEnabledFeature == .mix)

        var t = ChannelSwapSettings()
        t.engineEnabled = true
        t.isEnabled = true
        t.rememberEnabledFeature()
        #expect(t.lastEnabledFeature == .swap)
    }

    @Test("P5b ★ 功能全关后记忆必须保持（否则标题跳变、重开跳功能）")
    func memorySurvivesDisabling() {
        var s = ChannelSwapSettings(engineEnabled: true, mixEnabled: true)
        s.rememberEnabledFeature()
        #expect(s.lastEnabledFeature == .mix)

        // 关掉混音（引擎保持开着）→ 直通
        s.mixEnabled = false
        s.rememberEnabledFeature()      // 收口点每次写配置都会调用
        #expect(s.lastEnabledFeature == .mix, "两个都关时必须保留记忆")
        #expect(s.processingMode == .passThrough,
                "当前模式是直通 —— 与「记忆」是两件事，别混")
    }

    @Test("P5c 功能互切会更新记忆（混音 → 交换 → 混音）")
    func memoryUpdatesOnSwitch() {
        var s = ChannelSwapSettings(engineEnabled: true, mixEnabled: true)
        s.rememberEnabledFeature()
        #expect(s.lastEnabledFeature == .mix)

        s.mixEnabled = false
        s.isEnabled = true
        s.rememberEnabledFeature()
        #expect(s.lastEnabledFeature == .swap)

        s.isEnabled = false
        s.mixEnabled = true
        s.rememberEnabledFeature()
        #expect(s.lastEnabledFeature == .mix)
    }

    @Test("P5d 便捷构造：混音开着 ⇒ 记忆为混音（既有调用点语义自然正确）")
    func convenienceInitRemembers() {
        #expect(ChannelSwapSettings(mixEnabled: true).lastEnabledFeature == .mix)
        #expect(ChannelSwapSettings(isEnabled: true).lastEnabledFeature == .swap)
        #expect(ChannelSwapSettings().lastEnabledFeature == .swap, "默认值是交换")
    }

    @Test("P5e ★ 老配置迁移：混音开着 ⇒ 记忆为混音（否则界面会把它显示成交换）")
    func legacyConfigRemembersLastFeature() throws {
        let legacy = """
        {"isEnabled":false,"mixEnabled":true,"mixGainDB":-1,
         "mixSourceChannel":3,"mixTargetChannel":4}
        """
        let s = try JSONDecoder().decode(ChannelSwapSettings.self, from: Data(legacy.utf8))
        #expect(s.lastEnabledFeature == .mix,
                "老配置里混音开着 —— 用户最近用的就是混音，迁移必须据此推断")
    }

    @Test("P5f 记忆能原样往返（重启后标题与「关掉再打开」仍然正确）")
    func memoryRoundTrips() throws {
        var s = ChannelSwapSettings(engineEnabled: true, mixEnabled: true)
        s.rememberEnabledFeature()
        s.mixEnabled = false                    // 当前是直通，但记忆是混音
        let back = try roundTrip(s)
        #expect(back.lastEnabledFeature == .mix, "否则重启后重开会跳成交换")
        #expect(back.processingMode == .passThrough)
    }

    @Test("P5g ★ ConfigStore 收口：任何写路径都会更新记忆（GUI 与 tkctl 共用同一条路）")
    func configStoreUpdatesMemory() {
        // 收口放在 `ConfigStore.update` 而不是各个界面动作里 ——
        // 因为写配置有两条路径（GUI 的 AppState 与 tkctl 的 store.update），
        // 分散维护必然会漏一条。
        guard let defaults = UserDefaults(suiteName: "tk.test.\(UUID().uuidString)") else {
            Issue.record("无法创建隔离的 UserDefaults，跳过")
            return
        }
        let store = ConfigStore(defaults: defaults, key: "config")

        store.update {
            $0.channelSwap.engineEnabled = true
            $0.channelSwap.mixEnabled = true
        }
        #expect(store.config.channelSwap.lastEnabledFeature == .mix)

        // tkctl 风格的写路径：直接 store.update（不经过 AppState）
        store.update { $0.channelSwap.mixEnabled = false }
        #expect(store.config.channelSwap.lastEnabledFeature == .mix,
                "关闭功能后记忆必须保持")

        // 再开另一个功能 → 记忆随之更新
        store.update { $0.channelSwap.isEnabled = true }
        #expect(store.config.channelSwap.lastEnabledFeature == .swap)
    }
}
