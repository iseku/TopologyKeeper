import CoreAudio
import Testing
@testable import TopologyKeeperCore

// T19：停用锁定的即时生效
//
// 真机反馈的 bug：把所有锁定设置关掉后，菜单栏图标**不变**，
// 必须退出重启才显示为"未启用锁定"。

@Suite("T19 停用锁定的即时生效")
struct DisabledStateTests {

    @Test("T19a 规则从「已锁定」被停用后，快照不应仍显示已锁定")
    func disablingRuleClearsLockedState() {
        let harness = EngineHarness()
        harness.setupStandardDevice()
        harness.start()
        #expect(harness.firstSnapshot?.state == .locked)

        // 用户在设置里关掉这条规则
        harness.config.mutate { $0.rules[0].isEnabled = false }
        harness.onQueue { harness.engine.configDidChange() }

        let snapshot = harness.firstSnapshot
        #expect(snapshot?.isEnabled == false)
        #expect(snapshot?.state != .locked,
                "停用后不应还停留在已锁定（这正是用户看到的 bug）")
        #expect(snapshot?.state == .suspended(.userPaused))
    }

    @Test("T19b 停用全部规则后，聚合状态立即变为「未启用锁定」")
    func aggregateBecomesNoRule() {
        let harness = EngineHarness()
        harness.setupStandardDevice()
        harness.start()
        #expect(LockStateAggregator.aggregate(harness.onQueue { harness.snapshots }) == .locked)

        harness.config.mutate { $0.rules[0].isEnabled = false }
        harness.onQueue { harness.engine.configDidChange() }

        let snapshots = harness.onQueue { harness.snapshots }
        let aggregate = LockStateAggregator.aggregate(snapshots)
        #expect(aggregate == .noRule, "全部停用即「未启用锁定」，实际 \(aggregate)")
        #expect(aggregate.iconName == "waveform.slash", "图标应立即变为 waveform.slash")
        #expect(LockStateAggregator.allDisabled(snapshots))
    }

    @Test("T19c 重新启用后立即恢复锁定显示")
    func reEnablingRestoresLocked() {
        let harness = EngineHarness()
        harness.setupStandardDevice()
        harness.start()

        harness.config.mutate { $0.rules[0].isEnabled = false }
        harness.onQueue { harness.engine.configDidChange() }
        #expect(harness.firstSnapshot?.state == .suspended(.userPaused))

        harness.config.mutate { $0.rules[0].isEnabled = true }
        harness.onQueue { harness.engine.configDidChange() }
        #expect(harness.firstSnapshot?.state == .locked)
    }

    @Test("T19d 停用规则不应触发任何设备写入")
    func disabledRuleNeverWrites() {
        let harness = EngineHarness()
        harness.setupStandardDevice()
        harness.start()
        let writesAfterStart = harness.service.setPhysicalFormatCalls.count

        harness.config.mutate { $0.rules[0].isEnabled = false }
        // 把格式改掉，再反复触发 —— 停用规则不该动手
        harness.onQueue {
            harness.service.currentFormatByStream[200] =
                makeASBD(channels: 2, bits: 24, rate: 192000, bytesPerChannel: 4)
        }
        harness.onQueue { harness.engine.configDidChange() }
        harness.emit(.nominalRateChanged(uid: "TEST-UID", deviceID: 100))
        harness.emit(.devicesChanged(trigger: .deviceEvent))

        #expect(harness.service.setPhysicalFormatCalls.count == writesAfterStart,
                "停用的规则不得写入设备")
    }

    // MARK: 聚合器本身

    @Test("T19e 聚合器：空列表 / 全停用 / 部分启用")
    func aggregatorBehavior() {
        #expect(LockStateAggregator.aggregate([]) == .noRule)
        #expect(LockStateAggregator.aggregate([]).iconName == "waveform.slash")

        // 全停用 → noRule
        #expect(LockStateAggregator.aggregate([makeSnapshot(enabled: false, state: .locked)])
                == .noRule)

        // 一条启用且已锁定 → locked
        #expect(LockStateAggregator.aggregate([makeSnapshot(enabled: true, state: .locked)])
                == .locked)

        // 启用 + 停用混合：只看启用的那些
        let mixed = [makeSnapshot(enabled: false, state: .failed(.notEffective)),
                     makeSnapshot(enabled: true, state: .locked)]
        #expect(LockStateAggregator.aggregate(mixed) == .locked,
                "停用规则的状态不应影响聚合结果")

        // 取最需要注意的
        let two = [makeSnapshot(enabled: true, state: .locked),
                   makeSnapshot(enabled: true, state: .waitingForCapability(availableMaxChannels: 2))]
        #expect(LockStateAggregator.aggregate(two)
                == .waitingForCapability(availableMaxChannels: 2))
    }

    @Test("T19f 摘要文案：全停用时明确说明而不是「未连接」")
    func summaryTextIsExplicit() {
        #expect(LockStateAggregator.summary([]) == "未配置设备规则")
        let disabled = [makeSnapshot(enabled: false, state: .locked)]
        let text = LockStateAggregator.summary(disabled)
        #expect(text.contains("未启用"))
        #expect(!text.contains("未连接"))
    }

    // MARK: 「暂停」冲突策略（已从界面移除，枚举保留以兼容旧配置）

    @Test("T19g 「暂停」真正的作用只是「不写入」；其状态显示**并不等于**「未启用」")
    func pausedPolicyBlocksWritesOnly() {
        // ① 格式不匹配时（不调用 start()，设备仍是 2ch/24bit/192000）
        let harness = EngineHarness()
        harness.setupStandardDevice(policy: .paused)
        harness.onQueue { harness.engine.configDidChange() }

        #expect(harness.firstSnapshot?.state == .suspended(.userPaused),
                "需要写入时「暂停」报「已暂停」")
        #expect(harness.service.setPhysicalFormatCalls.isEmpty,
                "「暂停」不得写设备 —— 这才是它唯一真正的作用")

        // ② 格式已匹配时，「暂停」仍报「已锁定」：
        //    幂等检查（RuleEngine 步骤 4）排在冲突策略检查（步骤 5）**之前**，
        //    格式已对就直接 return，根本走不到 paused 分支。
        //    ⇒ 与「未启用」（T19a 恒为 suspended）**并不等价** ——
        //      这也正是它语义含糊、值得从界面移除的证据。
        let locked = EngineHarness()
        locked.setupStandardDevice()
        locked.start()                        // start 会把格式修正为 8ch/24bit/96000
        #expect(locked.firstSnapshot?.state == .locked)

        locked.config.mutate { $0.rules[0].conflictPolicy = .paused }
        locked.onQueue { locked.engine.configDidChange() }
        #expect(locked.firstSnapshot?.state == .locked,
                "格式已匹配时「暂停」显示为「已锁定」（幂等检查先于策略检查）")
    }

    @Test("T19h 界面可选策略不含「暂停」，但枚举值必须保留（否则旧配置解码失败）")
    func selectablePoliciesExcludePaused() {
        #expect(!ConflictPolicy.selectable.contains(.paused))
        #expect(ConflictPolicy.selectable == [.enforceAlways, .onConnectOnly])
        #expect(ConflictPolicy.allCases.contains(.paused),
                "删掉枚举值会让已存有 paused 的配置整份读不出来")
    }

    // MARK: 辅助

    private func makeSnapshot(enabled: Bool, state: LockState) -> RuleSnapshot {
        let capability = makeHDMICapability()
        let entry = capability.entry(channels: 8, bitDepth: 24, sampleRate: 96000)!
        return RuleSnapshot(
            ruleID: UUID(),
            deviceName: "Test",
            transportName: "HDMI",
            devicePresent: true,
            matchedViaFallback: false,
            state: state,
            conflictPolicy: .enforceAlways,
            isEnabled: enabled,
            preset: AudioFormatPreset(verbatim: entry, sampleRate: 96000),
            currentFormat: nil,
            capabilitySummary: capability.summary,
            capabilityMaxChannels: 8,
            capabilityCombinationCount: capability.combinationCount,
            lastAppliedAt: nil,
            lastError: nil,
            consecutiveFailures: 0)
    }
}
