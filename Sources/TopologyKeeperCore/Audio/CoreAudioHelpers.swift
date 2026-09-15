import CoreAudio
import Foundation

/// CoreAudio 底层辅助函数。
public enum CoreAudioHelpers {

    // MARK: - 属性地址构造

    public static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    // MARK: - 泛型读写

    /// 读取定长标量属性（如 `Float64`、`UInt32`、`AudioStreamBasicDescription`）
    public static func getScalar<T>(
        _ object: AudioObjectID,
        _ address: AudioObjectPropertyAddress,
        as type: T.Type
    ) -> T? {
        var address = address
        var size = UInt32(MemoryLayout<T>.size)
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: MemoryLayout<T>.size, alignment: MemoryLayout<T>.alignment)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, buffer) == noErr
        else { return nil }
        return buffer.load(as: T.self)
    }

    /// 读取变长数组属性（如设备列表、能力清单）
    public static func getArray<T>(
        _ object: AudioObjectID,
        _ address: AudioObjectPropertyAddress,
        as type: T.Type
    ) -> [T]? {
        var address = address
        var size: UInt32 = 0
        let stride = MemoryLayout<T>.stride
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr,
              Int(size) >= stride else { return [] }

        let count = Int(size) / stride
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, buffer) == noErr
        else { return nil }
        return Array(UnsafeBufferPointer(
            start: buffer.bindMemory(to: T.self, capacity: count), count: count))
    }

    /// 写入定长标量属性
    ///
    /// ⚠️ 这里是**按字节**把 `value` 的内存交给 HAL，所以必须显式排除引用类型：
    /// 若 `T` 是 `CFString` 之类的类类型，传入的会是**桥接对象指针的地址**，
    /// 而 HAL 期望的是**指针本身** —— 那会写进垃圾数据。
    /// 直接 `&value` 会让编译器发出 "forming 'UnsafeRawPointer' to a variable of
    /// type 'T'" 警告，正是提醒这一点。
    ///
    /// 目前所有调用点都是值类型（ASBD / Float64 / UInt32 / AudioDeviceID），
    /// 但用 `withUnsafePointer` 显式表达意图，避免将来有人传字符串踩坑。
    public static func setScalar<T>(
        _ object: AudioObjectID,
        _ address: AudioObjectPropertyAddress,
        _ value: T
    ) -> OSStatus {
        var address = address
        guard _isPOD(T.self) else {
            Log.error("setScalar 只接受值类型；拒绝写入 \(T.self)")
            return kAudioHardwareIllegalOperationError
        }
        return withUnsafePointer(to: value) { pointer in
            AudioObjectSetPropertyData(
                object, &address, 0, nil, UInt32(MemoryLayout<T>.size), pointer)
        }
    }

    /// 属性是否可设置
    public static func isSettable(
        _ object: AudioObjectID,
        _ address: AudioObjectPropertyAddress
    ) -> Bool {
        var address = address
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(object, &address, &settable) == noErr
        else { return false }
        return settable.boolValue
    }

    public static func hasProperty(
        _ object: AudioObjectID,
        _ address: AudioObjectPropertyAddress
    ) -> Bool {
        var address = address
        return AudioObjectHasProperty(object, &address)
    }

    // MARK: - 错误码

    /// 把 OSStatus 转成可读的四字符码，例 `'!dat'`
    public static func fourCharCode(_ status: OSStatus) -> String {
        let value = UInt32(bitPattern: status)
        let bytes = [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
                     UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
        guard let text = String(bytes: bytes, encoding: .ascii),
              text.allSatisfy({ $0.isLetter || $0.isNumber || " !?".contains($0) })
        else { return "0x\(String(value, radix: 16))" }
        return "'\(text)'"
    }

    public static func describe(_ status: OSStatus) -> String {
        switch status {
        case noErr:
            return "noErr"
        case kAudioHardwareUnknownPropertyError:
            return "kAudioHardwareUnknownPropertyError \(fourCharCode(status))"
        case kAudioDeviceUnsupportedFormatError:
            return "kAudioDeviceUnsupportedFormatError \(fourCharCode(status))"
        case kAudioHardwareBadObjectError:
            return "kAudioHardwareBadObjectError \(fourCharCode(status))"
        case kAudioHardwareIllegalOperationError:
            return "kAudioHardwareIllegalOperationError \(fourCharCode(status))"
        case kAudioHardwareNotRunningError:
            return "kAudioHardwareNotRunningError \(fourCharCode(status))"
        case kAudioHardwareBadDeviceError:
            return "kAudioHardwareBadDeviceError \(fourCharCode(status))"
        case kAudioHardwareUnsupportedOperationError:
            return "kAudioHardwareUnsupportedOperationError \(fourCharCode(status))"
        case kAudioDevicePermissionsError:
            return "kAudioDevicePermissionsError \(fourCharCode(status))"
        default:
            return "OSStatus \(status) \(fourCharCode(status))"
        }
    }

    // MARK: - 格式描述

    public static func formatFlagsString(_ flags: AudioFormatFlags) -> String {
        var parts: [String] = []
        if flags & kAudioFormatFlagIsFloat != 0 { parts.append("float") }
        if flags & kAudioFormatFlagIsSignedInteger != 0 { parts.append("sint") }
        if flags & kAudioFormatFlagIsBigEndian != 0 { parts.append("BE") } else { parts.append("LE") }
        if flags & kAudioFormatFlagIsPacked != 0 { parts.append("packed") }
        if flags & kAudioFormatFlagIsAlignedHigh != 0 { parts.append("alignedHigh") }
        if flags & kAudioFormatFlagIsNonInterleaved != 0 { parts.append("nonInterleaved") }
        return parts.isEmpty ? "-" : parts.joined(separator: ",")
    }

    /// 详细格式串，含容器宽度 —— 排查"模式 B"时必需
    public static func describe(_ asbd: AudioStreamBasicDescription) -> String {
        let rate = AudioFormatPreset.rateString(asbd.mSampleRate)
        return "\(asbd.mChannelsPerFrame)ch/\(rate)Hz/\(asbd.mBitsPerChannel)bit "
            + "bpf=\(asbd.mBytesPerFrame) bpp=\(asbd.mBytesPerPacket) "
            + "fpp=\(asbd.mFramesPerPacket) [\(formatFlagsString(asbd.mFormatFlags))]"
    }

    /// 简短格式串
    public static func describeShort(_ asbd: AudioStreamBasicDescription) -> String {
        "\(asbd.mChannelsPerFrame)ch/\(asbd.mBitsPerChannel)bit/\(AudioFormatPreset.rateString(asbd.mSampleRate))"
    }

    // MARK: - 声道布局：让设备自己说"哪条是低音、哪条是中置"

    /// 声道在设备声明顺序里的位置（**1-based 缓冲区索引**）
    public struct ChannelIndices: Equatable, Sendable {
        /// 低音（LFE）在这台设备的第几条声道
        public let lfe: Int?
        /// 中置（C）在这台设备的第几条声道
        public let center: Int?
        /// 读到的布局描述个数（0 表示设备没给描述，只能靠约定）
        public let descriptionCount: Int

        public init(lfe: Int?, center: Int?, descriptionCount: Int) {
            self.lfe = lfe
            self.center = center
            self.descriptionCount = descriptionCount
        }
    }

    /// 读某台输出设备的**首选声道布局**，并解析出 LFE / 中置的索引。
    ///
    /// ## 为什么需要这个（本项目的一条血泪教训）
    ///
    /// 本项目原先在 `ChannelSwapPlan` 里把"第 3 声道 = 中置、第 4 声道 = 低音"
    /// 当作**恒真**的约定。实测发现本机 `27C3A Pro` 自己声明的顺序是
    /// **L R LFE C Ls Rs …** —— 与 `MPEG_7_1_C`（L R **C LFE**）**相反**。
    ///
    /// 对**交换**无所谓（交换是对称的，谁是中置不影响结果）；
    /// 但对**混音**是致命的（混音有向，混错方向 = 混进没有声音的通道）。
    ///
    /// ⇒ 所以混音的源/目标索引**必须问设备**，而不是查表。
    ///   读不到时返回 `nil`，由调用方回落到约定值并**在日志里说明**。
    public static func channelIndices(of device: AudioObjectID) -> ChannelIndices? {
        var address = address(kAudioDevicePropertyPreferredChannelLayout,
                              scope: kAudioObjectPropertyScopeOutput)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioChannelLayout>.size) else { return nil }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return nil }

        let layout = raw.assumingMemoryBound(to: AudioChannelLayout.self).pointee
        let count = Int(layout.mNumberChannelDescriptions)

        // 情况一：带显式描述 —— 描述顺序**就是**设备的声道顺序，最可靠
        if count > 0 {
            // AudioChannelLayout 是变长结构：描述数组紧跟在头部之后。
            // 偏移用「结构体大小 - 单个描述大小」算出，避免依赖对齐假设。
            let firstOffset = MemoryLayout<AudioChannelLayout>.size
                - MemoryLayout<AudioChannelDescription>.size
            let stride = MemoryLayout<AudioChannelDescription>.stride
            var labels: [AudioChannelLabel] = []
            labels.reserveCapacity(count)
            for index in 0..<count {
                let desc = raw.advanced(by: firstOffset + index * stride)
                    .assumingMemoryBound(to: AudioChannelDescription.self).pointee
                labels.append(desc.mChannelLabel)
            }
            return indices(from: labels)
        }

        // 情况二：只有 layout tag —— 按 CoreAudio 的标准顺序反推
        switch layout.mChannelLayoutTag {
        case kAudioChannelLayoutTag_MPEG_5_1_A, kAudioChannelLayoutTag_MPEG_5_1_B,
             kAudioChannelLayoutTag_MPEG_5_1_C, kAudioChannelLayoutTag_MPEG_5_1_D,
             kAudioChannelLayoutTag_MPEG_7_1_A, kAudioChannelLayoutTag_MPEG_7_1_B,
             kAudioChannelLayoutTag_MPEG_7_1_C:
            // 这些标签都是 L R C LFE … 顺序
            return ChannelIndices(lfe: 4, center: 3, descriptionCount: 0)
        default:
            return ChannelIndices(lfe: nil, center: nil, descriptionCount: 0)
        }
    }

    /// 纯函数：从设备声明的**标签序列**里找出低音与中置的位置（**1-based**）。
    ///
    /// 单独抽出来是为了能**脱离硬件单测** —— 这段逻辑一旦错了，
    /// 混音就会混进没有声音的通道，属于"静默失效"，必须有测试盯住。
    ///
    /// 取**第一个**匹配项：多声道布局里重复标签没有意义，出现时以先者为准即可。
    public static func indices(from labels: [AudioChannelLabel]) -> ChannelIndices {
        var lfe: Int?
        var center: Int?
        for (offset, label) in labels.enumerated() {
            switch label {
            case kAudioChannelLabel_LFEScreen: if lfe == nil { lfe = offset + 1 }
            case kAudioChannelLabel_Center: if center == nil { center = offset + 1 }
            default: break
            }
        }
        return ChannelIndices(lfe: lfe, center: center, descriptionCount: labels.count)
    }

    /// 人话描述，例 "低音=第3声道、中置=第4声道（设备声明 8 条描述）"
    public static func describe(_ indices: ChannelIndices) -> String {
        let lfe = indices.lfe.map { "第\($0)声道" } ?? "未声明"
        let center = indices.center.map { "第\($0)声道" } ?? "未声明"
        return "低音=\(lfe)、中置=\(center)"
            + (indices.descriptionCount > 0 ? "（设备声明 \(indices.descriptionCount) 条描述）" : "（按布局标签推断）")
    }
}
