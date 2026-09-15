import CoreAudio
import Testing
@testable import TopologyKeeperCore

// 声道交换状态机与重试策略的单元测试（S2）。
//
// 这一组锁定的都是**用户确认的行为约定**，改坏了会直接体现为
// "该重试时不重试""该告警时不告警"或"无限重试"：
//   * 目标设备 <6 声道 → 报"等待"并退避重试，**不是失败**
//   * 回退序列 1-2-4-8 秒，穷尽后 → gaveUp + 告警
//   * 引擎必须**始终**设置 ChannelMap（含恒等）
//   * 采样率对齐**只写输入设备**
//
// 所有测试在专用串行队列上跑，并用 FakeScheduler 手动推进时间。

@Suite("S2 声道交换状态机")
struct ChannelSwapSupervisorTests {

    // MARK: 夹具

    private func makeQueue() -> DispatchQueue {
        DispatchQueue(label: "test.swap.\(UUID().uuidString)")
    }

    /// 在队列上同步执行并等待完成（测试里需要确定性）
    private func sync(_ q: DispatchQueue, _ body: @escaping @Sendable () -> Void) {
        q.sync(execute: body)
    }

    private func makeSupervisor(resolver: MockSwapResolver,
                                audio: MockSwapAudio,
                                scheduler: FakeScheduler,
                                queue: DispatchQueue,
                                notified: ValueBox<String>)
        -> ChannelSwapSupervisor {
        ChannelSwapSupervisor(
            resolver: resolver,
            audio: audio,
            queue: queue,
            executor: scheduler.executor(),
            notifier: { message in notified.value = message })
    }

    private var enabledSettings: ChannelSwapSettings {
        ChannelSwapSettings(isEnabled: true)
    }

    // MARK: 基本启动

    @Test("S2a 条件满足时启动，并写入正确的交换映射")
    func startsWhenEligible() {
        let q = makeQueue()
        let resolver = standardSwapTopology()
        let audio = MockSwapAudio()
        let sched = FakeScheduler()
        let sup = makeSupervisor(resolver: resolver, audio: audio, scheduler: sched, queue: q, notified: ValueBox<String>(""))

        sup.apply(enabledSettings)
        sync(q) {}

        #expect(sup.state == .running)
        #expect(audio.startCount == 1)
        #expect(sup.appliedChannelMap == [0, 1, 3, 2, 4, 5, 6, 7])
        // 默认输出就是目标设备 → 应走 DefaultOutput 路径
        #expect(audio.startCalls.first?.outputIsDefault == true)
    }

    @Test("S2b 关闭总开关后停止并释放设备")
    func stopsWhenDisabled() {
        let q = makeQueue()
        let audio = MockSwapAudio()
        let sup = makeSupervisor(resolver: standardSwapTopology(), audio: audio,
                                 scheduler: FakeScheduler(), queue: q, notified: ValueBox<String>(""))

        sup.apply(enabledSettings); sync(q) {}
        #expect(sup.state == .running)

        sup.apply(ChannelSwapSettings(isEnabled: false)); sync(q) {}
        #expect(sup.state == .disabled)
        #expect(audio.stopCount >= 1)
        #expect(sup.appliedChannelMap == nil)
    }

    @Test("S2c 幂等：设置未变且正在运行时，重复 apply 不重启音频通路")
    func applyIsIdempotent() {
        let q = makeQueue()
        let audio = MockSwapAudio()
        let sup = makeSupervisor(resolver: standardSwapTopology(), audio: audio,
                                 scheduler: FakeScheduler(), queue: q, notified: ValueBox<String>(""))

        sup.apply(enabledSettings); sync(q) {}
        sup.apply(enabledSettings); sync(q) {}
        sup.apply(enabledSettings); sync(q) {}

        #expect(audio.startCount == 1, "重复 apply 不应反复重启（会抖爆设备）")
    }

    // MARK: 核心：<6 声道走"等待 + 指数回退"

