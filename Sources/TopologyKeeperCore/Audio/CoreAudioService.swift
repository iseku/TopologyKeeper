import CoreAudio
import Foundation

/// `CoreAudioServiceProtocol` 的真实实现。
///
/// **线程约定**：所有方法只在调用方指定的串行队列（`audioQueue`）上调用。
/// CoreAudio 对同一对象的属性访问不是线程安全的，串行化是正确性要求而非优化。
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

    /// 设备当前物理格式。
    ///
    /// ## ★ 多输出流设备：以"**全部流一致**"为准，而不是第一条流
    ///
    /// 这条口径必须与 `FormatApplier.apply` 完全对齐 —— 它**逐个写全部输出流**
    /// （多流设备只改一条会留下"半套格式"，比不改更糟）。
    /// 如果这里只看 `streams.first`，就会产生本项目最忌讳的**假锁定**：
    /// `stream[0]` 已达标 ⇒ `RuleEngine` 的幂等检查短路成 `.locked`
    /// ⇒ `stream[1..]` 永远不修，而日志与界面都显示"已锁定"。
    ///
    /// ⇒ 多流时任意一条流读不到、或与第一条**不完全相同**，就返回 `nil`
    ///    （表达"还没到位"）。调用方会走"未就绪"分支并**继续重试**，
    ///    这正是半套格式时想要的行为。
    ///
    /// 单流设备（绝大多数）行为完全不变，也不会多读一次属性。
    public func currentPhysicalFormat(ofDevice device: AudioDeviceID) -> AudioStreamBasicDescription? {
        let streams = outputStreams(of: device)
        guard let first = streams.first,
              let reference = currentPhysicalFormat(of: first) else { return nil }

        guard streams.count > 1 else { return reference }

        for stream in streams.dropFirst() {
            guard let other = currentPhysicalFormat(of: stream),
                  Self.formatsAreIdentical(reference, other) else { return nil }
        }
        return reference
    }

    /// 两个物理格式是否**逐字段完全相同**。
    ///
    /// 抽成静态方法有两个目的：① 让"多流一致性"的判据可以被单测直接钉住
    /// （不依赖任何 CoreAudio 对象）；② 与 `FormatApplier` 共用同一套字段清单，
    /// 避免两处各自列字段、日后加字段时漏改一处而重新出现"半套格式被判为达标"。
    ///
    /// ⚠️ 刻意**不用** `AudioFormatPreset.matchesCurrent`：那个是"是否达到用户
    ///    目标组合"（只看声道/位深/采样率），而这里要的是"各流是否彼此一致"。
    ///    两者口径不同，混用会让"两条流都错但错得一样"被判成未就绪或反之。
    public static func formatsAreIdentical(_ a: AudioStreamBasicDescription,
                                           _ b: AudioStreamBasicDescription) -> Bool {
        a.mSampleRate == b.mSampleRate
            && a.mFormatID == b.mFormatID
            && a.mFormatFlags == b.mFormatFlags
            && a.mChannelsPerFrame == b.mChannelsPerFrame
            && a.mBitsPerChannel == b.mBitsPerChannel
            && a.mBytesPerFrame == b.mBytesPerFrame
            && a.mBytesPerPacket == b.mBytesPerPacket
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
