import CoreAudio
import Testing
@testable import TopologyKeeperCore

// T6–T9：引擎行为

// MARK: - T6 设备重建后必须 re-arm

@Suite("T6 设备重建后重新注册监听器")
struct DeviceWatcherRearmTests {

    private func makeWatcher(_ service: MockCoreAudioService,
                             uid: String = "TEST-UID") -> DeviceWatcher {
        DeviceWatcher(service: service,
                      queue: DispatchQueue(label: "t6"),
                      debounceMs: 0,
                      executor: immediateExecutor,      // 同步执行，便于断言
                      watchedUIDs: { [uid] })
    }

    @Test("T6a 启动时注册设备与流的监听器")
    func armsOnStart() {
        let service = MockCoreAudioService()
        service.configure(capability: makeHDMICapability(),
                          current: makeASBD(channels: 2, bits: 24, rate: 192000, bytesPerChannel: 4))
        let watcher = makeWatcher(service)

        watcher.start()

        #expect(watcher.armedDeviceID(forUID: "TEST-UID") == 100)
        #expect(service.registeredSelectors.contains(kAudioDevicePropertyNominalSampleRate))
        #expect(service.registeredSelectors.contains(kAudioStreamPropertyPhysicalFormat))
        // 必须注册 devices-list —— 它是唯一的可靠触发源
        #expect(service.registeredSelectors.contains(kAudioHardwarePropertyDevices))
        // 不应注册能力清单监听器 —— 实测从不触发
        #expect(!service.registeredSelectors.contains(kAudioStreamPropertyAvailablePhysicalFormats))
    }

    @Test("T6b 设备重建（AudioDeviceID 变化）后必须重新注册监听器")
    func rearmsAfterRebuild() {
        let service = MockCoreAudioService()
        service.configure(capability: makeHDMICapability(),
                          current: makeASBD(channels: 2, bits: 24, rate: 192000, bytesPerChannel: 4))
        let watcher = makeWatcher(service)
        watcher.start()

        let listenersAfterStart = service.registeredSelectors.count
        let rearmCountAfterStart = watcher.rearmCount
        #expect(watcher.armedDeviceID(forUID: "TEST-UID") == 100)

        // 模拟唤醒时的设备重建：实测 AudioDeviceID 142 → 177 → 207 → 222
        service.rebuildDevice(uid: "TEST-UID", newDeviceID: 177, newStreamID: 178)

        // 走真实事件路径：devices-list 触发
        service.fireDevicesChanged()

        #expect(watcher.armedDeviceID(forUID: "TEST-UID") == 177,
                "设备重建后必须指向新的 AudioDeviceID")
        #expect(watcher.rearmCount > rearmCountAfterStart,
                "必须发生至少一次重新注册")
        #expect(service.registeredSelectors.count > listenersAfterStart,
                "必须为新设备/新流注册新的监听器")
        // 旧监听器应被显式移除，避免泄漏
        #expect(service.removedListenerCount > 0)
    }

    @Test("T6c 多次连续重建（唤醒实测出现 2~3 次）都能正确跟踪")
    func tracksRepeatedRebuilds() {
        let service = MockCoreAudioService()
        service.configure(capability: makeHDMICapability(),
                          current: makeASBD(channels: 2, bits: 24, rate: 192000, bytesPerChannel: 4))
        let watcher = makeWatcher(service)
        watcher.start()

        // 复刻实测序列：142 → 177 → 207 → 222
        for (deviceID, streamID) in [(UInt32(177), UInt32(178)),
                                     (UInt32(207), UInt32(208)),
                                     (UInt32(222), UInt32(223))] {
            service.rebuildDevice(uid: "TEST-UID", newDeviceID: deviceID, newStreamID: streamID)
            service.fireDevicesChanged()
            #expect(watcher.armedDeviceID(forUID: "TEST-UID") == deviceID)
        }
        #expect(watcher.armedDeviceID(forUID: "TEST-UID") == 222)
        #expect(watcher.armedDeviceCount == 1, "同一 UID 不应累积多条登记")
    }

    @Test("T6d 设备消失后再出现，仍能被重新跟踪")
    func handlesDisappearThenReappear() {
        let service = MockCoreAudioService()
        service.configure(capability: makeHDMICapability(),
                          current: makeASBD(channels: 2, bits: 24, rate: 192000, bytesPerChannel: 4))
        let watcher = makeWatcher(service)
        watcher.start()

        let events = Collector<WatchEvent>()
        watcher.onEvent = { event in events.append(event) }

        // 消失
        service.removeDevice(uid: "TEST-UID")
        service.fireDevicesChanged()
        #expect(watcher.armedDeviceID(forUID: "TEST-UID") == nil)
        #expect(events.contains { if case .deviceDisappeared = $0 { return true }; return false })

        // 重新出现（新 ID）
        service.setDevice("TEST-UID", id: 300, name: "Test Device",
                          transport: kAudioDeviceTransportTypeHDMI, channels: 8)
        service.streamsByDevice[300] = [301]
        service.availableFormatsByStream[301] = makeHDMICapability().entries
        service.currentFormatByStream[301] = makeASBD(channels: 2, bits: 24,
                                                      rate: 192000, bytesPerChannel: 4)
        service.fireDevicesChanged()

        #expect(watcher.armedDeviceID(forUID: "TEST-UID") == 300)
        #expect(events.contains { if case .deviceAppeared = $0 { return true }; return false })
    }

    @Test("T6e 未受监控的设备不会注册监听器")
    func ignoresUnwatchedDevices() {
        let service = MockCoreAudioService()
        service.configure(uid: "WATCHED", deviceID: 100, streamID: 200,
                          capability: makeHDMICapability(),
                          current: makeASBD(channels: 2, bits: 24, rate: 192000, bytesPerChannel: 4))
        // 另一台不在监控列表里的设备（注意用 addDevice，setDevice 会替换全部设备）
        service.addDevice("OTHER", id: 900, name: "Other")
        service.streamsByDevice[900] = [901]
        service.availableFormatsByStream[901] = []

        let watcher = makeWatcher(service, uid: "WATCHED")
        watcher.start()

        #expect(watcher.armedDeviceID(forUID: "WATCHED") == 100)
        #expect(watcher.armedDeviceID(forUID: "OTHER") == nil)
    }
}

