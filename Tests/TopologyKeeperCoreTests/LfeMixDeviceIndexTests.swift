import CoreAudio
import Testing
@testable import TopologyKeeperCore

// 设备**自己声明的**声道布局 → 混音索引（纯逻辑 + 编解码）。
//
// 为什么这一组测试很关键：
//   本项目原先把"第 3 声道 = 中置、第 4 声道 = 低音"当恒真约定，
//   而本机 `27C3A Pro` 声明的是 **L R LFE C Ls Rs …** —— 正好相反。
//   对交换无所谓（对称操作），对**混音**致命：混错方向就是把低音
//   混进一条**没有声音**的通道，而且**不报任何错**（静默失效）。
//
// 用户随后在生产布局下实测确认了设备声明是对的：
//   第 3 声道 = LFE（整条无声，没有低音炮）、第 4 声道 = 中置（有声）。
//
// 编号：D（Device-declared）系列。

@Suite("D 设备声明布局 → 混音索引")
struct LfeMixDeviceIndexTests {

    private let lfe = kAudioChannelLabel_LFEScreen
    private let center = kAudioChannelLabel_Center
    private let left = kAudioChannelLabel_Left
    private let right = kAudioChannelLabel_Right
    private let ls = kAudioChannelLabel_LeftSurround
    private let rs = kAudioChannelLabel_RightSurround

    // MARK: D1 纯函数：从标签序列找索引

    @Test("D1a MPEG 顺序 L R C LFE … → 中置=3、低音=4")
    func mpegOrder() {
        let idx = CoreAudioHelpers.indices(from: [left, right, center, lfe, ls, rs])
        #expect(idx.center == 3)
        #expect(idx.lfe == 4)
        #expect(idx.descriptionCount == 6)
    }

    @Test("D1b 本机实测顺序 L R LFE C … → 中置=4、低音=3（与 MPEG 相反）")
    func machineOrder() {
        let idx = CoreAudioHelpers.indices(from: [left, right, lfe, center, ls, rs])
        #expect(idx.lfe == 3, "本机低音在第 3 声道（实测整条无声）")
        #expect(idx.center == 4, "本机中置在第 4 声道（实测有声）")
    }

    @Test("D1c 8 声道实测顺序 → 低音=3、中置=4")
    func machineOrderEightChannels() {
        // 27C3A Pro 真实声明的 8 条（Probe/dev_dump 实测）：
        //   L R LFE C Ls Rs LeftTopMiddle RightTopMiddle
        // 注意第 7/8 条是**顶中**声道（标签 49/51），不是左后/右后。
        let idx = CoreAudioHelpers.indices(
            from: [left, right, lfe, center, ls, rs,
                   kAudioChannelLabel_LeftTopMiddle, kAudioChannelLabel_RightTopMiddle])
        #expect(idx.lfe == 3)
        #expect(idx.center == 4)
        #expect(idx.descriptionCount == 8)
    }

    @Test("D1d 找不到标签时返回 nil（而不是乱猜一个索引）")
    func missingLabelsReturnNil() {
        let idx = CoreAudioHelpers.indices(from: [left, right, ls, rs])
        #expect(idx.lfe == nil)
        #expect(idx.center == nil)
    }

    @Test("D1e 空标签序列 → 全 nil、计数为 0")
    func emptyLabels() {
        let idx = CoreAudioHelpers.indices(from: [])
        #expect(idx.lfe == nil)
        #expect(idx.center == nil)
        #expect(idx.descriptionCount == 0)
    }

    @Test("D1f 重复标签取第一个")
    func duplicateLabelsTakeFirst() {
        let idx = CoreAudioHelpers.indices(from: [center, left, right, lfe, center, lfe])
        #expect(idx.center == 1)
        #expect(idx.lfe == 4)
    }

    @Test("D1g 描述串同时给出低音与中置")
    func descriptionMentionsBoth() {
        let text = CoreAudioHelpers.describe(
            CoreAudioHelpers.indices(from: [left, right, lfe, center]))
        #expect(text.contains("低音=第3声道"))
        #expect(text.contains("中置=第4声道"))
    }

