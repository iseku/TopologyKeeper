import CoreAudio
import Foundation
@testable import TopologyKeeperCore

// MARK: - 构造辅助

/// 构造 ASBD。
///
/// `bytesPerChannel` 默认为 `bits/8`（紧凑打包），
/// 但真实设备常常用**更宽的容器** —— 实测 27C3A Pro 的 20bit/24bit
/// 都是 4 字节/声道（32bit 容器），只有 16bit 是紧凑的 2 字节。
/// 测试里必须能表达这种差异，否则测不出"照抄条目"这条纪律的价值。
func makeASBD(channels: UInt32,
              bits: UInt32,
              rate: Double,
              bytesPerChannel: UInt32? = nil,
              packed: Bool = true,
              isFloat: Bool = false) -> AudioStreamBasicDescription {
    let container = bytesPerChannel ?? (bits / 8)
    var flags: AudioFormatFlags = kAudioFormatFlagIsSignedInteger
    if isFloat { flags = kAudioFormatFlagIsFloat }
    if packed { flags |= kAudioFormatFlagIsPacked }

    let bytesPerFrame = container * channels
    return AudioStreamBasicDescription(
        mSampleRate: rate,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: flags,
        mBytesPerPacket: bytesPerFrame,
        mFramesPerPacket: 1,
        mBytesPerFrame: bytesPerFrame,
        mChannelsPerFrame: channels,
        mBitsPerChannel: bits,
        mReserved: 0)
}

/// 构造能力清单条目。
/// `mSampleRateRange` 刻意做成**单点** —— 实测全部 193 条条目都是这样，
/// 用它判断"支持的采样率区间"会得到错误结论。
func makeRanged(_ asbd: AudioStreamBasicDescription) -> AudioStreamRangedDescription {
    AudioStreamRangedDescription(
        mFormat: asbd,
        mSampleRateRange: AudioValueRange(mMinimum: asbd.mSampleRate,
                                          mMaximum: asbd.mSampleRate))
}

/// 复刻 27C3A Pro 的能力清单结构：21 种组合（2–8ch × 16/20/24bit），
/// 其中**只有 2ch/16bit 支持 768000**，其余只到 192000。
/// 这是级联过滤必须存在的实测依据。
func makeHDMICapability() -> DeviceCapability {
    var entries: [AudioStreamRangedDescription] = []
    let commonRates: [Double] = [32000, 44100, 48000, 88200, 96000, 176400, 192000]
    for channels in UInt32(2)...UInt32(8) {
        for bits in [UInt32(16), UInt32(20), UInt32(24)] {
            // 24bit/20bit 用 4 字节容器；16bit 紧凑 2 字节
            let container: UInt32 = (bits == 16) ? 2 : 4
            var rates = commonRates
            if channels == 2 && bits == 16 { rates.append(768000) }
            for rate in rates {
                entries.append(makeRanged(makeASBD(channels: channels, bits: bits,
                                                   rate: rate, bytesPerChannel: container)))
            }
        }
    }
    return DeviceCapability(entries: entries)
}

/// 复刻 BlackHole 型设备：**只有唯一一种组合**，声道与位深都没得选。
func makeSingleCombinationCapability() -> DeviceCapability {
    let rates: [Double] = [8000, 16000, 24000, 44100, 48000, 88200, 96000,
                           176400, 192000, 352800, 384000, 705600, 768000]
    let entries = rates.map {
        makeRanged(makeASBD(channels: 16, bits: 32, rate: $0, isFloat: true))
    }
    return DeviceCapability(entries: entries)
}

// MARK: - Mock

/// 可编程的 CoreAudio 模拟实现。
///
/// 存在的意义：`RuleEngine` / `FormatApplier` 的全部逻辑（能力门控、
/// 回读校验、模式 A/B 区分、退避、抑制）都**不依赖真实硬件**即可验证。
final class MockCoreAudioService: CoreAudioServiceProtocol, @unchecked Sendable {