// MARK: - T7 睡眠期间不动作

@Suite("T7 睡眠期间抑制动作")
struct SleepSuppressionTests {

    @Test("T7a 睡眠中触发事件不会写入设备")
    func noWritesWhileSleeping() {
        let harness = EngineHarness()
        harness.setupStandardDevice()
        harness.start()

        // 先进入睡眠
        harness.onQueue { harness.sleepWake.simulateSleep() }

        // start() 本身会合法地写入一次（能力就绪 + 当前是 2ch），
        // 因此这里取基线，断言"此后不再有新的写入"。
        let writesBefore = harness.writeAttempts
        let callsBefore = harness.service.setPhysicalFormatCalls.count

        // 睡眠期间各种事件都不应引发写入
        harness.emit(.devicesChanged(trigger: .deviceEvent))
        harness.emit(.nominalRateChanged(uid: "TEST-UID", deviceID: 100))
        harness.emit(.physicalFormatChanged(uid: "TEST-UID", streamID: 200))

        #expect(harness.writeAttempts == writesBefore, "睡眠期间不允许任何写入")
        #expect(harness.service.setPhysicalFormatCalls.count == callsBefore)

        let snapshot = harness.firstSnapshot
        #expect(snapshot?.state == .suspended(.sleeping))
    }

    @Test("T7b 唤醒后恢复动作并成功锁定")
    func resumesAfterWake() {
        let harness = EngineHarness()
        _ = harness.setupStandardDevice()          // 当前 2ch，目标 8ch
        harness.start()

        harness.onQueue { harness.sleepWake.simulateSleep() }
        #expect(harness.firstSnapshot?.state == .suspended(.sleeping))

        harness.onQueue { harness.sleepWake.simulateWake() }

        let snapshot = harness.firstSnapshot
        #expect(snapshot?.state == .locked)
        #expect(harness.service.setPhysicalFormatCalls.count == 1)
    }

    @Test("T7c 睡眠期间即使能力已就绪也不写入")
    func capabilityReadyButSleeping() {
        let harness = EngineHarness()
        harness.setupStandardDevice()
        harness.start()
        let callsBefore = harness.service.setPhysicalFormatCalls.count
        harness.onQueue { harness.sleepWake.simulateSleep() }

        // 睡眠中即使设备能力已就绪、且事件不断，也不应写入
        harness.emit(.devicesChanged(trigger: .deviceEvent))
        harness.emit(.nominalRateChanged(uid: "TEST-UID", deviceID: 100))
        #expect(harness.service.setPhysicalFormatCalls.count == callsBefore)
    }
}

// MARK: - T8 自身写入抑制窗口

@Suite("T8 自身写入抑制窗口")
struct SelfWriteSuppressionTests {

    @Test("T8a 写入成功后，自己引发的事件不会造成第二次写入")
    func suppressesSelfTriggeredEvents() {
        let clock = FakeClock()
        let harness = EngineHarness(clock: clock)
        harness.setupStandardDevice()
        harness.start()

        #expect(harness.service.setPhysicalFormatCalls.count == 1)
        let writesAfterFirst = harness.writeAttempts

        // 模拟我们的写入引发的回声事件（实测一次写入触发 6 次事件）
        harness.emit(.physicalFormatChanged(uid: "TEST-UID", streamID: 200))
        harness.emit(.physicalFormatChanged(uid: "TEST-UID", streamID: 200))
        harness.emit(.nominalRateChanged(uid: "TEST-UID", deviceID: 100))

        #expect(harness.writeAttempts == writesAfterFirst,
                "抑制窗口内不应产生额外写入")
        #expect(harness.service.setPhysicalFormatCalls.count == 1)
    }

    @Test("T8b 抑制窗口过期后，再次被改动会被修复")
    func resumesAfterSuppressionWindow() {
        let clock = FakeClock()
        let harness = EngineHarness(clock: clock)
        harness.setupStandardDevice()
        harness.start()
        #expect(harness.service.setPhysicalFormatCalls.count == 1)

        // 别的进程把格式改回 2ch
        harness.onQueue {
            harness.service.currentFormatByStream[200] =
                makeASBD(channels: 2, bits: 24, rate: 192000, bytesPerChannel: 4)
        }

        // 抑制窗口内：不写
        harness.emit(.nominalRateChanged(uid: "TEST-UID", deviceID: 100))
        #expect(harness.service.setPhysicalFormatCalls.count == 1)

        // 推进超过 selfWriteSuppressMs（默认 3000ms）
        clock.advance(ms: 3500)

        harness.emit(.nominalRateChanged(uid: "TEST-UID", deviceID: 100))
        #expect(harness.service.setPhysicalFormatCalls.count == 2,
                "抑制窗口过期后应重新修复格式")
        #expect(harness.firstSnapshot?.state == .locked)
    }

    @Test("T8c 手动\"立即应用\"绕过抑制窗口")
    func manualBypassesSuppression() {
        let clock = FakeClock()
        let harness = EngineHarness(clock: clock)
        let rule = harness.setupStandardDevice()
        harness.start()

        // 仍是目标格式，手动触发也不该产生额外写入（幂等）
        harness.onQueue { harness.engine.applyNow(ruleID: rule.id) }
        #expect(harness.service.setPhysicalFormatCalls.count == 1)

        // 把格式改掉，手动触发应立即修复（不受抑制窗口限制）
        harness.onQueue {
            harness.service.currentFormatByStream[200] =
                makeASBD(channels: 2, bits: 24, rate: 192000, bytesPerChannel: 4)
        }
        harness.onQueue { harness.engine.applyNow(ruleID: rule.id) }
        #expect(harness.service.setPhysicalFormatCalls.count == 2)
    }
}