    @Test("S2d 目标设备只有 2 声道时进入等待，而不是失败")
    func waitsWhenChannelsTooFew() {
        let q = makeQueue()
        let resolver = standardSwapTopology(outputChannels: 2)   // 设备掉回 2ch
        let audio = MockSwapAudio()
        let sched = FakeScheduler()
        let sup = makeSupervisor(resolver: resolver, audio: audio, scheduler: sched, queue: q, notified: ValueBox<String>(""))

        sup.apply(enabledSettings)
        sync(q) {}

        guard case .waiting(let reason, let attempt, let next) = sup.state else {
            Issue.record("应处于 waiting，实际 \(sup.state)"); return
        }
        #expect(reason == .outputChannelsTooFew(current: 2, required: 6))
        #expect(attempt == 1)
        #expect(next == 1000)                 // 第一次 1 秒
        #expect(audio.startCount == 0, "条件不满足时一次都不该启动音频通路")
    }

    @Test("S2e 回退序列严格是 1-2-4-8 秒（用户确认的策略）")
    func backoffSequenceIsOneTwoFourEight() {
        let q = makeQueue()
        let resolver = standardSwapTopology(outputChannels: 2)
        let audio = MockSwapAudio()
        let sched = FakeScheduler()
        let sup = makeSupervisor(resolver: resolver, audio: audio, scheduler: sched, queue: q, notified: ValueBox<String>(""))

        sup.apply(enabledSettings)
        sync(q) {}
        // 反复推进时间：每次都会因条件不满足再安排下一次
        for _ in 0..<4 {
            sched.fireAll()
            q.sync {}
        }
        #expect(sched.requestedDelays == [1000, 2000, 4000, 8000])
        #expect(audio.startCount == 0)
    }

    @Test("S2f 回退穷尽后进入 gaveUp 并发出告警（只发一次）")
    func givesUpAndNotifiesAfterBackoffExhausted() {
        let q = makeQueue()
        let resolver = standardSwapTopology(outputChannels: 2)
        let audio = MockSwapAudio()
        let sched = FakeScheduler()
        let box = ValueBox<String>("")
        let sup = makeSupervisor(resolver: resolver, audio: audio, scheduler: sched,
                                 queue: q, notified: box)

        sup.apply(enabledSettings)
        sync(q) {}
        // 4 次回退全部推进（1-2-4-8），第 5 次评估时序列已穷尽
        for _ in 0..<5 {
            sched.fireAll()
            q.sync {}
        }

        guard case .gaveUp(let reason, let attempts) = sup.state else {
            Issue.record("应处于 gaveUp，实际 \(sup.state)"); return
        }
        #expect(attempts == 4)
        #expect(reason == .outputChannelsTooFew(current: 2, required: 6))
        #expect(box.value.contains("已重试 4 次"))
        // 再推进也不该重复告警
        sched.fireAll(); q.sync {}
        #expect(sup.state == .gaveUp(reason: reason, attempts: 4))
        #expect(audio.startCount == 0)
    }

    @Test("S2g 等待期间设备恢复 → 自动启动（这正是格式锁定生效后的情形）")
    func recoversWhenDeviceBecomesEligible() {
        let q = makeQueue()
        let resolver = standardSwapTopology(outputChannels: 2)
        let audio = MockSwapAudio()
        let sched = FakeScheduler()
        let sup = makeSupervisor(resolver: resolver, audio: audio, scheduler: sched, queue: q, notified: ValueBox<String>(""))

        sup.apply(enabledSettings)
        sync(q) {}
        #expect(!sup.state.isRunning)

        // 模拟 TopologyKeeper 把设备锁回 8ch
        resolver.devices = resolver.devices.map { d in
            makeSwapDevice(name: d.name, uid: d.uid, id: d.id,
                           outputChannels: d.isBlackHole ? 16 : 8,
                           inputChannels: d.inputChannels, rate: d.nominalSampleRate)
        }
        resolver.resolveByUID = Dictionary(uniqueKeysWithValues: resolver.devices.map { ($0.uid, $0) })
        resolver.defaultOutputUID = "00000000-0000-0000-0000"

        sched.fireAll()
        q.sync {}

        #expect(sup.state == .running)
        #expect(audio.startCount == 1)
        #expect(sup.appliedChannelMap == [0, 1, 3, 2, 4, 5, 6, 7])
    }

    @Test("S2h devicesChanged 会重置回退计数（设备变化是新情况，应给足机会）")
    func devicesChangedResetsBackoff() {
        let q = makeQueue()
        let resolver = standardSwapTopology(outputChannels: 2)
        let sched = FakeScheduler()
        let sup = makeSupervisor(resolver: resolver, audio: MockSwapAudio(),
                                 scheduler: sched, queue: q, notified: ValueBox<String>(""))

        sup.apply(enabledSettings); sync(q) {}
        sched.fireAll(); q.sync {}      // 第 1 次回退（1s）→ 再安排 2s
        sched.fireAll(); q.sync {}      // 第 2 次回退（2s）→ 再安排 4s
        #expect(sched.requestedDelays == [1000, 2000, 4000])

        sup.devicesChanged(); sync(q) {}
        #expect(sup.retryAttempt == 1, "设备变化后回退计数应重置")
    }