    // MARK: 状态

    var devices: [DeviceDescriptor] = []
    var streamsByDevice: [AudioDeviceID: [AudioStreamID]] = [:]
    var availableFormatsByStream: [AudioStreamID: [AudioStreamRangedDescription]] = [:]
    var currentFormatByStream: [AudioStreamID: AudioStreamBasicDescription] = [:]
    var nominalRateByDevice: [AudioDeviceID: Double] = [:]
    var runningSomewhereDevices: Set<AudioDeviceID> = []
    var aliveDevices: Set<AudioDeviceID> = []
    var defaultOutputID: AudioDeviceID?
    var defaultSystemOutputID: AudioDeviceID?

    // MARK: 可编程的写入行为

    enum WriteBehavior {
        /// 正常：写入即生效，且标称采样率跟随
        case succeed
        /// 模式 A：返回 noErr，但**什么都不做**（模拟设备被其它工具独占）
        case ignore
        /// 模式 B：返回 noErr，但**落到另一个格式**
        case landOn(AudioStreamBasicDescription)
        /// 声道/位深生效，但采样率保持不变
        case dropSampleRate
        /// 返回真实错误码
        case fail(OSStatus)
        /// 多流场景：第一条流正常，其余流"写入被接受但不生效"
        case landOnChannelsAndBitsOnlyForSecondStream
    }

    var writeBehavior: WriteBehavior = .succeed

    /// 重试路径：补设标称采样率是否有效（默认有效）
    var obeyNominalRateSet: Bool = true

    // MARK: 调用记录

    struct SetFormatCall: Equatable {
        let stream: AudioStreamID
        let channels: UInt32
        let bits: UInt32
        let rate: Double
        let bytesPerFrame: UInt32
    }

    private(set) var setPhysicalFormatCalls: [SetFormatCall] = []
    private(set) var setNominalRateCalls: [(device: AudioDeviceID, rate: Double)] = []
    private(set) var registeredSelectors: [AudioObjectPropertySelector] = []
    private(set) var removedListenerCount = 0

    // MARK: 测试辅助

    func setDevice(_ uid: String,
                   id: AudioDeviceID,
                   name: String = "Test Device",
                   transport: UInt32 = kAudioDeviceTransportTypeHDMI,
                   channels: Int = 8) {
        devices = [DeviceDescriptor(id: id, uid: uid, name: name,
                                    transportType: transport, outputChannelCount: channels)]
    }

    /// 追加一台设备（**不覆盖**已有设备）
    func addDevice(_ uid: String,
                   id: AudioDeviceID,
                   name: String = "Other Device",
                   transport: UInt32 = kAudioDeviceTransportTypeUSB,
                   channels: Int = 2) {
        devices.append(DeviceDescriptor(id: id, uid: uid, name: name,
                                        transportType: transport,
                                        outputChannelCount: channels))
    }

    /// 便捷配置：单设备 + 单流（会**替换**全部设备）
    func configure(uid: String = "TEST-UID",
                   deviceID: AudioDeviceID = 100,
                   streamID: AudioStreamID = 200,
                   capability: DeviceCapability,
                   current: AudioStreamBasicDescription) {
        setDevice(uid, id: deviceID)
        streamsByDevice[deviceID] = [streamID]
        availableFormatsByStream[streamID] = capability.entries
        currentFormatByStream[streamID] = current
        nominalRateByDevice[deviceID] = current.mSampleRate
        aliveDevices.insert(deviceID)
    }

    // MARK: CoreAudioServiceProtocol

    func systemDeviceList() -> [AudioDeviceID] { devices.map(\.id) }
    func allOutputDevices() -> [DeviceDescriptor] { devices }

    func deviceDescriptor(forUID uid: String) -> DeviceDescriptor? {
        devices.first { $0.uid == uid }
    }