// MARK: - T9 冲突退避

@Suite("T9 连续失败后的冲突退避")
struct ConflictBackoffTests {

    @Test("T9a 连续失败达到阈值后进入退避，期间不再写入")
    func entersBackoffAfterRepeatedFailures() {
        let clock = FakeClock()
        var config = AppConfig()
        config.conflictBackoffThreshold = 3
        config.conflictBackoffMs = 10_000
        config.selfWriteSuppressMs = 0        // 排除抑制窗口干扰

        let harness = EngineHarness(config: config, clock: clock)
        harness.setupStandardDevice()
        // 模拟"设备被其它工具独占"：返回 noErr 但毫无效果（模式 A）
        harness.service.writeBehavior = .ignore
        harness.start()

        // 前 3 次触发都失败
        for _ in 0..<3 {
            harness.emit(.nominalRateChanged(uid: "TEST-UID", deviceID: 100))
        }
        #expect(harness.service.setPhysicalFormatCalls.count == 3)

        // 第 4 次：应已进入退避，不再尝试写入
        harness.emit(.nominalRateChanged(uid: "TEST-UID", deviceID: 100))
        #expect(harness.service.setPhysicalFormatCalls.count == 3,
                "退避期间不应继续写入")

        let snapshot = harness.firstSnapshot
        if case .suspended(.conflictBackoff) = snapshot?.state {
            // 符合预期
        } else {
            Issue.record("期望 suspended(.conflictBackoff)，实际 \(String(describing: snapshot?.state))")
        }

        // 失败快照应携带可诊断信息
        #expect(snapshot?.state.displayText.contains("退避") == true)
    }

    @Test("T9b 退避到期后重新尝试")
    func retriesAfterBackoffExpires() {
        let clock = FakeClock()
        var config = AppConfig()
        config.conflictBackoffThreshold = 2
        config.conflictBackoffMs = 5_000
        config.selfWriteSuppressMs = 0

        let harness = EngineHarness(config: config, clock: clock)
        harness.setupStandardDevice()
        harness.service.writeBehavior = .ignore
        harness.start()

        harness.emit(.nominalRateChanged(uid: "TEST-UID", deviceID: 100))
        harness.emit(.nominalRateChanged(uid: "TEST-UID", deviceID: 100))
        let writesAtBackoff = harness.service.setPhysicalFormatCalls.count

        harness.emit(.nominalRateChanged(uid: "TEST-UID", deviceID: 100))
        #expect(harness.service.setPhysicalFormatCalls.count == writesAtBackoff)

        // 时间推进超过退避时长
        clock.advance(ms: 6000)

        // 让设备恢复正常写入
        harness.service.writeBehavior = .succeed
        harness.emit(.nominalRateChanged(uid: "TEST-UID", deviceID: 100))

        #expect(harness.service.setPhysicalFormatCalls.count > writesAtBackoff,
                "退避到期后应重新尝试")
        #expect(harness.firstSnapshot?.state == .locked)
    }

    @Test("T9c 能力未就绪不计入失败，不触发退避")
    func capabilityNotReadyDoesNotCountAsFailure() {
        let clock = FakeClock()
        var config = AppConfig()
        config.conflictBackoffThreshold = 2
        config.selfWriteSuppressMs = 0

        let harness = EngineHarness(config: config, clock: clock)
        harness.setupStandardDevice()
        // 在 start() 之前降级能力，模拟"唤醒早期设备只提供 2ch"的真实状态。
        //   这样 start() 自身也不会有任何写入，断言才是干净的。
        harness.degradeCapabilityTo2chOnly()
        harness.onQueue {
            harness.service.currentFormatByStream[200] =
                makeASBD(channels: 2, bits: 24, rate: 192000, bytesPerChannel: 4)
        }
        harness.start()

        // 触发很多次
        for _ in 0..<10 {
            harness.emit(.devicesChanged(trigger: .deviceEvent))
        }

        // 关键：能力未就绪不是失败，绝不能进入退避，
        // 否则设备能力真到位时就再也不会尝试了。
        let snapshot = harness.firstSnapshot
        if case .waitingForCapability(let maxCh) = snapshot?.state {
            #expect(maxCh == 2)
        } else {
            Issue.record("期望 waitingForCapability，实际 \(String(describing: snapshot?.state))")
        }
        #expect(harness.service.setPhysicalFormatCalls.isEmpty,
                "能力未就绪时一次写入都不该发生")

        // 现在恢复能力，应立即成功（未被退避挡住）
        harness.onQueue {
            harness.service.availableFormatsByStream[200] = makeHDMICapability().entries
        }
        harness.emit(.devicesChanged(trigger: .deviceEvent))
        #expect(harness.firstSnapshot?.state == .locked)
    }
}

// MARK: - T12 配置变更后必须重新注册监听器

@Suite("T12 配置变更后的监听器与立即生效")
struct ConfigChangeTests {

