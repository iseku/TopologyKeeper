import CoreAudio
import Foundation

/// 级联格式选择器背后的选择状态。
///
/// 放在 Core 而不是 UI 层，是为了让"级联归一化"这段逻辑可以单元测试
/// —— 它是 UI 正确性的关键（《详细设计.md》§10.5）。
///
/// 核心规则：三个维度**不是自由组合**，而是设备能力清单的投影。
/// 实测（§2.9）21 种组合中只有 `2ch/16bit` 支持 768000，
/// 用户先选它再改声道数就会造出非法组合。
public struct FormatSelection: Equatable, Sendable {

    public var channelCount: UInt32
    public var bitDepth: UInt32
    public var sampleRate: Double

    public init(channelCount: UInt32, bitDepth: UInt32, sampleRate: Double) {
        self.channelCount = channelCount
        self.bitDepth = bitDepth
        self.sampleRate = sampleRate
    }

    // MARK: - 构造

    /// 从某台设备的能力清单挑一个"合理默认值"。
    ///
    /// 优先选**声道数最大**的组合 —— 本工具的核心场景就是把设备拉到多声道
    /// （实测用户期望 8ch，而系统常常停在 2ch）。
    public static func preferred(from capability: DeviceCapability) -> FormatSelection? {
        guard !capability.isEmpty else { return nil }
        let channels = capability.maxChannelCount
        let bitDepths = capability.bitDepths(forChannelCount: channels)
        // 优先 24bit（专业音频常见），否则取最大位深
        let bits = bitDepths.contains(24) ? 24 : (bitDepths.max() ?? 0)
        let rates = capability.sampleRates(forChannelCount: channels, bitDepth: bits)
        // 优先 96000，否则取最大
        let rate = rates.contains(96000) ? 96000 : (rates.max() ?? 0)
        return FormatSelection(channelCount: channels, bitDepth: bits, sampleRate: rate)
    }

    public static func from(_ preset: AudioFormatPreset) -> FormatSelection {
        FormatSelection(channelCount: preset.channelCount,
                        bitDepth: preset.bitDepth,
                        sampleRate: preset.sampleRate)
    }

    // MARK: - 级联归一化（★ UI 正确性的关键）

    /// 把选择修正到合法范围。调用时机：任一维度被用户改动之后。
    ///
    /// 语义：**保留用户刚改动的那一维**，其余维度向它靠拢。
    /// 例如用户把声道从 2 改到 8，则位深/采样率在 8ch 的可用集合里重新选取。
    public mutating func normalize(pinningChanged changed: Dimension,
                                   against capability: DeviceCapability) {
        guard !capability.isEmpty else { return }

        switch changed {
        case .channels:
            if !capability.allChannelCounts.contains(channelCount) {
                channelCount = capability.allChannelCounts.first ?? channelCount
            }
            normalizeBitDepth(against: capability)
            normalizeSampleRate(against: capability)

        case .bitDepth:
            normalizeChannels(against: capability)
            if !capability.bitDepths(forChannelCount: channelCount).contains(bitDepth) {
                bitDepth = capability.bitDepths(forChannelCount: channelCount).first ?? bitDepth
            }
            normalizeSampleRate(against: capability)

        case .sampleRate:
            normalizeChannels(against: capability)
            normalizeBitDepth(against: capability)
            let available = capability.sampleRates(forChannelCount: channelCount, bitDepth: bitDepth)
            if !available.contains(where: { AudioFormatPreset.ratesEqual($0, sampleRate) }) {
                sampleRate = available.first ?? sampleRate
            }
        }
    }

    private mutating func normalizeChannels(against capability: DeviceCapability) {
        if !capability.allChannelCounts.contains(channelCount) {
            channelCount = capability.allChannelCounts.first ?? channelCount
        }
    }

    private mutating func normalizeBitDepth(against capability: DeviceCapability) {
        let available = capability.bitDepths(forChannelCount: channelCount)
        if !available.contains(bitDepth) {
            bitDepth = available.first ?? bitDepth
        }
    }

    private mutating func normalizeSampleRate(against capability: DeviceCapability) {
        let available = capability.sampleRates(forChannelCount: channelCount, bitDepth: bitDepth)
        if !available.contains(where: { AudioFormatPreset.ratesEqual($0, sampleRate) }) {
            sampleRate = available.first ?? sampleRate
        }
    }

    // MARK: - 校验

    /// 该选择在当前能力清单中是否真实可用
    public func isValid(against capability: DeviceCapability) -> Bool {
        capability.supports(channels: channelCount, bitDepth: bitDepth, sampleRate: sampleRate)
    }

    /// 可选值（供下拉框使用）
    public func availableBitDepths(in capability: DeviceCapability) -> [UInt32] {
        capability.bitDepths(forChannelCount: channelCount)
    }

    public func availableSampleRates(in capability: DeviceCapability) -> [Double] {
        capability.sampleRates(forChannelCount: channelCount, bitDepth: bitDepth)
    }

    // MARK: - 展示

    public var displayString: String {
        "\(channelCount)ch · \(bitDepth)bit · \(AudioFormatPreset.rateString(sampleRate))Hz"
    }

    public enum Dimension: Sendable {
        case channels, bitDepth, sampleRate
    }
}

extension DeviceCapability {
    /// 用一条真实条目构造预设（级联选择器保存时使用）。
    /// 返回 nil 表示该组合非法 —— UI 应当禁止保存。
    public func preset(for selection: FormatSelection) -> AudioFormatPreset? {
        guard let entry = entry(channels: selection.channelCount,
                                bitDepth: selection.bitDepth,
                                sampleRate: selection.sampleRate) else { return nil }
        // ★ 照抄条目，只覆盖采样率（D2）
        return AudioFormatPreset(verbatim: entry, sampleRate: selection.sampleRate)
    }
}