    func defaultOutputDeviceID() -> AudioDeviceID? { defaultOutputID }
    func defaultSystemOutputDeviceID() -> AudioDeviceID? { defaultSystemOutputID }

    func outputStreams(of device: AudioDeviceID) -> [AudioStreamID] {
        streamsByDevice[device] ?? []
    }

    func currentPhysicalFormat(of stream: AudioStreamID) -> AudioStreamBasicDescription? {
        currentFormatByStream[stream]
    }

    func currentVirtualFormat(of stream: AudioStreamID) -> AudioStreamBasicDescription? {
        currentFormatByStream[stream]
    }

    /// ★ 与生产实现 `CoreAudioService.currentPhysicalFormat(ofDevice:)` **同口径**。
    ///
    /// 多输出流设备必须"全部流一致"才算读到有效格式；否则返回 nil
    /// （表达"还没到位"）。做成镜像的原因：若这里仍只看第一条流，
    /// 测试就会比生产更宽松，从而**测不出**"半套格式被判为已锁定"这个缺陷
    /// （见 `CoreAudioService.formatsAreIdentical` 的说明）。
    func currentPhysicalFormat(ofDevice device: AudioDeviceID) -> AudioStreamBasicDescription? {
        let streams = outputStreams(of: device)
        guard let first = streams.first, let reference = currentFormatByStream[first] else {
            return nil
        }
        guard streams.count > 1 else { return reference }
        for stream in streams.dropFirst() {
            guard let other = currentFormatByStream[stream],
                  CoreAudioService.formatsAreIdentical(reference, other) else { return nil }
        }
        return reference
    }

    func nominalSampleRate(of device: AudioDeviceID) -> Double? {
        nominalRateByDevice[device]
    }

    func isRunningSomewhere(_ device: AudioDeviceID) -> Bool {
        runningSomewhereDevices.contains(device)
    }

    func isAlive(_ device: AudioDeviceID) -> Bool {
        aliveDevices.contains(device)
    }

    func availableFormats(of stream: AudioStreamID) -> [AudioStreamRangedDescription] {
        availableFormatsByStream[stream] ?? []
    }

    func capability(of device: AudioDeviceID) -> DeviceCapability {
        let perStream = outputStreams(of: device).map {
            DeviceCapability(entries: availableFormats(of: $0))
        }
        guard !perStream.isEmpty else { return .empty }
        return DeviceCapability.intersect(perStream)
    }

    func setPhysicalFormat(_ asbd: AudioStreamBasicDescription,
                           on stream: AudioStreamID) -> OSStatus {
        setPhysicalFormatCalls.append(SetFormatCall(
            stream: stream,
            channels: asbd.mChannelsPerFrame,
            bits: asbd.mBitsPerChannel,
            rate: asbd.mSampleRate,
            bytesPerFrame: asbd.mBytesPerFrame))

        switch writeBehavior {
        case .succeed:
            currentFormatByStream[stream] = asbd
            if let device = devices.first(where: { streamsByDevice[$0.id]?.contains(stream) == true }) {
                nominalRateByDevice[device.id] = asbd.mSampleRate
            }
            return noErr

        case .ignore:
            return noErr                       // 关键：noErr 但毫无效果

        case .landOn(let other):
            currentFormatByStream[stream] = other
            return noErr

        case .dropSampleRate:
            var landed = asbd
            if let previous = currentFormatByStream[stream] {
                landed.mSampleRate = previous.mSampleRate
            }
            currentFormatByStream[stream] = landed
            return noErr

        case .fail(let status):
            return status

        case .landOnChannelsAndBitsOnlyForSecondStream:
            // 第一条流正常生效；后续流保持原样（模拟半套格式）
            if setPhysicalFormatCalls.count == 1 {
                currentFormatByStream[stream] = asbd
            }
            return noErr
        }
    }