    @Test("T12a 新增规则后，watcher 必须重新注册（否则新设备的就地变更检测不到）")
    func addingRuleRearmsWatcher() {
        let harness = EngineHarness()
        harness.start()                                   // 无规则启动
        let rearmBefore = harness.watcher.rearmCount

        // 为当前已连接的设备新增一条规则
        harness.setupStandardDevice()
        harness.onQueue { harness.engine.configDidChange() }

        #expect(harness.watcher.rearmCount > rearmBefore,
                "配置变更后必须 rearm —— 受监控的设备集合变了（另一种情形）")
    }

    @Test("T12b 新增规则后应立刻把设备锁到目标格式（而不是等下一次设备事件）")
    func addingRuleTakesEffectImmediately() {
        let harness = EngineHarness()
        harness.start()
        #expect(harness.service.setPhysicalFormatCalls.isEmpty)

        harness.setupStandardDevice()                     // 设备当前 2ch，目标 8ch
        harness.onQueue { harness.engine.configDidChange() }

        #expect(harness.service.setPhysicalFormatCalls.count == 1,
                "新增规则后应立即生效，不能等到下次设备事件")
        #expect(harness.firstSnapshot?.state == .locked)
    }

    @Test("T12c 未启用规则的快照状态不应显示为「未连接」")
    func disabledRuleStateIsNotDeviceAbsent() {
        let harness = EngineHarness()
        let rule = harness.setupStandardDevice()
        harness.config.mutate { $0.rules[0].isEnabled = false }
        harness.start()
        harness.onQueue { harness.engine.refreshSnapshots() }

        let snapshot = harness.onQueue { harness.snapshots.first { $0.ruleID == rule.id } }
        // 设备是连接着的，只是规则被停用 —— 不能显示成"未连接"
        #expect(snapshot?.devicePresent == true)
        if case .deviceAbsent = snapshot?.state {
            Issue.record("停用规则被错误地显示为 deviceAbsent")
        }
    }
}

// MARK: - T13 抖动检测（"成功但被改回"的争夺）

@Suite("T13 格式抖动检测")
struct ThrashDetectionTests {

    @Test("T13a 反复成功写入达到阈值后进入退避")
    func repeatedSuccessEntersBackoff() {
        let clock = FakeClock()
        var config = AppConfig()
        config.selfWriteSuppressMs = 0
        config.thrashWindowMs = 30_000
        config.thrashThreshold = 4
        config.conflictBackoffMs = 20_000

        let harness = EngineHarness(config: config, clock: clock)
        harness.setupStandardDevice()
        harness.service.writeBehavior = .succeed
        harness.start()

        // 每次都"成功"，但外部立刻改回 → 反复触发
        // 关键：这种场景下连续失败计数永远是 0，只能靠应用频率识别
        for _ in 0..<40 {
            harness.onQueue {
                harness.service.currentFormatByStream[200] =
                    makeASBD(channels: 2, bits: 24, rate: 192000, bytesPerChannel: 4)
            }
            harness.emit(.nominalRateChanged(uid: "TEST-UID", deviceID: 100))
            clock.advance(ms: 200)
            if case .suspended(.conflictBackoff) = harness.firstSnapshot?.state { break }
        }

        let snapshot = harness.firstSnapshot
        if case .suspended(.conflictBackoff) = snapshot?.state {
            // 符合预期
        } else {
            Issue.record("反复成功写入后应识别为抖动并进入退避，实际 \(String(describing: snapshot?.state))")
        }
    }

    @Test("T13b 抖动退避期间不再写入")
    func noWritesDuringThrashBackoff() {
        let clock = FakeClock()
        var config = AppConfig()
        config.selfWriteSuppressMs = 0
        config.thrashWindowMs = 30_000
        config.thrashThreshold = 3
        config.conflictBackoffMs = 30_000

        let harness = EngineHarness(config: config, clock: clock)
        harness.setupStandardDevice()
        harness.start()

        // 直到进入退避
        var guardCount = 0
        while guardCount < 60 {
            harness.onQueue {
                harness.service.currentFormatByStream[200] =
                    makeASBD(channels: 2, bits: 24, rate: 192000, bytesPerChannel: 4)
            }
            harness.emit(.nominalRateChanged(uid: "TEST-UID", deviceID: 100))
            clock.advance(ms: 200)
            guardCount += 1
            if case .suspended(.conflictBackoff) = harness.firstSnapshot?.state { break }
        }

        let writesAtBackoff = harness.service.setPhysicalFormatCalls.count
        // 退避期间再怎么触发都不应写入
        for _ in 0..<10 {
            harness.onQueue {
                harness.service.currentFormatByStream[200] =
                    makeASBD(channels: 2, bits: 24, rate: 192000, bytesPerChannel: 4)
            }
            harness.emit(.nominalRateChanged(uid: "TEST-UID", deviceID: 100))
            clock.advance(ms: 100)
        }
        #expect(harness.service.setPhysicalFormatCalls.count == writesAtBackoff,
                "抖动退避期间不应继续写入")
    }

    @Test("T13c 正常偶发改动不会误判为抖动")
    func normalDriftDoesNotThrash() {
        let clock = FakeClock()
        var config = AppConfig()
        config.selfWriteSuppressMs = 0
        config.thrashWindowMs = 60_000
        config.thrashThreshold = 8

        let harness = EngineHarness(config: config, clock: clock)
        harness.setupStandardDevice()
        harness.start()

        // 稀疏的、间隔较大的改动（例如用户偶尔手动切一下）
        for _ in 0..<3 {
            clock.advance(ms: 20_000)
            harness.onQueue {
                harness.service.currentFormatByStream[200] =
                    makeASBD(channels: 2, bits: 24, rate: 192000, bytesPerChannel: 4)
            }
            harness.emit(.nominalRateChanged(uid: "TEST-UID", deviceID: 100))
        }

        #expect(harness.firstSnapshot?.state == .locked,
                "正常稀疏改动不应被误判为抖动，实际 \(String(describing: harness.firstSnapshot?.state))")
    }
}

// MARK: - T14 复刻真实唤醒时间线（现场复现的可自动化替代）

@Suite("T14 真实唤醒时间线回归")
struct WakeTimelineTests {

