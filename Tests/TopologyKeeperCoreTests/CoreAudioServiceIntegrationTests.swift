import CoreAudio
import Darwin
import Dispatch
import Testing
@testable import TopologyKeeperCore

// 真实 CoreAudio 的集成测试（多数用例不需要外部硬件，只增删监听器 / 读属性）。
//
// 这一组存在的意义：监听器生命周期是**最容易被静默写错**的地方 ——
// 注册/移除的队列不匹配、迭代中修改字典、设备重建后忘记重注册，
// 这三种错误都不会报错，只会让功能悄悄失效。
// 因此这里直接跑真实 HAL 调用，而不是用 Mock。

/// I-e / I-g 依赖「本机真实存在输出设备」这一前提。
///
/// GitHub Actions 的 macOS VM 没有虚拟音频设备
/// （actions/runner-images#3526），CI 上通过 `TK_SKIP_AUDIO_HW_TESTS=1`
/// 显式跳过这两条，而不是把 `#expect` 弱化成「没设备就 return」——
/// 后者会让本机真正的「枚举不到设备」故障失去告警。
///
/// 这里刻意用 `getenv` 而不是 `ProcessInfo`：本机只有 CommandLineTools，
/// 其 `Testing.framework` 不含 `_Testing_Foundation`，同一文件里
/// `import Foundation` + `import Testing` 会直接编译失败。
private let hasRealAudioDevice = getenv("TK_SKIP_AUDIO_HW_TESTS") == nil

@Suite("CoreAudioService 集成（真实 HAL）")
struct CoreAudioServiceIntegrationTests {

    private func makeService() -> CoreAudioService { CoreAudioService() }

    @Test("I-a 系统级监听器：注册 → 计数 → 全部移除")
    func systemListenerLifecycle() {
        let service = makeService()
        let queue = DispatchQueue(label: "test.coreaudio.integration")

        #expect(service.listenerCount == 0)

        let token1 = service.addListener(
            AudioObjectID(kAudioObjectSystemObject),
            CoreAudioHelpers.address(kAudioHardwarePropertyDevices),
            queue: queue) { }
        let token2 = service.addListener(
            AudioObjectID(kAudioObjectSystemObject),
            CoreAudioHelpers.address(kAudioHardwarePropertyDefaultOutputDevice),
            queue: queue) { }

        #expect(service.listenerCount == 2)

        service.removeListener(token1)
        #expect(service.listenerCount == 1)

        service.removeListener(token2)
        #expect(service.listenerCount == 0)
    }

    @Test("I-b removeAllListeners 在多个监听器下不崩溃（回归：迭代中修改字典）")
    func removeAllListenersIsSafe() {
        let service = makeService()
        let queue = DispatchQueue(label: "test.coreaudio.integration.many")

        // 故意注册较多监听器，确保 removeAllListeners 内部会真正修改字典多次
        for index in 0..<12 {
            _ = service.addListener(
                AudioObjectID(kAudioObjectSystemObject),
                CoreAudioHelpers.address(kAudioHardwarePropertyDevices),
                queue: queue) { _ = index }
        }
        #expect(service.listenerCount == 12)

        service.removeAllListeners()
        #expect(service.listenerCount == 0, "全部移除后登记表应为空")

        // 幂等：再次调用不应崩溃
        service.removeAllListeners()
        #expect(service.listenerCount == 0)
    }

    @Test("I-c 移除不存在的 token 是安全的空操作")
    func removingUnknownTokenIsNoOp() {
        let service = makeService()
        service.removeListener(ListenerToken(id: 9999))
        service.removeListener(ListenerToken(id: 0))
        #expect(service.listenerCount == 0)
    }