    // MARK: 设备事件成簇时的幂等短路（真机实测：唤醒瞬间连着重启 4 次）

    @Test("S2ac 设备未变时 devicesChanged 不重新装配（避免无谓的音频中断）")
    func devicesChangedIsIdempotentWhenDevicesUnchanged() {
        // 真机实测（修复唤醒失效问题时的验证日志 20:43:38）：
        // "设备拓扑变化"与"规则已锁定"通知在同一瞬间到达，
        // 连着重启了 4 次（间隔约 130ms）—— 功能没变，音频却断了两下。
        let q = makeQueue()
        let resolver = standardSwapTopology()
        let audio = MockSwapAudio()
        let sup = makeSupervisor(resolver: resolver, audio: audio,
                                 scheduler: FakeScheduler(), queue: q,
                                 notified: ValueBox<String>(""))

        sup.apply(enabledSettings); sync(q) {}
        #expect(audio.startCount == 1)

        for _ in 0..<5 { sup.devicesChanged(); sync(q) {} }

        #expect(audio.startCount == 1,
                "设备解析结果完全一致时不该重新装配（重启一次就断一次音频）")
        #expect(sup.state == .running)
    }

    @Test("S2ah 幂等短路按来源计数 —— 回答「是谁在反复喂评估」")
    func skipStatisticsAreBrokenDownByOrigin() {
        // 回归背景（真机日志实锤，2026-09-14 20:00:55）：
        // 唤醒后通路刚装配好，紧接着连出 5 条"设备与设置都未变，跳过重新装配"。
        // 那 5 条**行为正确**（幂等短路），但日志只有条数、没有来源，
        // 排查时无法分辨它们来自设备事件簇、规则锁定通知还是手动重试。
        // ⇒ 现在每个来源分别计数，并直接写进诊断。
        let q = makeQueue()
        let resolver = standardSwapTopology()
        let audio = MockSwapAudio()
        let sup = makeSupervisor(resolver: resolver, audio: audio,
                                 scheduler: FakeScheduler(), queue: q,
                                 notified: ValueBox<String>(""))

        sup.apply(enabledSettings); sync(q) {}
        #expect(audio.startCount == 1)

        for _ in 0..<3 { sup.devicesChanged(); sync(q) {} }

        #expect(audio.startCount == 1, "全都该被短路挡下")
        let stats = sup.diagnostics().skipStatistics ?? ""
        #expect(stats.contains("devices=3"), "设备事件来源应计 3 次，实际：\(stats)")

        // ⚠️ 这里**故意**再推一份完全相同的设置，并断言它**不**计入统计。
        //    原因（写下来免得将来误以为是漏测）：`apply` 在"设置没变且正在运行"
        //    时于 `applyLocked` 顶层就 return 了，根本不会走到短路分支 ——
        //    也就是说 `settings` 这个来源在正常流程下**不可能**出现在统计里。
        //    它仍是合法的来源标记：`applyLocked` 里那条评估路径确实带这个标签。
        sup.apply(enabledSettings); sync(q) {}
        #expect(sup.diagnostics().skipStatistics == stats,
                "设置没变时 apply 在顶层就返回，不应产生新的评估")
    }

    @Test("S2ai 设备销毁会清空来源统计（它描述的是「那条通路」的幂等情况）")
    func disappearedResetsSkipStatistics() {
        // 旧通路被销毁后统计必须归零：否则界面上会显示一条**已不存在**的通路
        // 的跳过次数，把排查引到错误方向（"设备都重建了，怎么还在跳过？"）。
        let q = makeQueue()
        let resolver = standardSwapTopology()
        let audio = MockSwapAudio()
        let sup = makeSupervisor(resolver: resolver, audio: audio,
                                 scheduler: FakeScheduler(), queue: q,
                                 notified: ValueBox<String>(""))

        sup.apply(enabledSettings); sync(q) {}
        sup.devicesChanged(); sync(q) {}
        #expect(sup.diagnostics().skipStatistics?.contains("devices=1") == true)

        sup.devicesDisappeared(); sync(q) {}
        #expect(sup.diagnostics().skipStatistics == nil, "设备销毁后统计应清空")

        // 重建之后重新计数（新通路的第一次设备事件仍会被短路，因为拓扑相同）
        sup.devicesChanged(); sync(q) {}
        #expect(sup.diagnostics().skipStatistics?.contains("devices=1") == true)
    }

    @Test("S2aj 从未跳过时统计为 nil；出现跳过后串稳定可读")
    func skipStatisticsFormatIsStable() {
        let q = makeQueue()
        let resolver = standardSwapTopology()
        let audio = MockSwapAudio()
        let sup = makeSupervisor(resolver: resolver, audio: audio,
                                 scheduler: FakeScheduler(), queue: q,
                                 notified: ValueBox<String>(""))

        sup.apply(enabledSettings); sync(q) {}
        // 装配完成但还没有任何事件 → 无跳过
        #expect(sup.diagnostics().skipStatistics == nil,
                "没发生过跳过就该是 nil，而不是空串（UI 靠 nil 判断「无需提示」）")

        sup.devicesChanged(); sync(q) {}
        let first = sup.diagnostics().skipStatistics
        let second = sup.diagnostics().skipStatistics
        #expect(first == second, "同一状态两次读取必须完全一致（顺序固定）")
        #expect(first == "devices=1", "格式应为 <来源>=<次数>，实际：\(first ?? "nil")")
    }

    @Test("S2ad AudioDeviceID 变了（设备重建）必须重新装配")
    func reassemblesWhenDeviceIDChanges() {
        let q = makeQueue()
        let resolver = standardSwapTopology()
        let audio = MockSwapAudio()
        let sup = makeSupervisor(resolver: resolver, audio: audio,
                                 scheduler: FakeScheduler(), queue: q,
                                 notified: ValueBox<String>(""))

        sup.apply(enabledSettings); sync(q) {}
        #expect(audio.startCount == 1)

        // 唤醒实测：设备被销毁重建，AudioDeviceID 142 → 222（UID 不变）
        resolver.devices = resolver.devices.map { d in
            d.uid == "00000000-0000-0000-0000"
                ? makeSwapDevice(name: d.name, uid: d.uid, id: 222,
                                 outputChannels: d.outputChannels,
                                 inputChannels: d.inputChannels, rate: d.nominalSampleRate)
                : d
        }
        resolver.resolveByUID = Dictionary(uniqueKeysWithValues: resolver.devices.map { ($0.uid, $0) })
        resolver.defaultOutputUID = "00000000-0000-0000-0000"

        sup.devicesChanged(); sync(q) {}

        #expect(audio.startCount == 2, "设备重建后必须重新装配到新设备")
        #expect(audio.startCalls.last?.output == "00000000-0000-0000-0000")
        #expect(sup.state == .running)
    }

    @Test("S2ae 设备消失过就必须强制重建（即便解析结果恰好一模一样）")
    func devicesDisappearedForcesReassembly() {
        // 为什么需要这条：`AudioDeviceID` 是会被系统**复用**的。
        // 设备销毁再创建后可能拿回同一个 ID，此时"解析结果比对"会误判成
        // "设备没变"而跳过重建，通路就永远绑在旧单元上了 —— 静默失效。
        let q = makeQueue()
        let resolver = standardSwapTopology()
        let audio = MockSwapAudio()
        let sup = makeSupervisor(resolver: resolver, audio: audio,
                                 scheduler: FakeScheduler(), queue: q,
                                 notified: ValueBox<String>(""))

        sup.apply(enabledSettings); sync(q) {}
        #expect(audio.startCount == 1)

        // 拓扑完全没变（同一个 id / uid / 通道数 / 采样率），但设备确实消失过
        sup.devicesDisappeared(); sync(q) {}

        #expect(audio.startCount == 2,
                "消失过就必须重建：旧 AUHAL 单元绑的 AudioDeviceID 已失效")
        #expect(sup.state == .running)
    }

    @Test("S2af 设置变了（设备没变）必须重新装配 —— 否则「改了配置没反应」")
    func reassemblesWhenSettingsChange() {
        // 回归防线：短路判据只看"设备"是不够的。
        // 用户调混音增益 / 换源声道时设备一动不动，但通路**必须**按新设置重装
        // ——"外部改了配置但装配还是旧的"是本项目实际踩过的坑。
        let q = makeQueue()
        let resolver = standardSwapTopology()
        let audio = MockSwapAudio()
        let sup = makeSupervisor(resolver: resolver, audio: audio,
                                 scheduler: FakeScheduler(), queue: q,
                                 notified: ValueBox<String>(""))

        var settings = ChannelSwapSettings(isEnabled: true)   // 默认 第3 ↔ 第4
        sup.apply(settings); sync(q) {}
        #expect(audio.startCount == 1)
        #expect(sup.appliedChannelMap == [0, 1, 3, 2, 4, 5, 6, 7])

        // 设备完全没变，只把交换声道改成 第1 ↔ 第2
        settings.firstChannel = 1
        settings.secondChannel = 2
        sup.apply(settings); sync(q) {}

        #expect(audio.startCount == 2, "设置变了必须重装，不能沿用旧装配")
        // 实际写进去的映射必须是新的（旧映射 = 改了配置没反应）
        #expect(sup.appliedChannelMap == [1, 0, 2, 3, 4, 5, 6, 7])
    }

    @Test("S2ag 关闭开关后设备事件不碰任何设备")
    func deviceEventsAreNoOpWhenDisabled() {
        let q = makeQueue()
        let audio = MockSwapAudio()
        let sup = makeSupervisor(resolver: standardSwapTopology(), audio: audio,
                                 scheduler: FakeScheduler(), queue: q,
                                 notified: ValueBox<String>(""))

        sup.apply(ChannelSwapSettings(isEnabled: false, mixEnabled: false)); sync(q) {}
        sup.devicesChanged(); sup.devicesDisappeared(); sync(q) {}

        #expect(audio.startCount == 0, "两个开关都关时通路不该启动")
        #expect(sup.state == .disabled)
    }

    // MARK: 设备缺失

    @Test("S2i 找不到 BlackHole 时等待（原因=inputDeviceMissing）")
    func waitsWhenInputMissing() {
        let q = makeQueue()
        let resolver = standardSwapTopology()
        resolver.devices = resolver.devices.filter { !$0.isBlackHole }
        resolver.resolveByUID = resolver.resolveByUID.filter { !$0.key.hasPrefix("BlackHole") }
        let audio = MockSwapAudio()
        let sup = makeSupervisor(resolver: resolver, audio: audio,
                                 scheduler: FakeScheduler(), queue: q, notified: ValueBox<String>(""))

        sup.apply(enabledSettings); sync(q) {}
        guard case .waiting(let reason, _, _) = sup.state else {
            Issue.record("应等待，实际 \(sup.state)"); return
        }
        #expect(reason == .inputDeviceMissing)
        #expect(audio.startCount == 0)
    }

    @Test("S2j 输出设备存在但声道数不足时，报「声道数不足」而非「找不到设备」")
    func waitsWithChannelReasonWhenDeviceTooSmall() {
        // 设计要点：候选设备**不做 ≥6ch 过滤**，否则设备掉到 2ch 时会被误报成
        // "找不到设备"，用户看不出到底怎么了。声道数门控由 supervisor 负责。
        let q = makeQueue()
        let resolver = standardSwapTopology(outputChannels: 2)
        let sup = makeSupervisor(resolver: resolver, audio: MockSwapAudio(),
                                 scheduler: FakeScheduler(), queue: q, notified: ValueBox<String>(""))

        sup.apply(enabledSettings); sync(q) {}
        guard case .waiting(let reason, _, _) = sup.state else {
            Issue.record("应等待，实际 \(sup.state)"); return
        }
        #expect(reason == .outputChannelsTooFew(current: 2, required: 6))
    }

    @Test("S2j2 完全没有非 BlackHole 输出设备时才报「找不到设备」")
    func waitsWhenNoOutputAtAll() {
        let q = makeQueue()
        let resolver = standardSwapTopology()
        resolver.devices = resolver.devices.filter { $0.isBlackHole }
        let sup = makeSupervisor(resolver: resolver, audio: MockSwapAudio(),
                                 scheduler: FakeScheduler(), queue: q, notified: ValueBox<String>(""))

        sup.apply(enabledSettings); sync(q) {}
        guard case .waiting(let reason, _, _) = sup.state else {
            Issue.record("应等待，实际 \(sup.state)"); return
        }
        #expect(reason == .outputDeviceMissing)
    }

    @Test("S2k 声道号配置越界属于配置错误 → 立即失败，而不是无限重试")
    func invalidChannelConfigFailsImmediately() {
        let q = makeQueue()
        let resolver = standardSwapTopology()            // 8ch
        let sched = FakeScheduler()
        let sup = makeSupervisor(resolver: resolver, audio: MockSwapAudio(),
                                 scheduler: sched, queue: q, notified: ValueBox<String>(""))
        // 第 99 声道根本不存在
        sup.apply(ChannelSwapSettings(isEnabled: true, firstChannel: 99, secondChannel: 4))
        sync(q) {}

        guard case .failed(let msg) = sup.state else {
            Issue.record("应失败，实际 \(sup.state)"); return
        }
        #expect(msg.contains("配置无效"))
        #expect(sched.requestedDelays.isEmpty, "配置错误不该进入重试")
    }

    // MARK: 采样率对齐：只写输入设备

    @Test("S2l 采样率不一致时对齐输入设备（且只写输入设备）")
    func alignsInputSampleRateOnly() {
        let q = makeQueue()
        let resolver = standardSwapTopology(blackHoleRate: 48000, outputRate: 96000)
        let sup = makeSupervisor(resolver: resolver, audio: MockSwapAudio(),
                                 scheduler: FakeScheduler(), queue: q, notified: ValueBox<String>(""))

        sup.apply(enabledSettings); sync(q) {}

        #expect(resolver.setSampleRateCalls.count == 1)
        #expect(resolver.setSampleRateCalls.first?.deviceUID == "BlackHole16ch_UID",
                "只允许写输入设备，绝不能碰输出设备（避免与格式锁定争夺）")
        #expect(resolver.setSampleRateCalls.first?.rate == 96000)
        #expect(sup.sampleRateAligned != nil)
    }

    @Test("S2m 采样率已一致时不写任何设备属性")
    func noSampleRateWriteWhenAlreadyAligned() {
        let q = makeQueue()
        let resolver = standardSwapTopology(blackHoleRate: 96000, outputRate: 96000)
        let sup = makeSupervisor(resolver: resolver, audio: MockSwapAudio(),
                                 scheduler: FakeScheduler(), queue: q, notified: ValueBox<String>(""))

        sup.apply(enabledSettings); sync(q) {}
        #expect(resolver.setSampleRateCalls.isEmpty)
    }

    @Test("S2n 关闭对齐开关后即使不一致也不写设备")
    func respectsAlignToggle() {
        let q = makeQueue()
        let resolver = standardSwapTopology(blackHoleRate: 48000, outputRate: 96000)
        let sup = makeSupervisor(resolver: resolver, audio: MockSwapAudio(),
                                 scheduler: FakeScheduler(), queue: q, notified: ValueBox<String>(""))

        var s = enabledSettings
        s.alignInputSampleRate = false
        sup.apply(s); sync(q) {}
        #expect(resolver.setSampleRateCalls.isEmpty)
    }

    // MARK: 指定 UID

    @Test("S2o 指定了输出设备 UID 时优先使用它（且仍校验声道数）")
    func respectsExplicitOutputUID() {
        let q = makeQueue()
        let resolver = standardSwapTopology()
        let another = makeSwapDevice(name: "Sculptor", uid: "sculptor-uid", id: 127,
                                     outputChannels: 2)
        resolver.devices.append(another)
        resolver.resolveByUID[another.uid] = another
        let audio = MockSwapAudio()
        let sup = makeSupervisor(resolver: resolver, audio: audio,
                                 scheduler: FakeScheduler(), queue: q, notified: ValueBox<String>(""))

        sup.apply(ChannelSwapSettings(isEnabled: true, outputDeviceUID: "sculptor-uid"))
        sync(q) {}

        // Sculptor 只有 2ch → 应等待而不是用它
        guard case .waiting(let reason, _, _) = sup.state else {
            Issue.record("应等待，实际 \(sup.state)"); return
        }
        #expect(reason == .outputChannelsTooFew(current: 2, required: 6))
        #expect(audio.startCount == 0)
    }

    @Test("S2p 目标设备不是系统默认输出时，走 HALOutput 绑设备路径")
    func usesHALOutputWhenNotDefault() {
        let q = makeQueue()
        let resolver = standardSwapTopology()
        // 默认输出改成别的设备（例如用户把 BlackHole 设成默认）
        resolver.defaultOutputUID = "BlackHole16ch_UID"
        let audio = MockSwapAudio()
        let sup = makeSupervisor(resolver: resolver, audio: audio,
                                 scheduler: FakeScheduler(), queue: q, notified: ValueBox<String>(""))

        sup.apply(enabledSettings); sync(q) {}
        #expect(sup.state == .running)
        #expect(audio.startCalls.first?.outputIsDefault == false,
                "默认输出不是目标设备时必须显式绑设备，否则会写错设备")
    }

    // MARK: 启动失败也走重试

    @Test("S2q 音频通路启动失败会重试，最终放弃")
    func startFailureRetriesThenGivesUp() {
        let q = makeQueue()
        let resolver = standardSwapTopology()
        let audio = MockSwapAudio()
        audio.startError = NSError(domain: "test", code: -1,
                                   userInfo: [NSLocalizedDescriptionKey: "模拟启动失败"])
        let sched = FakeScheduler()
        let box = ValueBox<String>("")
        let sup = makeSupervisor(resolver: resolver, audio: audio, scheduler: sched,
                                 queue: q, notified: box)

        sup.apply(enabledSettings); sync(q) {}
        for _ in 0..<5 { sched.fireAll(); q.sync {} }

        guard case .gaveUp = sup.state else {
            Issue.record("应 gaveUp，实际 \(sup.state)"); return
        }
        #expect(!box.value.isEmpty, "穷尽后应告警（ValueBox<String> 初始为空串，收到告警才非空）")
        #expect(audio.startCount >= 5, "每次重试都应真正尝试启动")
    }

    // MARK: 诊断

    @Test("S2r 诊断快照包含设备、映射与实时统计，且映射描述为 1-based")
    func diagnosticsSnapshot() {
        let q = makeQueue()
        let resolver = standardSwapTopology()
        let audio = MockSwapAudio()
        audio.statsValue = ChannelSwapAudioStats(inputCallbackCount: 100,
                                                 outputCallbackCount: 100,
                                                 framesIn: 51200, framesOut: 51200)
        let sup = makeSupervisor(resolver: resolver, audio: audio,
                                 scheduler: FakeScheduler(), queue: q, notified: ValueBox<String>(""))

        sup.apply(enabledSettings); sync(q) {}
        let d = sup.diagnostics()

        #expect(d.state == .running)
        #expect(d.inputDeviceName == "BlackHole 16ch")
        #expect(d.inputChannelCount == 16)
        #expect(d.outputDeviceName == "27C3A Pro")
        #expect(d.outputChannelCount == 8)
        #expect(d.appliedChannelMap == [0, 1, 3, 2, 4, 5, 6, 7])
        #expect(d.framesIn == 51200)
        // 1-based，且**输入在前**（用户确认的方向）
        #expect(d.channelMapDescription == "CH4-I → CH3-O、CH3-I → CH4-O")
    }

    @Test("S2s 恒等映射的诊断描述明确写着「不交换」（对应「不设就丢声道」那条约束）")
    func identityMapDescription() {
        let d = ChannelSwapDiagnostics(appliedChannelMap: [0, 1, 2, 3, 4, 5, 6, 7])
        #expect(d.channelMapDescription.contains("恒等映射"))
        #expect(d.channelMapDescription.contains("8 声道"))
    }

    @Test("S2t 未设置映射时诊断描述为「未设置」（便于发现「忘了设置」这个坑）")
    func noMapDescription() {
        #expect(ChannelSwapDiagnostics().channelMapDescription == "未设置")
    }

    // MARK: 功能感知文案（交换 / 混音共用通路，文案必须跟着走）

    @Test("S2w 状态文案随功能切换：开混音时不得显示成「交换中」")
    func statusTextFollowsActiveFunction() {
        #expect(ChannelSwapDiagnostics(state: .running,
                                       activeFunction: .swap).statusText == "交换中")
        // 回归点：先前无论跑哪个功能都写死"交换中"
        #expect(ChannelSwapDiagnostics(state: .running,
                                       activeFunction: .mix).statusText == "混音中")
    }

    @Test("S2x 非运行态的状态文案与功能无关（等待/未启用仍报各自原因）")
    func statusTextDelegatesForNonRunningStates() {
        let waiting = ChannelSwapDiagnostics(
            state: .waiting(reason: .inputDeviceMissing, attempt: 1, nextRetryInMs: 2000),
            activeFunction: .mix)
        #expect(waiting.statusText.contains("未找到 BlackHole"))

        #expect(ChannelSwapDiagnostics(state: .disabled,
                                       activeFunction: .mix).statusText == "未启用")
    }

    @Test("S2y 映射描述随功能切换：混音时必须给混音接线，不能回落成「恒等映射」")
    func mappingDescriptionFollowsActiveFunction() {
        // 交换 → ChannelMap 描述
        let swap = ChannelSwapDiagnostics(appliedChannelMap: [0, 1, 3, 2, 4, 5, 6, 7],
                                          activeFunction: .swap)
        #expect(swap.mappingDescription.contains("CH4-I → CH3-O"))

        // 混音 → 混音传递函数。此处 ChannelMap 恒等，绝不能拿它当答案。
        let mix = ChannelSwapDiagnostics(appliedChannelMap: [0, 1, 2, 3, 4, 5, 6, 7],
                                         activeFunction: .mix,
                                         mixDescription: "CH3-I → CH4-O ×0.316")
        #expect(mix.mappingDescription == "CH3-I → CH4-O ×0.316")
        #expect(!mix.mappingDescription.contains("恒等映射"),
                "混音不写 ChannelMap，回落会误导成「没生效」")
    }

    @Test("S2z 混音已开启但尚未装配时明确写「未装配」，不显示空串")
    func mappingDescriptionWhenMixNotAssembled() {
        #expect(ChannelSwapDiagnostics(state: .disabled,
                                       activeFunction: .mix).mappingDescription == "未装配")
    }

    @Test("S2aa 混音的映射文案是**传递函数首行**，与配置页共用同一份生成逻辑")
    func mixMappingUsesTransferFunction() {
        // 用户要求：状态栏应与配置页「当前传递函数」首行完全一致。
        // 先前状态栏显示的是装配摘要 "CH3-I → CH4-O ×0.316"，两处对不上。
        let line = LfeMixPlan.transferFunctionLine(inputChannel: 3, outputChannel: 4,
                                                   gain: LfeMixPlan.gain(fromDB: -10))
        #expect(line == "CH4-O = CH4-I + CH3-I × 0.316")

        let d = ChannelSwapDiagnostics(state: .running, activeFunction: .mix,
                                       mixDescription: line)
        #expect(d.mappingDescription == line)
        #expect(!d.mappingDescription.contains("→"), "不得回落到装配摘要的箭头写法")
    }

    @Test("S2ab 传递函数首行把「直通那条」算成配对里的另一条（两种输入都覆盖）")
    func transferFunctionDirectChannel() {
        let g = LfeMixPlan.gain(fromDB: -10)
        // 输入 3 → 直通 4
        #expect(LfeMixPlan.transferFunctionLine(inputChannel: 3, outputChannel: 4, gain: g)
                == "CH4-O = CH4-I + CH3-I × 0.316")
        // 输入 4 → 直通 3（镜像）
        #expect(LfeMixPlan.transferFunctionLine(inputChannel: 4, outputChannel: 4, gain: g)
                == "CH4-O = CH3-I + CH4-I × 0.316")
    }

    @Test("S2u 状态变化回调会收到 running（UI 依赖它刷新图标）")
    func stateChangeCallbackFires() {
        let q = makeQueue()
        let box = ValueBox<ChannelSwapState>(.disabled)
        let sup = makeSupervisor(resolver: standardSwapTopology(), audio: MockSwapAudio(),
                                 scheduler: FakeScheduler(), queue: q, notified: ValueBox<String>(""))
        sup.onStateChange = { state in box.value = state }

        sup.apply(enabledSettings); sync(q) {}
        #expect(box.value == .running)
    }

    @Test("S2v 等待状态下 onStateChange 收到 waiting（含重试次数与下次延迟）")
    func waitingStateCallback() {
        let q = makeQueue()
        let box = ValueBox<ChannelSwapState>(.disabled)
        let sup = makeSupervisor(resolver: standardSwapTopology(outputChannels: 2),
                                 audio: MockSwapAudio(),
                                 scheduler: FakeScheduler(), queue: q, notified: ValueBox<String>(""))
        sup.onStateChange = { state in box.value = state }

        sup.apply(enabledSettings); sync(q) {}
        guard case .waiting(_, let attempt, let next) = box.value else {
            Issue.record("应收到 waiting，实际 \(String(describing: box.value))"); return
        }
        #expect(attempt == 1 && next == 1000)
    }
}