    /// 复刻 2025-09 实测捕获的序列：
    ///
    /// ```
    /// t=0     睡眠 → 设备消失
    /// t=1.8s  设备出现 id=177，可用声道仅 [2]（26 个组合）
    /// t=19.5s 设备消失、再出现 id=207，仍是 [2]
    /// t=28.0s 设备消失、再出现 id=222，可用声道 [2…8]（155 个组合）
    ///         实际格式仍停在 2ch  →  此刻才应当写入
    /// ```
    ///
    /// 关键断言：**前两次重现时一次写入都不能发生**。
    /// 这正是"固定延迟 800ms"方案必然失败的地方。
    @Test("T14a 前两次设备重现（仅 2ch）不写入，第三次能力到位才写入一次")
    func reproducesRealWakeTimeline() {
        let harness = EngineHarness()
        harness.setupStandardDevice()
        // 覆盖成唤醒早期的真实状态：只有 2ch
        harness.degradeCapabilityTo2chOnly()
        harness.onQueue {
            harness.service.currentFormatByStream[200] =
                makeASBD(channels: 2, bits: 24, rate: 192000, bytesPerChannel: 4)
        }
        harness.start()

        // ── 唤醒早期：设备在，但 8ch 还不可用 ──
        #expect(harness.service.setPhysicalFormatCalls.isEmpty,
                "能力未就绪时一次写入都不该发生")
        if case .waitingForCapability(let maxCh) = harness.firstSnapshot?.state {
            #expect(maxCh == 2)
        } else {
            Issue.record("期望 waitingForCapability，实际 \(String(describing: harness.firstSnapshot?.state))")
        }

        // ── 第 1 次重现：id 177，仍只有 2ch（对应第 1 次黑屏）──
        harness.onQueue {
            harness.service.rebuildDevice(uid: "TEST-UID",
                                          newDeviceID: 177, newStreamID: 178)
        }
        harness.emit(.devicesChanged(trigger: .deviceEvent))
        #expect(harness.service.setPhysicalFormatCalls.isEmpty,
                "第 1 次重现时 8ch 不可用，绝不能写入")

        // ── 第 2 次重现：id 207，仍只有 2ch（对应第 2 次黑屏）──
        harness.onQueue {
            harness.service.rebuildDevice(uid: "TEST-UID",
                                          newDeviceID: 207, newStreamID: 208)
        }
        harness.emit(.devicesChanged(trigger: .deviceEvent))
        #expect(harness.service.setPhysicalFormatCalls.isEmpty,
                "第 2 次重现时 8ch 仍不可用，绝不能写入")

        // ── 第 3 次重现：id 222，能力终于到位 ──
        harness.onQueue {
            harness.service.rebuildDevice(uid: "TEST-UID",
                                          newDeviceID: 222, newStreamID: 223)
            harness.service.availableFormatsByStream[223] = makeHDMICapability().entries
        }
        harness.emit(.devicesChanged(trigger: .deviceEvent))

        #expect(harness.service.setPhysicalFormatCalls.count == 1,
                "能力到位后应当且仅当写入一次")
        #expect(harness.firstSnapshot?.state == .locked)
        // 写入的必须是 8ch/24bit/96000
        let call = harness.service.setPhysicalFormatCalls.first
        #expect(call?.channels == 8)
        #expect(call?.bits == 24)
        #expect(call?.rate == 96000)
        #expect(call?.bytesPerFrame == 32, "必须是能力清单里的 32 字节容器")
    }

    @Test("T14b 睡眠期间即使设备反复重现也不写入")
    func sleepSuppressesWholeTimeline() {
        let harness = EngineHarness()
        harness.setupStandardDevice()
        harness.degradeCapabilityTo2chOnly()
        harness.start()

        harness.onQueue { harness.sleepWake.simulateSleep() }
        let writesBefore = harness.writeAttempts

        // 睡眠期间设备反复消失/重现（实测睡眠期设备以 [2ch] 存在了 16 秒）
        for (deviceID, streamID) in [(UInt32(177), UInt32(178)), (UInt32(207), UInt32(208))] {
            harness.onQueue {
                harness.service.rebuildDevice(uid: "TEST-UID",
                                              newDeviceID: deviceID, newStreamID: streamID)
            }
            harness.emit(.devicesChanged(trigger: .deviceEvent))
        }

        #expect(harness.writeAttempts == writesBefore, "睡眠期间不允许任何写入")
    }
}

// MARK: - T18 唤醒后必须**再次通知声道处理**（本次修的 bug）

/// 回归背景（真机日志实锤）：
///
/// ```
/// 20:28:02  设备出现 id=347          ← 唤醒后的设备重建
/// 20:28:13  27C3A Pro 已锁定为 8ch/24bit/96000
/// （此后到用户手动点"重试"之前，再无一条"声道交换通路已启动"）
/// ```
///
/// 原因：声道处理跑在**另一条队列的另一个引擎**上，它的 AUHAL 单元把
/// `AudioDeviceID` 烧死在里面；设备被销毁重建后旧单元即失效，
/// 而 `DeviceWatcher` 的事件流只进 `RuleEngine` —— **没有任何人**
/// 通知声道处理重新装配，`swapEngine.devicesChanged()` 是一次都没被调用的死代码。
@Suite("T18 唤醒后通知声道处理（交换 / 混音）重新装配")
struct ChannelProcessingNotificationTests {

    /// 装上钩子并记录调用（含"设备是否被销毁"这个标志）。
    /// 必须在 `start()` 之前装（`start()` 自己会评估一轮）。
    private func installHook(_ harness: EngineHarness,
                             _ calls: Collector<Bool>) {
        harness.engine.onChannelProcessingNeeded = { disappeared in
            calls.append(disappeared)
        }
    }

    @Test("T18a 唤醒后设备重建（消失 → 以新 ID 出现）必须通知声道处理")
    func notifiesOnWakeRebuild() {
        let harness = EngineHarness()
        harness.setupStandardDevice()
        let calls = Collector<Bool>()
        installHook(harness, calls)
        harness.start()

        // 唤醒实测序列（真机日志 20:28）：
        //   ① 旧设备被销毁（旧 AUHAL 单元随之失效）→ 捕获到"设备消失"
        //   ② 设备以**新的 AudioDeviceID** 回来，且格式掉回 2ch
        // 这里按同一顺序驱动：先报消失，再在原设备记录上重建
        // （`rebuildDevice` 保留能力与格式，只换 AudioDeviceID —— 与真机一致）。
        harness.emit(.deviceDisappeared(uid: "TEST-UID"))
        #expect(calls.count >= 1, "设备消失就该让声道处理知道（旧单元已死）")
        #expect(calls.values.last == true,
                "消失必须带「强制重建」标志：AudioDeviceID 会被系统复用，只比对解析结果可能误判成「设备没变」而跳过重建")

