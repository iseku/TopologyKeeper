import CoreAudio
import Foundation

/// 设备当前**实际支持**的格式集合，来自 `kAudioStreamPropertyAvailablePhysicalFormats`。
///
/// 设计依据：
/// **UI 的三个下拉框不是自由组合，而是这份清单的投影。**
///
/// 实测要点：
/// * `mSampleRateRange` 在全部 193 条实测条目中都退化成**单点**
///   （如 `192000–192000`），**不能用来判断支持的采样率**；
///   采样率必须从每条的 `mSampleRate` 字段收集成离散集合。
/// * 各组合的采样率集合**不一定相同**：27C3A Pro 的 21 种组合中，
///   只有 `2ch/16bit` 支持 768000，其余 20 种只到 192000。
///   所以必须支持级联过滤，不能让用户自由拼三个维度。
/// * 某些设备只有**唯一组合**（如 BlackHole 16ch 只有 16ch/32bit float），
///   此时相应维度的可选值只有一个，UI 需要置灰而非崩溃。
public struct DeviceCapability: Sendable {

    /// 原始条目，**写入时直接照抄**。顺序保持设备返回的顺序。
    public let entries: [AudioStreamRangedDescription]

    public init(entries: [AudioStreamRangedDescription]) {
        self.entries = entries
    }

    public static let empty = DeviceCapability(entries: [])

    public var isEmpty: Bool { entries.isEmpty }

    /// 可用组合总数（UI 展示用）
    public var combinationCount: Int { entries.count }

    // MARK: - 一级/全量维度

    /// 全部可用声道数（去重升序）
    public var allChannelCounts: [UInt32] {
        uniqueSorted(entries.map { $0.mFormat.mChannelsPerFrame })
    }

    /// 全部可用位深（去重升序）
    public var allBitDepths: [UInt32] {
        uniqueSorted(entries.map { $0.mFormat.mBitsPerChannel })
    }

    /// 全部可用采样率（去重升序）
    public var allSampleRates: [Double] {
        uniqueSorted(entries.map { $0.mFormat.mSampleRate })
    }

    // MARK: - 级联查询（UI 下拉框的数据源）

    /// 给定声道数，返回可用的位深。
    public func bitDepths(forChannelCount channels: UInt32) -> [UInt32] {
        uniqueSorted(entries
            .filter { $0.mFormat.mChannelsPerFrame == channels }
            .map { $0.mFormat.mBitsPerChannel })
    }

    /// 给定声道数与位深，返回可用的采样率。
    ///
    /// 实测价值：`bitDepths(forChannelCount: 8)` 后再查采样率，
    /// 会发现 8ch 的所有位深都**不含 768000** —— 这正是需要级联的原因。
    public func sampleRates(forChannelCount channels: UInt32, bitDepth: UInt32) -> [Double] {
        uniqueSorted(entries
            .filter { $0.mFormat.mChannelsPerFrame == channels
                   && $0.mFormat.mBitsPerChannel == bitDepth }
            .map { $0.mFormat.mSampleRate })
    }

    // MARK: - 存在性校验

    /// 该三元组是否真实可用。命中则返回**原始条目**（写入时照抄它）。
    ///
    /// 这是"能力门控"的核心：返回 nil 表示**能力尚未就绪，
    /// 应该什么都不做并等待**，而不是尝试写入。
    public func entry(channels: UInt32,
                      bitDepth: UInt32,
                      sampleRate: Double) -> AudioStreamRangedDescription? {
        entries.first {
            $0.mFormat.mChannelsPerFrame == channels
                && $0.mFormat.mBitsPerChannel == bitDepth
                && AudioFormatPreset.ratesEqual($0.mFormat.mSampleRate, sampleRate)
        }
    }

    public func supports(channels: UInt32, bitDepth: UInt32, sampleRate: Double) -> Bool {
        entry(channels: channels, bitDepth: bitDepth, sampleRate: sampleRate) != nil
    }

    public func supports(_ preset: AudioFormatPreset) -> Bool {
        supports(channels: preset.channelCount,
                 bitDepth: preset.bitDepth,
                 sampleRate: preset.sampleRate)
    }

    /// 设备当前能达到的最大声道数。用于 UI 文案
    /// （例：“设备当前最高 2ch，正在等待 8ch 上线”）。
    public var maxChannelCount: UInt32 {
        allChannelCounts.max() ?? 0
    }

    // MARK: - 诊断

    /// 人类可读的能力摘要，用于日志。
    /// 例 "可用声道=[2, 3, 4, 5, 6, 7, 8] 组合=155"
    public var summary: String {
        "可用声道=\(allChannelCounts) 组合=\(combinationCount)"
    }

    /// 按 (声道, 位深) 分组的能力明细，用于日志与调试。
    public func detailedDescription() -> String {
        let groups = Dictionary(grouping: entries) {
            "\($0.mFormat.mChannelsPerFrame)ch/\($0.mFormat.mBitsPerChannel)bit"
        }
        return groups.keys.sorted().map { key in
            let rates = groups[key]!.map { $0.mFormat.mSampleRate }.sorted()
            return "  \(key): \(rates.map(AudioFormatPreset.rateString).joined(separator: ", "))"
        }.joined(separator: "\n")
    }

    // MARK: - 私有

    private func uniqueSorted<T: Comparable & Hashable>(_ values: [T]) -> [T] {
        Array(Set(values)).sorted()
    }
}

// MARK: - 变化检测

extension DeviceCapability {
    /// 能力签名：(声道, 位深, 采样率) 三元组的集合。
    ///
    /// 用它做**变化检测**，而不是逐字段比较 ——
    /// `AudioStreamRangedDescription` 是 C 结构体且没有 Equatable，
    /// 而语义上我们只关心"可选组合集合有没有变"。
    /// 实测中这个集合会从 26 个（仅 2ch）变成 155 个（含 8ch）。
    public var signature: Set<String> {
        Set(entries.map {
            "\($0.mFormat.mChannelsPerFrame)/\($0.mFormat.mBitsPerChannel)"
                + "/\(AudioFormatPreset.rateString($0.mFormat.mSampleRate))"
        })
    }
}

extension DeviceCapability: Equatable {
    /// 顺序无关的语义相等：只要可选组合集合相同即视为相同。
    public static func == (lhs: DeviceCapability, rhs: DeviceCapability) -> Bool {
        lhs.signature == rhs.signature
    }
}

extension DeviceCapability {
    /// 多输出流设备的合并能力。
    ///
    /// 实测本机 4 台设备都只有 1 个输出流，但 USB 音频接口可能有多流。
    /// 多流时取**交集**（保守）：只有所有流都支持的组合才真正可用。
    public static func intersect(_ capabilities: [DeviceCapability]) -> DeviceCapability {
        let nonEmpty = capabilities.filter { !$0.isEmpty }
        guard let first = nonEmpty.first else { return .empty }
        guard nonEmpty.count > 1 else { return first }

        // 以第一条为基准，保留在所有其余清单中都存在的组合
        let kept = first.entries.filter { candidate in
            nonEmpty.dropFirst().allSatisfy { other in
                other.entries.contains {
                    $0.mFormat.mChannelsPerFrame == candidate.mFormat.mChannelsPerFrame
                        && $0.mFormat.mBitsPerChannel == candidate.mFormat.mBitsPerChannel
                        && AudioFormatPreset.ratesEqual($0.mFormat.mSampleRate,
                                                        candidate.mFormat.mSampleRate)
                }
            }
        }
        return DeviceCapability(entries: kept)
    }
}