    // MARK: D2 设置层：设备声明 → 低音来源（目标由用户选）

    @Test("D2a 设备声明的低音位成为混音的**来源**（本机 = 第 3 声道）")
    func declaredLfeBecomesSource() {
        let settings = ChannelSwapSettings(mixEnabled: true)
        let declared = CoreAudioHelpers.ChannelIndices(lfe: 3, center: 4, descriptionCount: 8)
        let plan = settings.mixPlan(forOutputChannels: 8, declared: declared, swapPlan: nil)
        let resolved = plan.resolved()
        #expect(resolved?.inputChannel == 3, "来源按设备声明")
        #expect(resolved?.outputChannel == 4, "目标是用户选择（默认第 4 声道）")
    }

    @Test("D2b 读不到声明时回落到默认来源（第 3 声道），目标仍是用户选择")
    func fallsBackToDefaultSource() {
        let settings = ChannelSwapSettings()
        let plan = settings.mixPlan(forOutputChannels: 8, declared: nil, swapPlan: nil)
        let resolved = plan.resolved()
        #expect(resolved?.inputChannel == LfeMixPlan.defaultInputChannel)
        #expect(resolved?.outputChannel == LfeMixPlan.defaultOutputChannel)
        #expect(resolved != nil, "读不到声明也必须可用")
    }

    @Test("D2c 来源与目标**独立可设**：任意组合都原样生效（不再自动配对）")
    func sourceAndTargetAreIndependent() {
        // 用户要求（2026-09）：输入侧情况复杂，自动配对反而制造混乱，
        // 所以两个声道都由用户显式指定。
        let declared = CoreAudioHelpers.ChannelIndices(lfe: 3, center: 4, descriptionCount: 8)
        for source in LfeMixPlan.selectableChannels {
            for target in LfeMixPlan.selectableChannels where target != source {
                let settings = ChannelSwapSettings(mixSourceChannel: source,
                                                   mixTargetChannel: target)
                let plan = settings.mixPlan(forOutputChannels: 8, declared: declared, swapPlan: nil)
                let r = plan.resolved()
                #expect(r?.inputChannel == source, "来源应原样生效")
                #expect(r?.outputChannel == target, "目标应原样生效（不推导）")
            }
        }
    }