        let afterDisappear = calls.count

        harness.onQueue {
            harness.service.rebuildDevice(uid: "TEST-UID", newDeviceID: 347, newStreamID: 348)
        }
        harness.emit(.deviceAppeared(uid: "TEST-UID", deviceID: 347))

        #expect(calls.count > afterDisappear,
                "设备重建（新 deviceID）后必须再通知一次，否则交换通路永远绑在旧设备上")
        #expect(harness.firstSnapshot?.devicePresent == true,
                "通知必须建立在设备已被重新解析的前提上")
        // 通知发生在**引擎评估之后**（先锁定格式、再轮到声道处理）：
        // 这一点由 T18e 从"等待能力 → 已锁定"的跃迁正面锁定
    }

    @Test("T18b 系统唤醒事件本身也要通知（设备不重建的唤醒）")
    func notifiesOnWakeEvent() {
        let harness = EngineHarness()
        harness.setupStandardDevice()
        let calls = Collector<Bool>()
        installHook(harness, calls)
        harness.start()

        let before = calls.count
        harness.onQueue { harness.sleepWake.simulateWake() }

        #expect(calls.count > before, "didWake / screensDidWake 到达时也要给声道处理一次机会")
    }

    @Test("T18c 音频服务重启（coreaudiod 崩溃）同样通知")
    func notifiesOnServiceRestart() {
        let harness = EngineHarness()
        harness.setupStandardDevice()
        let calls = Collector<Bool>()
        installHook(harness, calls)
        harness.start()

        let before = calls.count
        harness.emit(.systemRestarted)

        #expect(calls.count > before, "音频服务重启后所有音频单元都失效，必须重新装配")
    }

    @Test("T18d 睡眠期间**不**通知 —— 否则会耗尽回退序列并弹误导性告警")
    func doesNotNotifyWhileSleeping() {
        let harness = EngineHarness()
        harness.setupStandardDevice()
        let calls = Collector<Bool>()
        installHook(harness, calls)
        harness.start()

        harness.onQueue { harness.sleepWake.simulateSleep() }
        let duringSleepBaseline = calls.count

        // 睡眠期间设备反复消失/重现（实测睡眠期设备会消失）
        for (deviceID, streamID) in [(UInt32(177), UInt32(178)), (UInt32(207), UInt32(208))] {
            harness.onQueue {
                harness.service.rebuildDevice(uid: "TEST-UID",
                                              newDeviceID: deviceID, newStreamID: streamID)
            }
            harness.emit(.devicesChanged(trigger: .deviceEvent))
        }

        #expect(calls.count == duringSleepBaseline,
                "睡眠中设备消失/重建都不该惊动声道处理（唤醒后会自然收到事件）")
    }

    @Test("T18e 规则从「等待能力」变为「已锁定」时必须补一次通知")
    func notifiesWhenRuleBecomesLocked() {
        // 场景：唤醒早期设备只有 2ch → 声道处理的 ≥6 声道门控不通过，只能等待；
        // 等本引擎把格式锁回 8ch 后若不再喂信号，它要等完 1-2-4-8 秒回退序列，
        // 序列耗尽就停在 gaveUp —— 用户看到的就是"唤醒后交换没回来"。
        let harness = EngineHarness()
        harness.setupStandardDevice()
        harness.degradeCapabilityTo2chOnly()      // 唤醒早期的真实状态
        let calls = Collector<Bool>()
        installHook(harness, calls)
        harness.start()

        if case .waitingForCapability = harness.firstSnapshot?.state {} else {
            Issue.record("前置条件：应处于 waitingForCapability，实际 \(String(describing: harness.firstSnapshot?.state))")
        }

        let beforeLock = calls.count

        // 能力终于到位（实测唤醒后 19~28 秒才出现），此刻写入并锁定
        harness.onQueue {
            harness.service.availableFormatsByStream[200] = makeHDMICapability().entries
        }
        harness.emit(.devicesChanged(trigger: .deviceEvent))

        #expect(harness.service.setPhysicalFormatCalls.count == 1)
        #expect(harness.firstSnapshot?.state == .locked)
        #expect(calls.count > beforeLock,
                "锁定后必须通知声道处理：此时设备才真正有 8 声道可用")
    }

    @Test("T18f 已经锁定的规则在兜底轮询里不重复通知（避免每次轮询都打扰）")
    func doesNotSpamWhileAlreadyLocked() {
        let harness = EngineHarness()
        let rule = harness.setupStandardDevice()
        // 设备一开始就是目标格式 → 首次评估即 .locked
        harness.onQueue {
            harness.service.currentFormatByStream[200] =
                makeASBD(channels: 8, bits: 24, rate: 96000, bytesPerChannel: 4)
        }
        let calls = Collector<Bool>()
        installHook(harness, calls)
        harness.start()

        #expect(harness.snapshot(for: rule)?.state == .locked)
        let baseline = calls.count

        // 兜底轮询会反复评估；"本来就锁着"不该产生通知
        for _ in 0..<5 {
            harness.emit(.poll)
        }

        #expect(calls.count == baseline,
                "规则一直锁定时，轮询不应反复通知声道处理（那是纯粹的抖动）")
    }
}

// MARK: - T15 受监控集合收缩时的 rearm（回归：迭代中修改字典）

@Suite("T15 受监控集合收缩")
struct RearmShrinkTests {

