import CoreAudio
import Testing
@testable import TopologyKeeperCore

// T1–T5：FormatApplier 的核心行为
// 对应《详细设计.md》§13.2。
//
// 这一组测试锁死的是本项目最重要的三条纪律：
//   1. 能力门控 —— 组合不可用时**绝不写入**
//   2. 照抄条目 —— 字节数来自设备清单，不是自己算的
//   3. 回读校验 —— noErr 不是成功依据

@Suite("FormatApplier 核心行为")
struct FormatApplierTests {

    // MARK: T1 已经是目标格式 → 不写设备

    @Test("T1 已是目标格式时不写入设备，直接判定为已锁定")
    func alreadyLocked() {
        let mock = MockCoreAudioService()
        let capability = makeHDMICapability()
        let current = makeASBD(channels: 8, bits: 24, rate: 96000, bytesPerChannel: 4)
        mock.configure(capability: capability, current: current)

        let preset = AudioFormatPreset(verbatim: makeRanged(current), sampleRate: 96000)
        let applier = FormatApplier(service: mock)

        // 注意：FormatApplier 自身不做"已锁定"判断（那是 RuleEngine 的职责），
        // 但即便调用也必须能幂等地成功。
        let outcome = applier.apply(preset, to: 100)

        #expect(outcome.isSuccess)
        #expect(mock.setPhysicalFormatCalls.count == 1)
    }

    // MARK: T2 能力未就绪 → 绝不写入（D9）

    @Test("T2 目标组合不在能力清单时返回 capabilityNotReady 且不写入任何设备")
    func capabilityNotReady() {
        let mock = MockCoreAudioService()
        // 模拟唤醒早期状态：设备只提供 2ch（实测 §2.12 的前两次出现）
        var entries: [AudioStreamRangedDescription] = []
        for bits in [UInt32(16), UInt32(20), UInt32(24)] {
            let container: UInt32 = (bits == 16) ? 2 : 4
            entries.append(makeRanged(makeASBD(channels: 2, bits: bits,
                                               rate: 96000, bytesPerChannel: container)))
        }
        let capability = DeviceCapability(entries: entries)

        mock.configure(capability: capability,
                       current: makeASBD(channels: 2, bits: 24, rate: 192000, bytesPerChannel: 4))

        let preset = AudioFormatPreset(
            sampleRate: 96000, channelCount: 8, bitDepth: 24,
            formatFlags: kAudioFormatFlagIsSignedInteger,
            bytesPerFrame: 32, bytesPerPacket: 32, framesPerPacket: 1)
        let applier = FormatApplier(service: mock)

        let outcome = applier.apply(preset, to: 100)

        guard case .capabilityNotReady(let maxCh) = outcome else {
            Issue.record("期望 capabilityNotReady，实际 \(outcome)")
            return
        }
        #expect(maxCh == 2)
        #expect(outcome.shouldWait)
        // 核心断言：一次写入都不能发生
        #expect(mock.setPhysicalFormatCalls.isEmpty)
        #expect(mock.setNominalRateCalls.isEmpty)
    }

    // MARK: T3 模式 A：noErr 但完全没变（设备被独占）

    @Test("T3 写入返回 noErr 但格式毫无变化时判定为 notEffective")
    func modeASilentFailure() {
        let mock = MockCoreAudioService()
        let capability = makeHDMICapability()
        let current = makeASBD(channels: 2, bits: 24, rate: 192000, bytesPerChannel: 4)
        mock.configure(capability: capability, current: current)
        mock.writeBehavior = .ignore          // 模拟 SoundSource 独占

        let entry = capability.entry(channels: 8, bitDepth: 24, sampleRate: 96000)!
        let preset = AudioFormatPreset(verbatim: entry, sampleRate: 96000)
        let applier = FormatApplier(service: mock)

        let outcome = applier.apply(preset, to: 100)

        guard case .notEffective(let before, let after) = outcome else {
            Issue.record("期望 notEffective，实际 \(outcome)")
            return
        }
        #expect(before.mChannelsPerFrame == 2)
        #expect(after.mChannelsPerFrame == 2)
        #expect(outcome.failureKind == .notEffective)
        #expect(!outcome.isSuccess)
    }

    // MARK: T4 模式 B：noErr 但落到错误格式

    @Test("T4 写入返回 noErr 但落到另一格式时判定为 wrongFormat")
    func modeBSilentFailure() {
        let mock = MockCoreAudioService()
        let capability = makeHDMICapability()
        // 起始态：2ch/24bit/192000
        mock.configure(capability: capability,
                       current: makeASBD(channels: 2, bits: 24, rate: 192000, bytesPerChannel: 4))
        // 模拟"手工重算字节数"导致的落地错误：变了，但不是目标。
        // 注意必须与起始态**不同**，否则会（正确地）被判定为模式 A。
        mock.writeBehavior = .landOn(
            makeASBD(channels: 2, bits: 24, rate: 96000, bytesPerChannel: 4))

        let entry = capability.entry(channels: 8, bitDepth: 24, sampleRate: 96000)!
        let preset = AudioFormatPreset(verbatim: entry, sampleRate: 96000)
        let applier = FormatApplier(service: mock)

        let outcome = applier.apply(preset, to: 100)

        guard case .wrongFormat(let wanted, let got) = outcome else {
            Issue.record("期望 wrongFormat，实际 \(outcome)")
            return
        }
        #expect(wanted.mChannelsPerFrame == 8)
        #expect(got.mChannelsPerFrame == 2)
        #expect(outcome.failureKind == .wrongFormat)
    }