    @Test("D2c2 上游与下游可以同编号：不存在唯一无效组合这回事")
    func noInvalidCombinationAcrossSpaces() {
        // 用户纠正：CH3/CH4 是两套（上游 I / 下游 O），把两者混为一谈
        // 才会得出"同声道叠加"这种不存在的顾虑。
        let declared = CoreAudioHelpers.ChannelIndices(lfe: 3, center: 4, descriptionCount: 8)
        for ch in LfeMixPlan.selectableChannels {
            let settings = ChannelSwapSettings(mixSourceChannel: ch, mixTargetChannel: ch)
            let plan = settings.mixPlan(forOutputChannels: 8, declared: declared, swapPlan: nil)
            #expect(plan.resolved() != nil,
                    "CH\(ch)-I → CH\(ch)-O 必须可用")
            #expect(plan.unavailableReason == nil)
        }
    }

    @Test("D2d 反向配置（衰减第 4 → 混入第 3）同样可用")
    func reverseDirectionWorks() {
        let settings = ChannelSwapSettings(mixSourceChannel: 4, mixTargetChannel: 3)
        let declared = CoreAudioHelpers.ChannelIndices(lfe: 4, center: 3, descriptionCount: 6)
        let plan = settings.mixPlan(forOutputChannels: 6, declared: declared, swapPlan: nil)
        let r = plan.resolved()
        #expect(r?.inputChannel == 4)
        #expect(r?.outputChannel == 3)
    }

    @Test("D2e 交换与混音互斥：交换生效时不给混音计划")
    func swapBlocksMix() {
        let settings = ChannelSwapSettings(isEnabled: true, mixEnabled: true)
        let declared = CoreAudioHelpers.ChannelIndices(lfe: 3, center: 4, descriptionCount: 8)
        let swap = ChannelSwapPlan(sourceChannelCount: 8, firstChannel: 3, secondChannel: 4)
        let plan = settings.mixPlan(forOutputChannels: 8, declared: declared, swapPlan: swap)
        #expect(plan.resolved() == nil, "互斥组合下混音不得生效")
    }

    // MARK: D3 增益、默认值与宽松解码

    @Test("D3a 增益按 mixGainDB 换算（默认 −10dB → 0.3162）")
    func gainComesFromSettings() {
        let plan = ChannelSwapSettings().mixPlan(forOutputChannels: 8)
        #expect(abs(plan.gain - 0.3162) < 0.001)
    }

    @Test("D3b 自定义增益生效（−20dB → 0.1）")
    func customGain() {
        let plan = ChannelSwapSettings(mixGainDB: -20).mixPlan(forOutputChannels: 8)
        #expect(abs(plan.gain - 0.1) < 1e-6)
    }

    @Test("D3c 默认：混音关闭、增益 −10dB、目标第 4 声道")
    func defaults() {
        let s = ChannelSwapSettings()
        #expect(s.mixEnabled == false)
        #expect(s.mixGainDB == LfeMixPlan.defaultGainDB)
        #expect(s.mixSourceChannel == LfeMixPlan.defaultInputChannel)
        #expect(s.mixTargetChannel == LfeMixPlan.defaultOutputChannel, "目标由配对自动推导")
    }

    @Test("D3d 老配置（完全没有 mix 字段）必须能解码成功且回落默认")
    func decodesLegacyConfigWithoutMixFields() throws {
        let legacy = """
        {"isEnabled":true,"firstChannel":3,"secondChannel":4,"alignInputSampleRate":true,
         "retryBackoffMs":[1000,2000],"notifyOnGiveUp":true}
        """
        let decoded = try JSONDecoder().decode(ChannelSwapSettings.self, from: Data(legacy.utf8))
        #expect(decoded.isEnabled == true, "老字段必须照常解出")
        #expect(decoded.mixEnabled == false, "缺失的新字段回落默认")
        #expect(decoded.mixGainDB == LfeMixPlan.defaultGainDB)
        #expect(decoded.mixSourceChannel == LfeMixPlan.defaultInputChannel)
        #expect(decoded.mixTargetChannel == LfeMixPlan.defaultOutputChannel)
    }

    @Test("D3e 混音目标为 null（旧版本写过 nil）时回落默认，而不是解码失败")
    func decodesNullTargetGracefully() throws {
        // 早期版本用 mixTargetChannel: nil 表示"跟随交换"。该语义已废弃（用户确认
        // 交换与混音互斥），但**已存配置里可能留着 null**，必须能平滑降级。
        let json = """
        {"isEnabled":false,"mixEnabled":true,"mixGainDB":-6,"mixTargetChannel":null}
        """
        let decoded = try JSONDecoder().decode(ChannelSwapSettings.self, from: Data(json.utf8))
        #expect(decoded.mixEnabled == true)
        #expect(decoded.mixGainDB == -6)
        #expect(decoded.mixSourceChannel == LfeMixPlan.defaultInputChannel,
                "null 应回落默认来源，而不是让整份配置读不出来")
    }

    @Test("D3f 目标声道往返一致")
    func targetRoundTrips() throws {
        var s = ChannelSwapSettings()
        s.mixEnabled = true
        s.mixGainDB = -12
        s.mixSourceChannel = 4          // 反向：衰减第4 → 混入第3
        s.mixTargetChannel = 3
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(ChannelSwapSettings.self, from: data)
        #expect(back == s)
        #expect(back.mixSourceChannel == 4)
        #expect(back.mixTargetChannel == 3, "两个声道都必须往返一致")
    }

    @Test("D3g 描述串给出源→目标与 dB")
    func mixDescriptionIsInformative() {
        let s = ChannelSwapSettings(mixEnabled: true)
        let declared = CoreAudioHelpers.ChannelIndices(lfe: 3, center: 4, descriptionCount: 8)
        let text = s.mixDescription(channels: 8, declared: declared, swapPlan: nil)
        #expect(text.contains("CH3-I → CH4-O"), "用 I/O 后缀区分两个空间")
        #expect(text.contains("-10dB"))
    }
}