    private func makeServiceWithSixDevices() -> MockCoreAudioService {
        let service = MockCoreAudioService()
        for index in 0..<6 {
            let deviceID = AudioDeviceID(500 + index)
            let streamID = AudioStreamID(600 + index)
            service.addDevice("UID-\(index)", id: deviceID, name: "Dev\(index)")
            service.streamsByDevice[deviceID] = [streamID]
            service.availableFormatsByStream[streamID] = makeHDMICapability().entries
            service.currentFormatByStream[streamID] =
                makeASBD(channels: 8, bits: 24, rate: 96000, bytesPerChannel: 4)
            service.aliveDevices.insert(deviceID)
        }
        return service
    }

    private func makeWatcher(_ service: MockCoreAudioService,
                             uids: ValueBox<[String]>) -> DeviceWatcher {
        DeviceWatcher(service: service,
                      queue: DispatchQueue(label: "t15"),
                      debounceMs: 0,
                      executor: immediateExecutor,
                      watchedUIDs: { uids.value })
    }

    /// 回归：`rearm()` 的循环体会 `armed[uid] = nil`，
    /// 直接在 `armed.keys` 上遍历属于"迭代中修改字典"，行为未定义。
    /// 这个路径在**每次删除规则、或设备批量消失**时都会走到。
    @Test("T15a 受监控集合从多个一次性收缩到空")
    func shrinkToEmpty() {
        let service = makeServiceWithSixDevices()
        let uids = ValueBox((0..<6).map { "UID-\($0)" })
        let watcher = makeWatcher(service, uids: uids)

        watcher.start()
        #expect(watcher.armedDeviceCount == 6)

        uids.value = []                       // 一次性全部移除
        watcher.rearm()

        #expect(watcher.armedDeviceCount == 0, "全部移除后登记表应为空")
        #expect(service.removedListenerCount > 0, "应当显式移除旧监听器，避免泄漏")
    }

    @Test("T15b 多次逐步收缩，剩余设备仍被正确跟踪")
    func shrinkInSteps() {
        let service = makeServiceWithSixDevices()
        let uids = ValueBox((0..<6).map { "UID-\($0)" })
        let watcher = makeWatcher(service, uids: uids)
        watcher.start()

        uids.value = ["UID-0", "UID-1", "UID-2", "UID-3"]
        watcher.rearm()
        #expect(watcher.armedDeviceCount == 4)
        #expect(watcher.armedDeviceID(forUID: "UID-0") == 500)

        uids.value = ["UID-2"]
        watcher.rearm()
        #expect(watcher.armedDeviceCount == 1)
        #expect(watcher.armedDeviceID(forUID: "UID-2") == 502)
        #expect(watcher.armedDeviceID(forUID: "UID-0") == nil)

        uids.value = []
        watcher.rearm()
        #expect(watcher.armedDeviceCount == 0)
    }

    @Test("T15c 收缩后再扩张也能正确重新注册")
    func shrinkThenGrow() {
        let service = makeServiceWithSixDevices()
        let uids = ValueBox(["UID-0"])
        let watcher = makeWatcher(service, uids: uids)
        watcher.start()
        #expect(watcher.armedDeviceCount == 1)

        uids.value = []
        watcher.rearm()
        #expect(watcher.armedDeviceCount == 0)

        uids.value = ["UID-0", "UID-5"]
        watcher.rearm()
        #expect(watcher.armedDeviceCount == 2)
        #expect(watcher.armedDeviceID(forUID: "UID-5") == 505)
    }
}

// MARK: - T16 多输出流设备

@Suite("T16 多输出流设备")
struct MultiStreamTests {

    /// 构造一台有两条输出流的设备
    private func makeTwoStreamDevice(secondStreamSupports8ch: Bool)
        -> (MockCoreAudioService, AudioStreamID, AudioStreamID) {
        let service = MockCoreAudioService()
        let deviceID = AudioDeviceID(700)
        let streamA = AudioStreamID(701)
        let streamB = AudioStreamID(702)

        service.setDevice("MULTI-UID", id: deviceID, name: "USB Interface",
                          transport: kAudioDeviceTransportTypeUSB, channels: 8)
        service.streamsByDevice[deviceID] = [streamA, streamB]

        let full = makeHDMICapability()
        service.availableFormatsByStream[streamA] = full.entries
        service.availableFormatsByStream[streamB] = secondStreamSupports8ch
            ? full.entries
            : full.entries.filter { $0.mFormat.mChannelsPerFrame == 2 }   // 只支持 2ch

        let current = makeASBD(channels: 2, bits: 24, rate: 192000, bytesPerChannel: 4)
        service.currentFormatByStream[streamA] = current
        service.currentFormatByStream[streamB] = current
        service.nominalRateByDevice[deviceID] = 192000
        return (service, streamA, streamB)
    }

    private var target: AudioFormatPreset {
        let capability = makeHDMICapability()
        let entry = capability.entry(channels: 8, bitDepth: 24, sampleRate: 96000)!
        return AudioFormatPreset(verbatim: entry, sampleRate: 96000)
    }

