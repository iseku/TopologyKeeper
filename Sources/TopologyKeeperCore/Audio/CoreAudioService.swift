import CoreAudio
import Foundation

/// `CoreAudioServiceProtocol` 的真实实现。
///
/// **线程约定**：所有方法只在调用方指定的串行队列（`audioQueue`）上调用。
/// CoreAudio 对同一对象的属性访问不是线程安全的，串行化是正确性要求而非优化（D12）。
/// 因此标记 `@unchecked Sendable`：安全性由调用方的队列纪律保证。
public final class CoreAudioService: CoreAudioServiceProtocol, @unchecked Sendable {

    private let systemObject = AudioObjectID(kAudioObjectSystemObject)

    /// 监听器登记表（仅在 audioQueue 上访问）
    private var listeners: [UInt64: ListenerRegistration] = [:]
    private var nextListenerID: UInt64 = 1

    private struct ListenerRegistration {
        let object: AudioObjectID
        let address: AudioObjectPropertyAddress
        /// ★ 必须记住注册时用的队列：CoreAudio 把队列作为监听器身份的一部分，
        /// 移除时传错队列会导致**静默失败并泄漏监听器**。
        let queue: DispatchQueue
        let block: AudioObjectPropertyListenerBlock
    }

    public init() {}

    // MARK: - 系统

    public func systemDeviceList() -> [AudioDeviceID] {
        CoreAudioHelpers.getArray(systemObject,
            CoreAudioHelpers.address(kAudioHardwarePropertyDevices),
            as: AudioDeviceID.self) ?? []
    }

    public func allOutputDevices() -> [DeviceDescriptor] {
        systemDeviceList().compactMap { device in
            // 只保留有输出流的设备
            guard !outputStreams(of: device).isEmpty else { return nil }
            return descriptor(of: device)
        }
    }

    private func descriptor(of device: AudioDeviceID) -> DeviceDescriptor? {
        guard let uid = CoreAudioHelpers.getScalar(device,
                CoreAudioHelpers.address(kAudioDevicePropertyDeviceUID), as: CFString.self)
        else { return nil }

        let name = CoreAudioHelpers.getScalar(device,
            CoreAudioHelpers.address(kAudioObjectPropertyName), as: CFString.self) as String?
            ?? "<未知设备>"

        let transport = CoreAudioHelpers.getScalar(device,
            CoreAudioHelpers.address(kAudioDevicePropertyTransportType), as: UInt32.self) ?? 0

        // 输出声道数取各输出流 virtual format 的声道数之和
        let channels = outputStreams(of: device).reduce(0) { total, stream in
            let ch = CoreAudioHelpers.getScalar(stream,
                CoreAudioHelpers.address(kAudioStreamPropertyVirtualFormat),
                as: AudioStreamBasicDescription.self)?.mChannelsPerFrame ?? 0
            return total + Int(ch)
        }

        return DeviceDescriptor(id: device,
                                uid: uid as String,
                                name: name,
                                transportType: transport,
                                outputChannelCount: channels)
    }

    public func deviceDescriptor(forUID uid: String) -> DeviceDescriptor? {
        for device in systemDeviceList() {
            guard let d = descriptor(of: device), d.uid == uid else { continue }
            return d
        }
        return nil
    }

    public func defaultOutputDeviceID() -> AudioDeviceID? {
        CoreAudioHelpers.getScalar(systemObject,
            CoreAudioHelpers.address(kAudioHardwarePropertyDefaultOutputDevice),
            as: AudioDeviceID.self)
    }

    public func defaultSystemOutputDeviceID() -> AudioDeviceID? {
        CoreAudioHelpers.getScalar(systemObject,
            CoreAudioHelpers.address(kAudioHardwarePropertyDefaultSystemOutputDevice),
            as: AudioDeviceID.self)
    }

    // MARK: - 设备与流

    public func outputStreams(of device: AudioDeviceID) -> [AudioStreamID] {
        CoreAudioHelpers.getArray(device,
            CoreAudioHelpers.address(kAudioDevicePropertyStreams,
                                     scope: kAudioObjectPropertyScopeOutput),
            as: AudioStreamID.self) ?? []
    }

    public func currentPhysicalFormat(of stream: AudioStreamID) -> AudioStreamBasicDescription? {
        CoreAudioHelpers.getScalar(stream,
            CoreAudioHelpers.address(kAudioStreamPropertyPhysicalFormat),
            as: AudioStreamBasicDescription.self)
    }