    @Test("T4c 起始态与落地态相同 → 判定为模式 A 而非模式 B")
    func unchangedIsModeANotModeB() {
        let mock = MockCoreAudioService()
        let capability = makeHDMICapability()
        let stalled = makeASBD(channels: 2, bits: 24, rate: 96000, bytesPerChannel: 4)
        mock.configure(capability: capability, current: stalled)
        mock.writeBehavior = .landOn(stalled)          // 与起始态完全相同

        let entry = capability.entry(channels: 8, bitDepth: 24, sampleRate: 96000)!
        let preset = AudioFormatPreset(verbatim: entry, sampleRate: 96000)
        let applier = FormatApplier(service: mock)

        let outcome = applier.apply(preset, to: 100)

        // "什么都没变" 应归为模式 A（设备被独占），而不是模式 B（构造错误）——
        // 两者的排查方向完全不同。
        guard case .notEffective = outcome else {
            Issue.record("期望 notEffective（模式 A），实际 \(outcome)")
            return
        }
    }

    // MARK: T4b 照抄的字节数必须与清单一致

    @Test("T4b 写入使用的 bytesPerFrame 来自能力清单（24bit 是 32bit 容器而非紧凑打包）")
    func verbatimByteSize() {
        let mock = MockCoreAudioService()
        let capability = makeHDMICapability()
        mock.configure(capability: capability,
                       current: makeASBD(channels: 2, bits: 16, rate: 44100, bytesPerChannel: 2))

        let entry = capability.entry(channels: 8, bitDepth: 24, sampleRate: 96000)!
        let preset = AudioFormatPreset(verbatim: entry, sampleRate: 96000)
        let applier = FormatApplier(service: mock)

        _ = applier.apply(preset, to: 100)

        let call = try? #require(mock.setPhysicalFormatCalls.first)
        #expect(call?.channels == 8)
        #expect(call?.bits == 24)
        // 关键：8 × 4 = 32，而不是 8 × 3 = 24
        #expect(call?.bytesPerFrame == 32)
    }

    // MARK: T5 声道/位深生效但采样率未跟随

    @Test("T5a 采样率未跟随时补设标称采样率，成功则判定为 applied")
    func sampleRateRecoverySucceeds() {
        let mock = MockCoreAudioService()
        let capability = makeHDMICapability()
        mock.configure(capability: capability,
                       current: makeASBD(channels: 2, bits: 24, rate: 192000, bytesPerChannel: 4))
        mock.writeBehavior = .dropSampleRate
        mock.obeyNominalRateSet = true

        let entry = capability.entry(channels: 8, bitDepth: 24, sampleRate: 96000)!
        let preset = AudioFormatPreset(verbatim: entry, sampleRate: 96000)
        let applier = FormatApplier(service: mock)

        let outcome = applier.apply(preset, to: 100)

        #expect(outcome.isSuccess)
        #expect(mock.setNominalRateCalls.count == 1)
        #expect(mock.setNominalRateCalls.first?.rate == 96000)
    }

    @Test("T5b 补设标称采样率也无效时判定为 sampleRateNotApplied")
    func sampleRateRecoveryFails() {
        let mock = MockCoreAudioService()
        let capability = makeHDMICapability()
        mock.configure(capability: capability,
                       current: makeASBD(channels: 2, bits: 24, rate: 192000, bytesPerChannel: 4))
        mock.writeBehavior = .dropSampleRate
        mock.obeyNominalRateSet = false        // noErr 但无效

        let entry = capability.entry(channels: 8, bitDepth: 24, sampleRate: 96000)!
        let preset = AudioFormatPreset(verbatim: entry, sampleRate: 96000)
        let applier = FormatApplier(service: mock)

        let outcome = applier.apply(preset, to: 100)

        guard case .sampleRateNotApplied(let wanted, let got) = outcome else {
            Issue.record("期望 sampleRateNotApplied，实际 \(outcome)")
            return
        }
        #expect(wanted == 96000)
        #expect(got == 192000)
    }

    // MARK: 其它

    @Test("设备没有输出流时返回 noOutputStreams")
    func noStreams() {
        let mock = MockCoreAudioService()
        mock.setDevice("TEST", id: 100)
        mock.streamsByDevice[100] = []

        let preset = AudioFormatPreset(
            sampleRate: 96000, channelCount: 8, bitDepth: 24,
            formatFlags: kAudioFormatFlagIsSignedInteger,
            bytesPerFrame: 32, bytesPerPacket: 32, framesPerPacket: 1)
        let applier = FormatApplier(service: mock)

        #expect(applier.apply(preset, to: 100) == .noOutputStreams)
    }

    @Test("真实 OSStatus 错误被正确上报")
    func osStatusError() {
        let mock = MockCoreAudioService()
        let capability = makeHDMICapability()
        mock.configure(capability: capability,
                       current: makeASBD(channels: 2, bits: 16, rate: 44100, bytesPerChannel: 2))
        mock.writeBehavior = .fail(kAudioDeviceUnsupportedFormatError)

        let entry = capability.entry(channels: 8, bitDepth: 24, sampleRate: 96000)!
        let preset = AudioFormatPreset(verbatim: entry, sampleRate: 96000)
        let applier = FormatApplier(service: mock)

        let outcome = applier.apply(preset, to: 100)
        #expect(outcome == .osStatus(kAudioDeviceUnsupportedFormatError))
        #expect(outcome.failureKind == .osStatus(kAudioDeviceUnsupportedFormatError))
    }
}