    @Test("T16a 有一条流不支持目标组合时 → 整体判定为能力未就绪，零写入")
    func partialCapabilityYieldsNotReady() {
        let (service, _, _) = makeTwoStreamDevice(secondStreamSupports8ch: false)
        let applier = FormatApplier(service: service)

        let outcome = applier.apply(target, to: 700)

        guard case .capabilityNotReady = outcome else {
            Issue.record("期望 capabilityNotReady，实际 \(outcome)")
            return
        }
        #expect(service.setPhysicalFormatCalls.isEmpty,
                "只要有一条流不支持，就一次写入都不能发生（否则会留下半套格式）")
    }

    @Test("T16b 两条流都支持时，必须两条都写入")
    func allStreamsWritten() {
        let (service, streamA, streamB) = makeTwoStreamDevice(secondStreamSupports8ch: true)
        let applier = FormatApplier(service: service)

        let outcome = applier.apply(target, to: 700)

        #expect(outcome.isSuccess)
        let writtenStreams = Set(service.setPhysicalFormatCalls.map(\.stream))
        #expect(writtenStreams == Set([streamA, streamB]),
                "两条输出流都必须写入")
    }

    @Test("T16c 只有一条流生效时不能误报成功")
    func partialApplicationIsNotSuccess() {
        let (service, _, _) = makeTwoStreamDevice(secondStreamSupports8ch: true)
        // 让第二条流的写入不生效（模拟半套格式）
        service.writeBehavior = .succeed
        let applier = FormatApplier(service: service)

        // 先正常写入
        let first = applier.apply(target, to: 700)
        #expect(first.isSuccess)

        // 再把第二条流改回 2ch，然后重新应用并观察
        service.currentFormatByStream[702] =
            makeASBD(channels: 2, bits: 24, rate: 192000, bytesPerChannel: 4)
        service.writeBehavior = .landOnChannelsAndBitsOnlyForSecondStream

        let second = applier.apply(target, to: 700)
        #expect(!second.isSuccess, "只要有一条流没到位，就不能算成功")
    }
}

// MARK: - T17 睡眠通知缺失时的自愈（实测踩到的严重缺陷）

@Suite("T17 睡眠标志自愈")
struct SleepWatchdogTests {

    /// 可手动触发的看门狗执行器
    private final class ManualExecutor: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: [@Sendable () -> Void] = []

        var executor: DelayedExecutor {
            { [weak self] _, work in
                guard let self else { return }
                self.lock.lock(); self.pending.append(work); self.lock.unlock()
            }
        }

        var hasPending: Bool {
            lock.lock(); defer { lock.unlock() }
            return !pending.isEmpty
        }

        func fireAll() {
            lock.lock()
            let work = pending
            pending.removeAll()
            lock.unlock()
            for item in work { item() }
        }
    }

    /// 实测缺陷：`pmset sleepnow` 被电源断言阻止，`willSleep` 已发出
    /// 但系统**从未真正睡眠**（`Total Sleep/Wakes: 0`），
    /// 于是 `didWake` 永不到来 —— 原来会把引擎永久卡死。
    @Test("T17a willSleep 后未收到 didWake 时，看门狗必须自愈")
    func watchdogRecoversFromAbortedSleep() {
        let manual = ManualExecutor()
        let observer = SleepWakeObserver(hopQueue: nil,
                                         watchdogExecutor: manual.executor,
                                         watchdogIntervalMs: 1)

        let wakeCallbacks = ValueBox(0)
        observer.onWake = { wakeCallbacks.value += 1 }

        observer.handleWillSleep()
        #expect(observer.isSleeping == true)
        #expect(manual.hasPending, "willSleep 后必须安排看门狗")

        // 系统其实没睡 —— 模拟看门狗到时触发
        manual.fireAll()

        #expect(observer.isSleeping == false, "看门狗触发后必须清除睡眠标志")
        #expect(observer.watchdogFireCount == 1)
        #expect(wakeCallbacks.value == 1, "自愈后应当触发一次唤醒回调，让引擎重新评估")
    }

    @Test("T17b didWake 正常到达时看门狗不再重复触发")
    func normalWakeCancelsWatchdog() {
        let manual = ManualExecutor()
        let observer = SleepWakeObserver(hopQueue: nil,
                                         watchdogExecutor: manual.executor,
                                         watchdogIntervalMs: 1)

        let wakeCallbacks = ValueBox(0)
        observer.onWake = { wakeCallbacks.value += 1 }

        observer.handleWillSleep()
        observer.handleDidWake()

        #expect(observer.isSleeping == false)
        #expect(wakeCallbacks.value == 1)

        // 迟到的看门狗不应再次触发回调
        manual.fireAll()
        #expect(wakeCallbacks.value == 1, "didWake 已处理，看门狗不应重复触发")
        #expect(observer.watchdogFireCount == 0)
    }

    @Test("T17c 重复的 didWake 不会重复触发回调")
    func duplicateWakeIsIdempotent() {
        let observer = SleepWakeObserver(hopQueue: nil)
        let wakeCallbacks = ValueBox(0)
        observer.onWake = { wakeCallbacks.value += 1 }

        observer.handleWillSleep()
        observer.handleDidWake()
        observer.handleDidWake()
        observer.handleDidWake()

        #expect(wakeCallbacks.value == 1, "重复的唤醒通知应当幂等")
    }

    @Test("T17d 没有 willSleep 时收到 didWake 不误触发回调")
    func wakeWithoutSleepIsIgnored() {
        let observer = SleepWakeObserver(hopQueue: nil)
        let wakeCallbacks = ValueBox(0)
        observer.onWake = { wakeCallbacks.value += 1 }

        observer.handleDidWake()
        #expect(wakeCallbacks.value == 0, "没睡过就不该报唤醒")
        #expect(observer.isSleeping == false)
    }

    @Test("T17e 引擎在自愈后必须能继续工作（端到端）")
    func engineResumesAfterWatchdogHeals() {
        let manual = ManualExecutor()
        let harness = EngineHarness()
        harness.setupStandardDevice()

        // 用真实 SleepWakeObserver 替换 mock，并注入手动看门狗
        let realObserver = SleepWakeObserver(hopQueue: harness.queue,
                                             watchdogExecutor: manual.executor,
                                             watchdogIntervalMs: 1)
        harness.engine.replaceSleepWakeForTesting(realObserver)
        harness.start()

        // 进入"睡眠"
        harness.onQueue { realObserver.handleWillSleep() }
        #expect(harness.firstSnapshot?.state == .suspended(.sleeping))

        // 睡眠被阻止，didWake 永不到来 —— 看门狗自愈
        manual.fireAll()
        harness.onQueue { harness.engine.refreshSnapshots() }

        let state = harness.firstSnapshot?.state
        #expect(state != .suspended(.sleeping),
                "自愈后不应再停在睡眠中，实际 \(String(describing: state))")
    }
}
