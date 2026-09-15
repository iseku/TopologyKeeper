import CoreAudio
import Foundation

/// 监听器句柄
public struct ListenerToken: Hashable, Sendable {
    public let id: UInt64
    public init(id: UInt64) { self.id = id }
}

/// CoreAudio 的唯一抽象边界。
///
/// 铁律：**任何 CoreAudio API 调用只能出现在本协议的实现里**。
/// 上层（RuleEngine / FormatApplier）只依赖协议，因此可以完全用 Mock 做单元测试。
///
/// 所有实现必须是 `Sendable`：约定**全部方法只在同一条串行队列上调用**
/// （`audioQueue`），由该队列保证线程安全。
public protocol CoreAudioServiceProtocol: AnyObject, Sendable {

    // MARK: 系统

    func systemDeviceList() -> [AudioDeviceID]
    func allOutputDevices() -> [DeviceDescriptor]
    func deviceDescriptor(forUID uid: String) -> DeviceDescriptor?
    /// 仅供观测，**永不写入**
    func defaultOutputDeviceID() -> AudioDeviceID?
    func defaultSystemOutputDeviceID() -> AudioDeviceID?

    // MARK: 设备与流

    func outputStreams(of device: AudioDeviceID) -> [AudioStreamID]
    func currentPhysicalFormat(of stream: AudioStreamID) -> AudioStreamBasicDescription?
    func currentVirtualFormat(of stream: AudioStreamID) -> AudioStreamBasicDescription?
    func nominalSampleRate(of device: AudioDeviceID) -> Double?
    func isRunningSomewhere(_ device: AudioDeviceID) -> Bool
    func isAlive(_ device: AudioDeviceID) -> Bool

    // MARK: 能力（★ 核心）

    /// 单流的能力清单
    func availableFormats(of stream: AudioStreamID) -> [AudioStreamRangedDescription]
    /// 设备级能力：多输出流时取交集
    func capability(of device: AudioDeviceID) -> DeviceCapability

    /// 设备当前物理格式（取第一个输出流）
    func currentPhysicalFormat(ofDevice device: AudioDeviceID) -> AudioStreamBasicDescription?

    // MARK: 写入

    func setPhysicalFormat(_ asbd: AudioStreamBasicDescription,
                           on stream: AudioStreamID) -> OSStatus
    func setNominalSampleRate(_ rate: Double, on device: AudioDeviceID) -> OSStatus

    // MARK: 监听

    /// 注册属性监听。`handler` 会在指定 `queue` 上被调用 ——
    /// **传入业务串行队列可让回调与其它工作天然有序**。
    @discardableResult
    func addListener(_ target: AudioObjectID,
                     _ address: AudioObjectPropertyAddress,
                     queue: DispatchQueue,
                     handler: @escaping @Sendable () -> Void) -> ListenerToken

    func removeListener(_ token: ListenerToken)
    func removeAllListeners()
}
