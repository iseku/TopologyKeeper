import CoreAudio
import Testing

@testable import TopologyKeeperCore

// 延迟相关设置的**装配层**测试：设置 → supervisor → 驱动 / 设备。
//
// ## 为什么必须有这一层（血债）
//
// `setTargetLatency` 曾经只有协议扩展的**空默认实现**，而 `ChannelSwapAudioDriver`
// 忘了覆盖 —— 纯逻辑测试（`LatencyTargetTests`：目标解析、钳制、编解码）**全绿**，
// 真机上「延迟目标滑块」却**从未生效**：supervisor 的调用被空实现吞掉，
// 驱动永远用默认 30ms ⇒ 用户无论怎么拖滑块、怎么换缓冲都没反应，
// 目标水位恒为 1440 帧（30ms @48kHz）。
//
// 教训：**纯函数正确 ≠ 设置真的传到了硬件层**。两者必须分别锁死，
// 而且"必须表态"的协议方法**不能给默认实现**（那正是本项目最怕的静默失效）。
//
// 这里同时锁住音频缓冲的两条纪律：真写到了设备、停止时真恢复了原值。
//
// 编号：Y（latency wiring）系列。

@Suite("Y 延迟设置接线")
struct LatencyWiringTests {

    private func makeQueue() -> DispatchQueue {
        DispatchQueue(label: "test.latency.\(UUID().uuidString)")
    }

    private func sync(_ q: DispatchQueue, _ body: @escaping @Sendable () -> Void) {
        q.sync(execute: body)
    }

    private func makeSupervisor(resolver: MockSwapResolver,
                                audio: MockSwapAudio,
                                queue: DispatchQueue) -> ChannelSwapSupervisor {
        ChannelSwapSupervisor(resolver: resolver,
                              audio: audio,
                              queue: queue,
                              executor: FakeScheduler().executor(),
                              notifier: { _ in })
    }

    /// 通路要跑（交换开启）+ 两个可调项
    private func runningSettings(targetLatencyMs: Double,
                                 bufferFrames: Int?) -> ChannelSwapSettings {
        var s = ChannelSwapSettings(isEnabled: true,
                                    targetLatencyMs: targetLatencyMs,
                                    preferredBufferFrames: bufferFrames)
        s.engineEnabled = true
        return s
    }

    private let blackHoleUID = "BlackHole16ch_UID"
    private let outputUID = "00000000-0000-0000-0000"