    func setNominalSampleRate(_ rate: Double, on device: AudioDeviceID) -> OSStatus {
        setNominalRateCalls.append((device, rate))
        guard obeyNominalRateSet else { return noErr }   // noErr 但无效
        nominalRateByDevice[device] = rate
        // 真实设备上标称采样率变化会带动流的物理格式
        for stream in outputStreams(of: device) {
            if var format = currentFormatByStream[stream] {
                format.mSampleRate = rate
                currentFormatByStream[stream] = format
            }
        }
        return noErr
    }

    @discardableResult
    func addListener(_ target: AudioObjectID,
                     _ address: AudioObjectPropertyAddress,
                     queue: DispatchQueue,
                     handler: @escaping @Sendable () -> Void) -> ListenerToken {
        registeredSelectors.append(address.mSelector)
        listenerHandlers[ListenerKey(object: target, selector: address.mSelector), default: []]
            .append(handler)
        return ListenerToken(id: UInt64(registeredSelectors.count))
    }

    func removeListener(_ token: ListenerToken) {
        removedListenerCount += 1
    }

    func removeAllListeners() {
        removedListenerCount += registeredSelectors.count
        registeredSelectors.removeAll()
        listenerHandlers.removeAll()
    }

    // MARK: 事件驱动（测试用）

    struct ListenerKey: Hashable {
        let object: AudioObjectID
        let selector: AudioObjectPropertySelector
    }

    /// 已注册的监听器回调，测试可主动触发它们来模拟真实事件
    var listenerHandlers: [ListenerKey: [@Sendable () -> Void]] = [:]

    /// 模拟 `kAudioHardwarePropertyDevices` 触发（设备列表变化）
    func fireDevicesChanged() {
        let key = ListenerKey(object: AudioObjectID(kAudioObjectSystemObject),
                              selector: kAudioHardwarePropertyDevices)
        for handler in listenerHandlers[key] ?? [] { handler() }
    }

    /// 模拟某个设备属性触发
    func fire(selector: AudioObjectPropertySelector, on object: AudioObjectID) {
        let key = ListenerKey(object: object, selector: selector)
        for handler in listenerHandlers[key] ?? [] { handler() }
    }

    /// 模拟音频服务重启
    func fireServiceRestarted() {
        fire(selector: kAudioHardwarePropertyServiceRestarted,
             on: AudioObjectID(kAudioObjectSystemObject))
    }

    // MARK: 设备重建（模拟唤醒时的 142 → 177 → 207 → 222）

    /// 模拟设备被销毁并重建：UID 不变，但 AudioDeviceID / AudioStreamID 全部改变。
    /// 旧监听器随之失效 —— 这正是必须 re-arm 的原因。
    func rebuildDevice(uid: String, newDeviceID: AudioDeviceID, newStreamID: AudioStreamID) {
        guard let index = devices.firstIndex(where: { $0.uid == uid }) else { return }
        guard let oldDeviceID = devices[safe: index]?.id else { return }

        let capability = capability(of: oldDeviceID)
        let previousFormat = currentFormatByStream[streamsByDevice[oldDeviceID]?.first ?? 0]

        devices[index] = DeviceDescriptor(id: newDeviceID,
                                          uid: uid,
                                          name: devices[index].name,
                                          transportType: devices[index].transportType,
                                          outputChannelCount: devices[index].outputChannelCount)
        streamsByDevice[oldDeviceID] = nil
        streamsByDevice[newDeviceID] = [newStreamID]
        availableFormatsByStream[newStreamID] = capability.entries
        if let previousFormat { currentFormatByStream[newStreamID] = previousFormat }
        aliveDevices.remove(oldDeviceID)
        aliveDevices.insert(newDeviceID)
    }

    /// 模拟设备彻底移除
    func removeDevice(uid: String) {
        guard let device = devices.first(where: { $0.uid == uid }) else { return }
        devices.removeAll { $0.uid == uid }
        streamsByDevice[device.id] = nil
        aliveDevices.remove(device.id)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