    public func currentVirtualFormat(of stream: AudioStreamID) -> AudioStreamBasicDescription? {
        CoreAudioHelpers.getScalar(stream,
            CoreAudioHelpers.address(kAudioStreamPropertyVirtualFormat),
            as: AudioStreamBasicDescription.self)
    }

    public func currentPhysicalFormat(ofDevice device: AudioDeviceID) -> AudioStreamBasicDescription? {
        outputStreams(of: device).first.flatMap { currentPhysicalFormat(of: $0) }
    }

    public func nominalSampleRate(of device: AudioDeviceID) -> Double? {
        CoreAudioHelpers.getScalar(device,
            CoreAudioHelpers.address(kAudioDevicePropertyNominalSampleRate), as: Float64.self)
    }

    public func isRunningSomewhere(_ device: AudioDeviceID) -> Bool {
        let value = CoreAudioHelpers.getScalar(device,
            CoreAudioHelpers.address(kAudioDevicePropertyDeviceIsRunningSomewhere),
            as: UInt32.self) ?? 0
        return value != 0
    }

    public func isAlive(_ device: AudioDeviceID) -> Bool {
        let value = CoreAudioHelpers.getScalar(device,
            CoreAudioHelpers.address(kAudioDevicePropertyDeviceIsAlive),
            as: UInt32.self) ?? 0
        return value != 0
    }

    // MARK: - 能力

    public func availableFormats(of stream: AudioStreamID) -> [AudioStreamRangedDescription] {
        CoreAudioHelpers.getArray(stream,
            CoreAudioHelpers.address(kAudioStreamPropertyAvailablePhysicalFormats),
            as: AudioStreamRangedDescription.self) ?? []
    }

    public func capability(of device: AudioDeviceID) -> DeviceCapability {
        let perStream = outputStreams(of: device).map {
            DeviceCapability(entries: availableFormats(of: $0))
        }
        guard !perStream.isEmpty else { return .empty }
        // 多流取交集（保守）；单流直接返回
        return DeviceCapability.intersect(perStream)
    }

    // MARK: - 写入

    public func setPhysicalFormat(_ asbd: AudioStreamBasicDescription,
                                  on stream: AudioStreamID) -> OSStatus {
        CoreAudioHelpers.setScalar(stream,
            CoreAudioHelpers.address(kAudioStreamPropertyPhysicalFormat), asbd)
    }

    public func setNominalSampleRate(_ rate: Double, on device: AudioDeviceID) -> OSStatus {
        CoreAudioHelpers.setScalar(device,
            CoreAudioHelpers.address(kAudioDevicePropertyNominalSampleRate), rate)
    }

    // MARK: - 监听

    @discardableResult
    public func addListener(_ target: AudioObjectID,
                            _ address: AudioObjectPropertyAddress,
                            queue: DispatchQueue,
                            handler: @escaping @Sendable () -> Void) -> ListenerToken {
        var address = address
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        let status = AudioObjectAddPropertyListenerBlock(target, &address, queue, block)

        let id = nextListenerID
        nextListenerID += 1
        if status == noErr {
            listeners[id] = ListenerRegistration(object: target,
                                                 address: address,
                                                 queue: queue,
                                                 block: block)
        } else {
            Log.warn("监听器注册失败 (\(CoreAudioHelpers.describe(status))): "
                     + selectorName(address.mSelector))
        }
        return ListenerToken(id: id)
    }

    public func removeListener(_ token: ListenerToken) {
        guard let registration = listeners.removeValue(forKey: token.id) else { return }
        var address = registration.address
        // ★ 用注册时的同一个队列（见 ListenerRegistration.queue 的说明）
        let status = AudioObjectRemovePropertyListenerBlock(
            registration.object, &address, registration.queue, registration.block)
        if status != noErr {
            // 对象已被销毁（设备拔出/重建）是正常情况，记 debug 即可；
            // 但如果是队列不匹配之类的问题，这条日志是唯一的线索。
            Log.debug("移除监听器返回 \(CoreAudioHelpers.describe(status))"
                      + "（对象可能已销毁）")
        }
    }

    public func removeAllListeners() {
        // ★ 先快照 key：removeListener 会修改字典，
        //   直接在 listeners.keys 上遍历属于"迭代中修改"，行为未定义。
        for token in Array(listeners.keys) {
            removeListener(ListenerToken(id: token))
        }
    }

    /// 当前登记的监听器数量（诊断与测试用）
    public var listenerCount: Int { listeners.count }

    private func selectorName(_ selector: AudioObjectPropertySelector) -> String {
        CoreAudioHelpers.fourCharCode(OSStatus(bitPattern: selector))
    }
}