    @Test("Y1 延迟目标必须真的传到驱动（曾因协议空默认实现被整轮吞掉）")
    func targetLatencyReachesDriver() {
        let q = makeQueue()
        let audio = MockSwapAudio()
        let sup = makeSupervisor(resolver: standardSwapTopology(), audio: audio, queue: q)

        sup.apply(runningSettings(targetLatencyMs: 15, bufferFrames: nil))
        sync(q) {}

        #expect(audio.startCount == 1, "通路应已启动")
        #expect(audio.targetLatencyCalls.last == 15,
                "驱动必须收到 15ms，实际收到 \(String(describing: audio.targetLatencyCalls.last))")
    }

    @Test("Y2 音频缓冲设置必须真的写到设备上（输入与输出都要）")
    func bufferFramesReachDevices() {
        let q = makeQueue()
        let resolver = standardSwapTopology()
        let sup = makeSupervisor(resolver: resolver, audio: MockSwapAudio(), queue: q)

        sup.apply(runningSettings(targetLatencyMs: 10, bufferFrames: 256))
        sync(q) {}

        let uids = Set(resolver.setBufferFrameSizeCalls.map(\.deviceUID))
        #expect(uids.contains(blackHoleUID), "输入设备（BlackHole）的缓冲未被写入")
        #expect(uids.contains(outputUID), "输出设备的缓冲未被写入")
        #expect(resolver.setBufferFrameSizeCalls.allSatisfy { $0.frames == 256 },
                "写入的必须是所选档位 256 帧")
    }

    @Test("Y3 选择「跟随系统」时绝不碰设备属性")
    func followSystemNeverTouchesDevice() {
        let q = makeQueue()
        let resolver = standardSwapTopology()
        let sup = makeSupervisor(resolver: resolver, audio: MockSwapAudio(), queue: q)

        sup.apply(runningSettings(targetLatencyMs: 30, bufferFrames: nil))
        sync(q) {}

        #expect(resolver.setBufferFrameSizeCalls.isEmpty,
                "「跟随系统」时一个属性都不该写（它是全局设备属性）")
    }

    @Test("Y4 设备不支持所选档位时不写，并把原因说出来（不许静默忽略）")
    func unsupportedBufferIsReported() {
        let q = makeQueue()
        let resolver = standardSwapTopology()
        resolver.supportedBufferFrames = 512...4096          // 模拟"不支持 256"
        let sup = makeSupervisor(resolver: resolver, audio: MockSwapAudio(), queue: q)

        sup.apply(runningSettings(targetLatencyMs: 10, bufferFrames: 256))
        sync(q) {}

        #expect(resolver.setBufferFrameSizeCalls.isEmpty, "设备不支持的档位不得写入")
        let desc = sup.diagnostics().bufferDescription ?? ""
        #expect(desc.contains("不支持"), "必须说明未生效的原因，实际：\(desc)")
    }

    @Test("Y5 停止通路时必须恢复缓冲原值（它是全局设备属性）")
    func stopRestoresOriginalBuffer() {
        let q = makeQueue()
        let resolver = standardSwapTopology()
        let sup = makeSupervisor(resolver: resolver, audio: MockSwapAudio(), queue: q)

        sup.apply(runningSettings(targetLatencyMs: 10, bufferFrames: 256))
        sync(q) {}
        #expect(resolver.bufferFramesByUID[outputUID] == 256, "装配后输出设备应停在小缓冲上")
        #expect(resolver.bufferFramesByUID[blackHoleUID] == 256, "输入设备同样")

        sup.stop()
        sync(q) {}

        #expect(resolver.bufferFramesByUID.values.allSatisfy { $0 == 512 },
                "停止后两台设备都必须恢复 512 帧原值 —— 否则整机音频都留在小缓冲上")
        #expect(resolver.setBufferFrameSizeCalls.last?.frames == 512)
    }

    @Test("Y7 完整链路：滑块设的值真的决定目标水位（设多少就是多少，低于下限才被钳）")
    func sliderValueDrivesWatermark() {
        let driver = ChannelSwapAudioDriver()
        // 未设置 → 默认 30ms @48kHz = 1440 帧（这正是"滑块不生效"时真机上恒定的那个值）
        #expect(driver.resolveCurrentLatencyTarget(sampleRate: 48000, callbackFrames: 512).target == 1440,
                "未设置时应为默认 30ms")
        // 设 40ms → 1920 帧（在安全水位之上，如实兑现）
        driver.setTargetLatency(40)
        #expect(driver.resolveCurrentLatencyTarget(sampleRate: 48000, callbackFrames: 512).target == 1920,
                "设 40ms 就该是 1920 帧")
        // 设 15ms → 720 帧，但低于安全水位 2×512 = 1024 ⇒ 被钳到 1024（= 21.3ms）
        driver.setTargetLatency(15)
        #expect(driver.resolveCurrentLatencyTarget(sampleRate: 48000, callbackFrames: 512).target == 1024,
                "低于安全水位时钳到 2×回调")
        // ★ 把缓冲换成 256 帧后，同样的 15ms 请求就能真的压到 720 帧
        #expect(driver.resolveCurrentLatencyTarget(sampleRate: 48000, callbackFrames: 256).target == 720,
                "256 帧缓冲下安全水位 512 ⇒ 15ms(720 帧) 可以兑现（这就是换缓冲的意义）")
    }

    @Test("Y6 缓冲设置失败时不得静默：诊断里要留下失败原因")
    func failedBufferWriteIsVisible() {
        let q = makeQueue()
        let resolver = standardSwapTopology()
        resolver.bufferFrameSizeSetStatus = kAudioHardwareIllegalOperationError
        let sup = makeSupervisor(resolver: resolver, audio: MockSwapAudio(), queue: q)

        sup.apply(runningSettings(targetLatencyMs: 10, bufferFrames: 256))
        sync(q) {}

        let desc = sup.diagnostics().bufferDescription ?? ""
        #expect(desc.contains("失败"), "写失败必须出现在诊断里，实际：\(desc)")
    }
}
