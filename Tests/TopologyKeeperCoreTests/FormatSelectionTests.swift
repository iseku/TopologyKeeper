import CoreAudio
import Testing
@testable import TopologyKeeperCore

// 级联选择器逻辑的单元测试（《详细设计.md》§10.5 / T10）。
//
// 这段逻辑是 UI 正确性的关键：三个下拉框**不是自由组合**，
// 而是设备能力清单的投影。实测依据 §2.9：
// 27C3A Pro 的 21 种组合中，只有 2ch/16bit 支持 768000。

@Suite("级联格式选择")
struct FormatSelectionTests {

    // MARK: 默认值

    @Test("默认选择取最大声道 + 24bit + 96000（本工具的核心场景）")
    func preferredSelection() {
        let capability = makeHDMICapability()
        let selection = FormatSelection.preferred(from: capability)

        #expect(selection?.channelCount == 8)
        #expect(selection?.bitDepth == 24)
        #expect(selection?.sampleRate == 96000)
        #expect(selection?.isValid(against: capability) == true)
    }

    @Test("单组合设备（BlackHole 型）的默认选择跟随唯一组合")
    func preferredForSingleCombinationDevice() {
        let capability = makeSingleCombinationCapability()
        let selection = FormatSelection.preferred(from: capability)

        #expect(selection?.channelCount == 16)
        #expect(selection?.bitDepth == 32)
        // 该设备没有 96000 之外的偏好冲突，96000 在列表中
        #expect(selection?.sampleRate == 96000)
        #expect(selection?.isValid(against: capability) == true)
    }

    @Test("空能力清单返回 nil 而不是崩溃")
    func preferredOnEmptyCapability() {
        #expect(FormatSelection.preferred(from: .empty) == nil)
    }

    // MARK: 级联归一化：这就是必须级联的原因

    @Test("从 2ch/16bit/768000 改声道到 8ch 时，采样率必须自动降级")
    func normalizeDrops778kWhenChannelsChange() {
        let capability = makeHDMICapability()

        // 用户先选了 2ch/16bit/768000（唯一支持 768000 的组合）
        var selection = FormatSelection(channelCount: 2, bitDepth: 16, sampleRate: 768000)
        #expect(selection.isValid(against: capability), "起始组合应当合法")

        // 然后把声道改成 8
        selection.channelCount = 8
        selection.normalize(pinningChanged: .channels, against: capability)

        // 8ch 不支持 768000 —— 必须被自动修正到合法值
        #expect(!AudioFormatPreset.ratesEqual(selection.sampleRate, 768000),
                "8ch 不可能支持 768000，采样率必须被降级")
        #expect(selection.isValid(against: capability),
                "归一化后必须是合法组合，实际 \(selection.displayString)")
    }

    @Test("改位深时会重算采样率可用集合")
    func normalizeOnBitDepthChange() {
        let capability = makeHDMICapability()
        var selection = FormatSelection(channelCount: 2, bitDepth: 16, sampleRate: 768000)

        // 位深改成 24 → 2ch/24bit 不含 768000
        selection.bitDepth = 24
        selection.normalize(pinningChanged: .bitDepth, against: capability)

        #expect(!AudioFormatPreset.ratesEqual(selection.sampleRate, 768000))
        #expect(selection.isValid(against: capability))
        #expect(selection.channelCount == 2, "改位深不应影响已选声道")
    }

    @Test("改采样率时保留采样率，只修正其它维度")
    func normalizeKeepsSampleRate() {
        let capability = makeHDMICapability()
        var selection = FormatSelection(channelCount: 2, bitDepth: 16, sampleRate: 768000)

        selection.normalize(pinningChanged: .sampleRate, against: capability)

        // 用户改的是采样率，所以采样率保留
        #expect(AudioFormatPreset.ratesEqual(selection.sampleRate, 768000))
        #expect(selection.isValid(against: capability))
        // 2ch/16bit/768000 本来就合法，什么都不用改
        #expect(selection.channelCount == 2 && selection.bitDepth == 16)
    }

    @Test("非法声道数被修正到可用集合内的值")
    func normalizeInvalidChannelCount() {
        let capability = makeSingleCombinationCapability()   // 只有 16ch
        var selection = FormatSelection(channelCount: 8, bitDepth: 32, sampleRate: 48000)

        selection.normalize(pinningChanged: .channels, against: capability)

        #expect(selection.channelCount == 16)
        #expect(selection.isValid(against: capability))
    }

    @Test("非法位深被修正")
    func normalizeInvalidBitDepth() {
        let capability = makeSingleCombinationCapability()   // 只有 32bit
        var selection = FormatSelection(channelCount: 16, bitDepth: 24, sampleRate: 48000)

        selection.normalize(pinningChanged: .bitDepth, against: capability)

        #expect(selection.bitDepth == 32)
        #expect(selection.isValid(against: capability))
    }

    @Test("归一化后的一批组合全部合法（回归）")
    func normalizedSelectionsAreAlwaysValid() {
        let capability = makeHDMICapability()
        let allChannels = capability.allChannelCounts
        let allRates = capability.allSampleRates

        for channels in allChannels {
            for bits in [UInt32(16), UInt32(20), UInt32(24)] {
                for rate in allRates {
                    var selection = FormatSelection(channelCount: channels,
                                                    bitDepth: bits,
                                                    sampleRate: rate)
                    selection.normalize(pinningChanged: .channels, against: capability)
                    #expect(selection.isValid(against: capability),
                            "归一化后仍非法：\(selection.displayString)")
                }
            }
        }
    }

    // MARK: 校验与构造

    @Test("跨维度拼出的非法组合被 isValid 拒绝")
    func invalidCombinationRejected() {
        let capability = makeHDMICapability()
        let invalid = FormatSelection(channelCount: 8, bitDepth: 16, sampleRate: 768000)
        #expect(!invalid.isValid(against: capability))
        // 同时 preset(for:) 也必须返回 nil —— UI 据此禁止保存
        #expect(capability.preset(for: invalid) == nil)
    }

    @Test("合法组合构造出的 preset 照抄能力清单的字节数")
    func presetUsesVerbatimByteSize() {
        let capability = makeHDMICapability()
        let selection = FormatSelection(channelCount: 8, bitDepth: 24, sampleRate: 96000)
        let preset = capability.preset(for: selection)

        #expect(preset != nil)
        // 8ch × 4 字节容器 = 32，而不是 8 × 3 = 24
        #expect(preset?.bytesPerFrame == 32)
        #expect(preset?.sampleRate == 96000)
        #expect(preset?.channelCount == 8)
        #expect(preset?.bitDepth == 24)
    }

    @Test("可用值查询与实际能力一致")
    func availableValuesMatchCapability() {
        let capability = makeHDMICapability()
        let selection = FormatSelection(channelCount: 8, bitDepth: 24, sampleRate: 96000)

        #expect(selection.availableBitDepths(in: capability) == [16, 20, 24])
        let rates = selection.availableSampleRates(in: capability)
        #expect(!rates.contains(768000), "8ch/24bit 不应有 768000")
        #expect(rates.contains(96000))
    }
}
