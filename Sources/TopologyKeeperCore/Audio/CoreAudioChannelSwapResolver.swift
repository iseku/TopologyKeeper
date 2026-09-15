import CoreAudio
import Foundation

/// `ChannelSwapDeviceResolving` 的真实实现 —— **声道交换里唯一读设备属性的地方**。
///
/// 说明：本类只做"枚举 + 读属性 + 写输入设备采样率"。
/// 它不驱动音频数据（那是 `ChannelSwapAudioDriver` 的事），
/// 也不碰输出设备的任何属性（避免与格式锁定功能争夺，见 `ChannelSwapSettings`）。
public final class CoreAudioChannelSwapResolver: ChannelSwapDeviceResolving, @unchecked Sendable {

    private let systemObject = AudioObjectID(kAudioObjectSystemObject)

    public init() {}

    // MARK: - 设备枚举

    public func device(uid: String?, namePrefix: String) -> ChannelSwapDeviceInfo? {
        if let uid, !uid.isEmpty {
            return allDevices().first { $0.uid == uid }
        }
        guard !namePrefix.isEmpty else { return nil }
        return allDevices()
            .filter { $0.name.hasPrefix(namePrefix) }
            // BlackHole 有多版本（2ch/16ch/64ch）时取声道最多的那个
            .max { $0.outputChannels < $1.outputChannels }
    }

    public func preferredOutputDevice(excludingNamePrefix: String) -> ChannelSwapDeviceInfo? {
        // ⚠️ 刻意**不**在这里过滤声道数：设备可能临时掉回 2ch，
        //    那种情况要报"声道数不足、等待重试"而不是"找不到设备"。
        //    门控由 ChannelSwapSupervisor 负责。
        allDevices()
            .filter { !$0.name.hasPrefix(excludingNamePrefix) }
            .max { $0.outputChannels < $1.outputChannels }
    }

    public func defaultOutputDevice() -> ChannelSwapDeviceInfo? {
        guard let id: AudioDeviceID = CoreAudioHelpers.getScalar(
            systemObject,
            CoreAudioHelpers.address(kAudioHardwarePropertyDefaultOutputDevice),
            as: AudioDeviceID.self) else { return nil }
        return info(of: id)
    }

    public func setNominalSampleRate(_ rate: Double, on device: ChannelSwapDeviceInfo) -> OSStatus {
        CoreAudioHelpers.setScalar(device.id,
            CoreAudioHelpers.address(kAudioDevicePropertyNominalSampleRate), rate)
    }

    /// 读设备声明的声道布局（低音/中置各在第几条声道）。
    ///
    /// 实测：本机 `27C3A Pro` 声明 **L R LFE C Ls Rs …**，
    /// 与本项目原先假定的 `MPEG_7_1_C`（L R **C LFE**）相反。
    /// 混音必须按设备说的来，否则会混进没有声音的通道。
    public func declaredChannelIndices(of device: ChannelSwapDeviceInfo) -> CoreAudioHelpers.ChannelIndices? {
        CoreAudioHelpers.channelIndices(of: device.id)
    }

    // MARK: - 内部

    /// 枚举所有"有输出流"的设备（BlackHole 也有输出流，故一并包含）
    private func allDevices() -> [ChannelSwapDeviceInfo] {
        let ids: [AudioDeviceID] = CoreAudioHelpers.getArray(
            systemObject,
            CoreAudioHelpers.address(kAudioHardwarePropertyDevices),
            as: AudioDeviceID.self) ?? []
        return ids.compactMap { info(of: $0) }
    }

    private func info(of id: AudioDeviceID) -> ChannelSwapDeviceInfo? {
        guard let uid = CoreAudioHelpers.getScalar(id,
                CoreAudioHelpers.address(kAudioDevicePropertyDeviceUID), as: CFString.self)
                as String? else { return nil }

        let name = (CoreAudioHelpers.getScalar(id,
            CoreAudioHelpers.address(kAudioObjectPropertyName), as: CFString.self) as String?)
            ?? "<未知设备>"

        let rate = CoreAudioHelpers.getScalar(id,
            CoreAudioHelpers.address(kAudioDevicePropertyNominalSampleRate),
            as: Float64.self) ?? 0

        // 输出声道数：各输出流 virtual format 的声道数之和
        let outStreams: [AudioStreamID] = CoreAudioHelpers.getArray(id,
            CoreAudioHelpers.address(kAudioDevicePropertyStreams,
                                     scope: kAudioObjectPropertyScopeOutput),
            as: AudioStreamID.self) ?? []
        let outChannels = outStreams.reduce(0) { total, stream in
            let ch = CoreAudioHelpers.getScalar(stream,
                CoreAudioHelpers.address(kAudioStreamPropertyVirtualFormat),
                as: AudioStreamBasicDescription.self)?.mChannelsPerFrame ?? 0
            return total + Int(ch)
        }

        // 输入声道数（BlackHole 是 16 进 16 出；读取它时需要知道能读几路）
        let inStreams: [AudioStreamID] = CoreAudioHelpers.getArray(id,
            CoreAudioHelpers.address(kAudioDevicePropertyStreams,
                                     scope: kAudioObjectPropertyScopeInput),
            as: AudioStreamID.self) ?? []
        let inChannels = inStreams.reduce(0) { total, stream in
            let ch = CoreAudioHelpers.getScalar(stream,
                CoreAudioHelpers.address(kAudioStreamPropertyVirtualFormat),
                as: AudioStreamBasicDescription.self)?.mChannelsPerFrame ?? 0
            return total + Int(ch)
        }

        // 没输入流也没输出流的设备（如纯 MIDI）跳过
        guard outChannels > 0 || inChannels > 0 else { return nil }

        return ChannelSwapDeviceInfo(id: id,
                                     uid: uid,
                                     name: name,
                                     outputChannels: outChannels,
                                     inputChannels: inChannels,
                                     nominalSampleRate: rate,
                                     isBlackHole: name.hasPrefix("BlackHole"))
    }
}