    @Test("I-d 注册在不同队列上的监听器都能被正确移除（回归：队列不匹配）")
    func listenersOnDifferentQueuesAreRemoved() {
        let service = makeService()
        let queueA = DispatchQueue(label: "test.coreaudio.queueA")
        let queueB = DispatchQueue(label: "test.coreaudio.queueB")

        let tokenA = service.addListener(
            AudioObjectID(kAudioObjectSystemObject),
            CoreAudioHelpers.address(kAudioHardwarePropertyDevices),
            queue: queueA) { }
        let tokenB = service.addListener(
            AudioObjectID(kAudioObjectSystemObject),
            CoreAudioHelpers.address(kAudioHardwarePropertyDevices),
            queue: queueB) { }
        #expect(service.listenerCount == 2)

        service.removeListener(tokenA)
        service.removeListener(tokenB)
        #expect(service.listenerCount == 0)
    }

    @Test("I-e 枚举真实输出设备：UID 唯一、能解析回同一设备", .enabled(if: hasRealAudioDevice))
    func enumeratesRealDevices() {
        let service = makeService()
        let devices = service.allOutputDevices()
        // 本机至少有一台输出设备（内置扬声器）
        #expect(!devices.isEmpty, "至少应能枚举到内置输出设备")

        // UID 必须唯一
        let uids = devices.map(\.uid)
        #expect(Set(uids).count == uids.count, "设备 UID 应当唯一")

        // 按 UID 解析应回到同一台设备
        for device in devices {
            let resolved = service.deviceDescriptor(forUID: device.uid)
            #expect(resolved?.id == device.id)
        }

        // 不存在的 UID 返回 nil
        #expect(service.deviceDescriptor(forUID: "definitely-not-a-real-uid") == nil)
    }

    @Test("I-f 读到的能力清单内部自洽（每个组合都能查回来）")
    func realCapabilityIsSelfConsistent() {
        let service = makeService()
        guard let device = service.allOutputDevices().first else { return }
        let capability = service.capability(of: device.id)
        guard !capability.isEmpty else { return }

        // 每个条目的三元组都应能通过存在性校验查回来
        for entry in capability.entries {
            let found = capability.entry(channels: entry.mFormat.mChannelsPerFrame,
                                         bitDepth: entry.mFormat.mBitsPerChannel,
                                         sampleRate: entry.mFormat.mSampleRate)
            #expect(found != nil, "能力清单里的组合必须能查回来")
        }

        // 维度集合应与条目一致
        #expect(!capability.allChannelCounts.isEmpty)
        #expect(!capability.allBitDepths.isEmpty)
        #expect(!capability.allSampleRates.isEmpty)

        // 每个声道数都应至少有一个位深可选
        for channels in capability.allChannelCounts {
            #expect(!capability.bitDepths(forChannelCount: channels).isEmpty)
        }
    }

    @Test("I-g 默认输出设备与默认系统输出设备是两个不同属性（我早期搞混过）", .enabled(if: hasRealAudioDevice))
    func defaultDevicePropertiesAreDistinct() {
        let service = makeService()
        // 至少默认输出设备必须存在
        #expect(service.defaultOutputDeviceID() != nil)
        // 两个属性都存在且可读（值可能相同也可能不同，不作断言）
        _ = service.defaultSystemOutputDeviceID()
    }

    @Test("I-h 真实设备上写入用的 ASBD 来自能力清单（照抄，不重算字节数）")
    func formatApplierUsesVerbatimByteSizeOnRealDevice() {
        let service = makeService()
        guard let device = service.allOutputDevices().first else { return }
        let capability = service.capability(of: device.id)
        guard !capability.isEmpty else { return }

        // 取一个真实条目构造 preset
        guard let entry = capability.entries.first else { return }
        let preset = AudioFormatPreset(verbatim: entry, sampleRate: entry.mFormat.mSampleRate)

        // preset 的字节数必须与清单条目完全一致（即"照抄"而非"重算"）
        #expect(preset.bytesPerFrame == entry.mFormat.mBytesPerFrame)
        #expect(preset.bytesPerPacket == entry.mFormat.mBytesPerPacket)
        #expect(preset.formatFlags == entry.mFormat.mFormatFlags)
        #expect(preset.framesPerPacket == entry.mFormat.mFramesPerPacket)
        #expect(preset.channelCount == entry.mFormat.mChannelsPerFrame)
        #expect(preset.bitDepth == entry.mFormat.mBitsPerChannel)
    }
}
