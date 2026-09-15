import CoreAudio
import Testing
@testable import TopologyKeeperCore

// T10–T11：能力清单的级联查询与边界情况
// 对应《详细设计.md》§10.5 与 §13.2。
//
// 这一组锁死的是 UI 格式选择器的正确性 ——
// 三个下拉框必须是能力清单的**投影**，不能让用户自由拼维度。

@Suite("能力清单级联查询")
struct CapabilityCascadeTests {

    // MARK: T10 采样率可用性依赖 (声道, 位深)

    @Test("T10a 2ch/16bit 支持 768000")
    func twoChannel16BitReaches768k() {
        let capability = makeHDMICapability()
        let rates = capability.sampleRates(forChannelCount: 2, bitDepth: 16)
        #expect(rates.contains(768000))
    }

    @Test("T10b 2ch/24bit 不支持 768000")
    func twoChannel24BitCappedAt192k() {
        let capability = makeHDMICapability()
        let rates = capability.sampleRates(forChannelCount: 2, bitDepth: 24)
        #expect(!rates.contains(768000))
        #expect(rates.max() == 192000)
    }

    @Test("T10c 8ch 的所有位深都不支持 768000（级联过滤的必要性）")
    func eightChannelNeverReaches768k() {
        let capability = makeHDMICapability()
        for bits in capability.bitDepths(forChannelCount: 8) {
            let rates = capability.sampleRates(forChannelCount: 8, bitDepth: bits)
            #expect(!rates.contains(768000),
                    "8ch/\(bits)bit 不应支持 768000")
            #expect(rates.max() == 192000)
        }
    }

    @Test("T10d 存在性校验：跨维度拼出的非法三元组必须被拒绝")
    func invalidTripleRejected() {
        let capability = makeHDMICapability()
        // 2ch/16bit/768000 合法
        #expect(capability.supports(channels: 2, bitDepth: 16, sampleRate: 768000))
        // 8ch/16bit/768000 非法 —— 用户先选前者再改声道就会造出这个组合
        #expect(!capability.supports(channels: 8, bitDepth: 16, sampleRate: 768000))
    }

    @Test("T10e 清单覆盖 2–8ch × 16/20/24bit 共 21 种组合")
    func combinationMatrix() {
        let capability = makeHDMICapability()
        #expect(capability.allChannelCounts == [2, 3, 4, 5, 6, 7, 8])
        #expect(capability.allBitDepths == [16, 20, 24])
        for channels in capability.allChannelCounts {
            #expect(capability.bitDepths(forChannelCount: channels) == [16, 20, 24])
        }
    }

    // MARK: T11 单组合设备（BlackHole 型）

    @Test("T11a 只有唯一组合时，位深维度只有一个可选值")
    func singleCombinationBitDepth() {
        let capability = makeSingleCombinationCapability()
        #expect(capability.allChannelCounts == [16])
        #expect(capability.allBitDepths == [32])
        #expect(capability.bitDepths(forChannelCount: 16) == [32])
        // 声道维度只有 16ch —— UI 应置灰而不是给出空下拉框
        #expect(capability.allChannelCounts.count == 1)
        #expect(capability.allBitDepths.count == 1)
    }

    @Test("T11b 单组合设备仍有多个采样率可选")
    func singleCombinationSampleRates() {
        let capability = makeSingleCombinationCapability()
        let rates = capability.sampleRates(forChannelCount: 16, bitDepth: 32)
        #expect(rates.count == 13)
        #expect(rates.contains(44100))
        #expect(rates.contains(768000))
    }

    @Test("T11c 空能力清单不会崩溃，且各维度均为空")
    func emptyCapabilityIsSafe() {
        let capability = DeviceCapability.empty
        #expect(capability.isEmpty)
        #expect(capability.allChannelCounts.isEmpty)
        #expect(capability.allBitDepths.isEmpty)
        #expect(capability.allSampleRates.isEmpty)
        #expect(capability.maxChannelCount == 0)
        #expect(capability.bitDepths(forChannelCount: 8).isEmpty)
        #expect(capability.sampleRates(forChannelCount: 8, bitDepth: 24).isEmpty)
        #expect(!capability.supports(channels: 8, bitDepth: 24, sampleRate: 96000))
    }

    @Test("T11d 查询不存在的声道数时返回空而非崩溃")
    func queryNonexistentChannels() {
        let capability = makeHDMICapability()
        #expect(capability.bitDepths(forChannelCount: 99).isEmpty)
        #expect(capability.sampleRates(forChannelCount: 99, bitDepth: 24).isEmpty)
    }

    // MARK: 能力变化检测

    @Test("能力签名能检测出 2ch → 2..8ch 的变化（唤醒场景）")
    func signatureDetectsCapabilityGrowth() {
        // 唤醒早期：只有 2ch（实测 §2.12 的第 1、2 次出现）
        let early = DeviceCapability(entries: (2...2).flatMap { channels in
            [UInt32(16), UInt32(20), UInt32(24)].map { bits in
                makeRanged(makeASBD(channels: UInt32(channels), bits: bits,
                                    rate: 96000, bytesPerChannel: bits == 16 ? 2 : 4))
            }
        })
        // 能力到位：2–8ch
        let full = makeHDMICapability()

        #expect(early != full)
        #expect(early.signature.count == 3)
        #expect(full.signature.count == full.combinationCount)
        // 顺序无关：重排后仍视为相同
        let reordered = DeviceCapability(entries: full.entries.reversed())
        #expect(reordered == full)
    }

    // MARK: 多流交集

    @Test("多输出流设备取能力交集（保守）")
    func intersectAcrossStreams() {
        let full = makeHDMICapability()
        // 第二个流只支持 2ch
        let restricted = DeviceCapability(entries: full.entries.filter {
            $0.mFormat.mChannelsPerFrame == 2
        })
        let intersection = DeviceCapability.intersect([full, restricted])
        #expect(intersection.allChannelCounts == [2])

        // 单流时原样返回
        #expect(DeviceCapability.intersect([full]) == full)
        // 空输入返回空
        #expect(DeviceCapability.intersect([]).isEmpty)
    }
}
