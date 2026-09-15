import CoreAudio
import Foundation

/// 一个具体音频格式的**最小充分表示**。
///
/// 设计依据（《详细设计.md》D1 / 可行性分析 §2.2）：
/// 实测证明只存 (声道数, 位深, 采样率) 三个整数是不够的 ——
/// 本设备的 20bit/24bit 采用 **32bit 容器**（`mBytesPerFrame = 声道数 × 4`），
/// 而 16bit 才是紧凑打包（`声道数 × 2`）。
/// 若丢掉容器宽度与 flags，写入会**静默落到错误格式**（返回 noErr 却得到别的格式）。
///
/// 因此这里保留与 `AudioStreamBasicDescription` 对齐的全部关键字段。
public struct AudioFormatPreset: Codable, Equatable, Hashable, Sendable {

    public var sampleRate: Double
    public var channelCount: UInt32
    public var bitDepth: UInt32
    /// 区分 float / signedInteger / packed / alignedHigh 等
    public var formatFlags: UInt32
    /// 每帧字节数 —— 24-in-32 与紧凑打包的差异就体现在这里
    public var bytesPerFrame: UInt32
    public var bytesPerPacket: UInt32
    public var framesPerPacket: UInt32

    public init(sampleRate: Double,
                channelCount: UInt32,
                bitDepth: UInt32,
                formatFlags: UInt32,
                bytesPerFrame: UInt32,
                bytesPerPacket: UInt32,
                framesPerPacket: UInt32) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.bitDepth = bitDepth
        self.formatFlags = formatFlags
        self.bytesPerFrame = bytesPerFrame
        self.bytesPerPacket = bytesPerPacket
        self.framesPerPacket = framesPerPacket
    }

    // MARK: - 唯一构造入口

    /// 从设备能力清单取一条条目，**只覆盖采样率，其余原样照抄**。
    ///
    /// 这是本项目最重要的实现纪律（D2）：
    /// 实测对照 —— 照抄法 5/5 正确，手工重算字节数 1/3 正确。
    /// **绝不要自己计算 `mBytesPerFrame`。**
    public init(verbatim entry: AudioStreamRangedDescription, sampleRate: Double) {
        var asbd = entry.mFormat          // ← 原样照抄
        asbd.mSampleRate = sampleRate     // ← 唯一被覆盖的字段
        self.init(asbd: asbd)
    }

    public init(asbd: AudioStreamBasicDescription) {
        self.sampleRate = asbd.mSampleRate
        self.channelCount = asbd.mChannelsPerFrame
        self.bitDepth = asbd.mBitsPerChannel
        self.formatFlags = asbd.mFormatFlags
        self.bytesPerFrame = asbd.mBytesPerFrame
        self.bytesPerPacket = asbd.mBytesPerPacket
        self.framesPerPacket = asbd.mFramesPerPacket
    }

    public var asbd: AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: formatFlags,
            mBytesPerPacket: bytesPerPacket,
            mFramesPerPacket: framesPerPacket,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: channelCount,
            mBitsPerChannel: bitDepth,
            mReserved: 0)
    }

    // MARK: - 比对

    /// “是否已锁定”的判定：只比对 **声道 / 位深 / 采样率**。
    ///
    /// 刻意**不**比对 flags/bpf —— 设备可能合法地报告不同的容器表示，
    /// 比进去会造成"假未锁定"并引发无意义重写。
    public func matchesCurrent(_ cur: AudioStreamBasicDescription) -> Bool {
        cur.mChannelsPerFrame == channelCount
            && cur.mBitsPerChannel == bitDepth
            && Self.ratesEqual(cur.mSampleRate, sampleRate)
    }

    /// 次级健康检查：容器/标志是否与写入值一致。
    ///
    /// 不一致**不算失败**，仅记 warning —— 可能是"模式 B"（ASBD 构造问题）的迹象。
    public func containerMatches(_ cur: AudioStreamBasicDescription) -> Bool {
        cur.mBytesPerFrame == bytesPerFrame && cur.mFormatFlags == formatFlags
    }

    /// 采样率比较容差：CoreAudio 的采样率是精确离散值，0.5Hz 容差足够。
    public static func ratesEqual(_ a: Double, _ b: Double) -> Bool {
        abs(a - b) < 0.5
    }

    // MARK: - 展示

    /// 例 "8ch · 24bit · 96000Hz"
    public var displayString: String {
        "\(channelCount)ch · \(bitDepth)bit · \(Self.rateString(sampleRate))Hz"
    }

    /// 例 "8ch/24bit/96000"
    public var compactString: String {
        "\(channelCount)ch/\(bitDepth)bit/\(Self.rateString(sampleRate))"
    }

    public static func rateString(_ rate: Double) -> String {
        rate == rate.rounded() ? String(Int(rate)) : String(format: "%.0f", rate)
    }
}

extension AudioFormatPreset: CustomStringConvertible {
    public var description: String { compactString }
}
