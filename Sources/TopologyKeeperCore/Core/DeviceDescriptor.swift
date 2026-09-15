import CoreAudio
import Foundation

/// 音频设备描述。
///
/// ⚠️ 关键区别（实测）：
/// * `id`（`AudioDeviceID`）是**会话级**的，设备每次消失/重现都会变
///   —— 实测唤醒过程中经历了 `142 → 177 → 207 → 222`。
/// * `uid` 才是稳定标识，**必须用 UID 匹配设备**。
public struct DeviceDescriptor: Equatable, Hashable, Sendable {
    public let id: AudioDeviceID
    public let uid: String
    public let name: String
    public let transportType: UInt32
    public let outputChannelCount: Int

    public init(id: AudioDeviceID,
                uid: String,
                name: String,
                transportType: UInt32,
                outputChannelCount: Int) {
        self.id = id
        self.uid = uid
        self.name = name
        self.transportType = transportType
        self.outputChannelCount = outputChannelCount
    }
}

extension DeviceDescriptor {
    public var transportName: String {
        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn:     return "内置"
        case kAudioDeviceTransportTypeUSB:         return "USB"
        case kAudioDeviceTransportTypeHDMI:        return "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
        case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
        case kAudioDeviceTransportTypeVirtual:     return "虚拟"
        case kAudioDeviceTransportTypeAggregate:   return "聚合"
        case kAudioDeviceTransportTypeAirPlay:     return "AirPlay"
        case kAudioDeviceTransportTypeBluetooth:   return "蓝牙"
        case kAudioDeviceTransportTypeBluetoothLE: return "蓝牙LE"
        default:                                   return "其它"
        }
    }

    /// 例 "27C3A Pro (HDMI)"
    public var displayName: String { "\(name) (\(transportName))" }
}
