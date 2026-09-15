import CoreAudio
import Testing
@testable import TopologyKeeperCore

// 声道交换计划的纯逻辑测试（《探针结论-声道交换.md》§3）。
//
// 编号规范（用户要求）：**对外一律 1-based**（第 1…8 声道），
//   与「音频MIDI设置」、电视/功放 UI 一致；只有写给 CoreAudio 的
//   ChannelMap 才转成 0-based。本文件的断言同时覆盖这两个层面。
//
// 布局对照（1-based）：
//   第1=左 第2=右 第3=中置 第4=低音 第5=左环绕 第6=右环绕 第7=左后环绕 第8=右后环绕

@Suite("S1 声道交换计划")
struct ChannelSwapPlanTests {

    // MARK: 默认值（1-based）

    @Test("S1a 默认交换对是第 3/第 4 声道（中置↔低音），对外表述为 1-based")
    func defaultPairIsThirdAndFourth() {
        let plan = ChannelSwapPlan(sourceChannelCount: 8)
        #expect(plan.firstChannel == 3)
        #expect(plan.secondChannel == 4)
        #expect(ChannelSwapPlan.defaultFirstChannel == 3)
        #expect(ChannelSwapPlan.defaultSecondChannel == 4)
    }

    @Test("S1b 编号转换是唯二的转换点，且互为逆运算")
    func indexConversionIsInvertible() {
        for ch in 1...8 {
            #expect(ChannelSwapPlan.channelNumber(forAPIIndex: ChannelSwapPlan.apiIndex(forChannel: ch)) == ch)
        }
        #expect(ChannelSwapPlan.apiIndex(forChannel: 1) == 0)
        #expect(ChannelSwapPlan.apiIndex(forChannel: 3) == 2)
        #expect(ChannelSwapPlan.apiIndex(forChannel: 4) == 3)
        #expect(ChannelSwapPlan.apiIndex(forChannel: 8) == 7)
    }

    // MARK: 核心：写进 API 的映射表（0-based）

    @Test("S1c 8 声道默认交换给出 [0,1,3,2,4,5,6,7]（本机 27C3A Pro 的实际用例）")
    func eightChannelDefaultMap() {
        #expect(ChannelSwapPlan(sourceChannelCount: 8).swapMap == [0, 1, 3, 2, 4, 5, 6, 7])
    }

    @Test("S1d 6 声道（5.1）交换给出 [0,1,3,2,4,5]")
    func sixChannelDefaultMap() {
        #expect(ChannelSwapPlan(sourceChannelCount: 6).swapMap == [0, 1, 3, 2, 4, 5])
    }

    @Test("S1e 映射表长度恒等于声道数（ChannelMap 元素个数必须匹配目标声道数）")
    func mapLengthMatchesChannelCount() {
        for n in 6...16 {
            #expect(ChannelSwapPlan(sourceChannelCount: n).swapMap?.count == n, "声道数 \(n) 时映射长度不对")
        }
    }

    @Test("S1f 映射是**对合**：交换两次回到原状")
    func mapIsInvolution() {
        for n in 6...16 {
            let plan = ChannelSwapPlan(sourceChannelCount: n)
            guard let map = plan.swapMap else { Issue.record("\(n)ch 应可交换"); continue }
            let twice = (0..<n).map { map[Int(map[$0])] }
            #expect(twice == (0..<n).map { Int32($0) }, "\(n)ch 的映射不是对合")
        }
    }

    @Test("S1g 映射是双射：没有声道被丢掉或重复")
    func mapIsBijection() {
        for n in 6...16 {
            let plan = ChannelSwapPlan(sourceChannelCount: n)
            guard let map = plan.swapMap else { Issue.record("\(n)ch 应可交换"); continue }
            #expect(Set(map) == Set((0..<n).map { Int32($0) }), "\(n)ch 映射不是双射")
        }
    }

    @Test("S1h 只有被指定的两个位置变了，其余声道保持原位")
    func onlyTargetChannelsChange() {
        guard let map = ChannelSwapPlan(sourceChannelCount: 8).swapMap else {
            Issue.record("应可交换"); return
        }
        for i in 0..<8 where i != 2 && i != 3 {
            #expect(map[i] == Int32(i), "第 \(i + 1) 声道（1-based）不该被改动")
        }
        #expect(map[2] == 3)   // 第3声道 ← 源第4声道
        #expect(map[3] == 2)   // 第4声道 ← 源第3声道
    }

    // MARK: 边界与拒绝

    @Test("S1i 声道数不足 6 时判定为不可交换")
    func rejectsTooFewChannels() {
        #expect(ChannelSwapPlan.canSwap(onDeviceWithChannels: 6) == true)
        #expect(ChannelSwapPlan.canSwap(onDeviceWithChannels: 8) == true)
        #expect(ChannelSwapPlan.canSwap(onDeviceWithChannels: 5) == false)
        #expect(ChannelSwapPlan.canSwap(onDeviceWithChannels: 2) == false)
        #expect(ChannelSwapPlan.canSwap(onDeviceWithChannels: 0) == false)
    }

    @Test("S1j 声道数不足 6 时不给映射表（产品规则：<6 声道不做交换）")
    func noMapWhenChannelsTooFew() {
        #expect(ChannelSwapPlan(sourceChannelCount: 5).swapMap == nil)
        #expect(ChannelSwapPlan(sourceChannelCount: 4).swapMap == nil)
        #expect(ChannelSwapPlan(sourceChannelCount: 2).swapMap == nil)
        #expect(ChannelSwapPlan(sourceChannelCount: 0).swapMap == nil)
        #expect(ChannelSwapPlan(sourceChannelCount: -1).swapMap == nil)
        #expect(ChannelSwapPlan(sourceChannelCount: 6).swapMap != nil)   // 边界：恰好 6 允许
    }

    @Test("S1k swapMap 为 nil 当且仅当 canSwap 判定不可行（两者必须一致）")
    func mapNilMatchesCanSwap() {
        for n in [0, 1, 2, 3, 4, 5, 6, 7, 8, 16] {
            let hasMap = ChannelSwapPlan(sourceChannelCount: n).swapMap != nil
            #expect(hasMap == ChannelSwapPlan.canSwap(onDeviceWithChannels: n),
                    "\(n)ch 时 swapMap 与 canSwap 不一致")
        }
    }

    @Test("S1l 声道号越界则拒绝（对外是 1-based，所以下界是 1）")
    func rejectsInvalidChannels() {
        // 声道号 0 在 1-based 下非法
        #expect(ChannelSwapPlan(sourceChannelCount: 8, firstChannel: 0, secondChannel: 4).swapMap == nil)
        // 超出声道数
        #expect(ChannelSwapPlan(sourceChannelCount: 8, firstChannel: 3, secondChannel: 9).swapMap == nil)
        // 合法边界
        #expect(ChannelSwapPlan(sourceChannelCount: 8, firstChannel: 1, secondChannel: 8).swapMap != nil)
    }

    @Test("S1l2 两者相同 = **显式不交换**，返回恒等映射而不是 nil")
    func sameChannelMeansIdentity() {
        // 语义变更（v3 混音引入）：
        //   早先 a == b 返回 nil，而 nil 的含义是"这台设备做不了" →
        //   驱动会当成错误拒绝启动通路。
        //   但"不交换、但通路照跑"是**合法需求**：混音与交换互斥却共用同一条通路，
        //   只开混音时就需要这种恒等计划（否则桥接不建立 → 整条链路静音，实测踩过）。
        #expect(ChannelSwapPlan(sourceChannelCount: 8, firstChannel: 3, secondChannel: 3).swapMap
                == [0, 1, 2, 3, 4, 5, 6, 7])
        #expect(ChannelSwapPlan(sourceChannelCount: 6, firstChannel: 4, secondChannel: 4).swapMap
                == [0, 1, 2, 3, 4, 5])
        // 仍然是"可用"的计划（不是 nil）
        #expect(ChannelSwapPlan(sourceChannelCount: 8, firstChannel: 3, secondChannel: 3).isIdentity)
    }

    @Test("S1m 可交换任意一对声道（不只 C/LFE），且按 1-based 解释")
    func supportsArbitraryPair() {
        // 第1↔第2 声道（左右互换）→ API 索引 0 与 1
        #expect(ChannelSwapPlan(sourceChannelCount: 8, firstChannel: 1, secondChannel: 2).swapMap
                == [1, 0, 2, 3, 4, 5, 6, 7])
        // 第7↔第8 声道 → API 索引 6 与 7
        #expect(ChannelSwapPlan(sourceChannelCount: 8, firstChannel: 7, secondChannel: 8).swapMap
                == [0, 1, 2, 3, 4, 5, 7, 6])
    }

    // MARK: 反查与描述

    @Test("S1n sourceChannel 反查与映射表一致（1-based 进出）")
    func sourceChannelMatchesMap() {
        let plan = ChannelSwapPlan(sourceChannelCount: 8)
        guard let map = plan.swapMap else { Issue.record("应可交换"); return }
        for ch in 1...8 {
            // map 是 API 的 0-based 索引；sourceChannel 返回 1-based 声道号 → 需转换后比较
            let apiIndex = Int(map[ch - 1])
            #expect(plan.sourceChannel(forDestination: ch) == ChannelSwapPlan.channelNumber(forAPIIndex: apiIndex))
        }
        #expect(plan.sourceChannel(forDestination: 0) == nil)    // 0 非法
        #expect(plan.sourceChannel(forDestination: 9) == nil)
    }

    @Test("S1o isIdentity 只有不交换时才为真")
    func identityDetection() {
        #expect(ChannelSwapPlan(sourceChannelCount: 8).isIdentity == false)
        #expect(ChannelSwapPlan(sourceChannelCount: 2).isIdentity == true)   // 无法生成→按恒等
    }

    @Test("S1p 声道语义名按 1-based 覆盖 7.1 全部 8 个声道")
    func semanticNames() {
        #expect(ChannelSwapPlan.semanticName(forChannel: 1) == "左")
        #expect(ChannelSwapPlan.semanticName(forChannel: 3) == "中置")
        #expect(ChannelSwapPlan.semanticName(forChannel: 4) == "低音")
        #expect(ChannelSwapPlan.semanticName(forChannel: 8) == "右后环绕")
        #expect(ChannelSwapPlan.semanticName(forChannel: 0) == nil)
        #expect(ChannelSwapPlan.semanticName(forChannel: 9) == nil)
    }

    @Test("S1q 交换描述用 1-based 表述（对外展示不出现 0-based 下标）")
    func swapDescriptionIsOneBased() {
        let desc = ChannelSwapPlan(sourceChannelCount: 8).swapDescription
        #expect(desc == "中置(第3声道) ↔ 低音(第4声道)")
        #expect(!desc.contains("(2)") && !desc.contains("(3)"))
    }

    @Test("S1t 恒等计划的描述必须写「不交换」，不得输出「第1声道 ↔ 第1声道」")
    func identitySwapDescriptionSaysNoSwap() {
        // 只开混音时交换就是恒等的，且用 first==second==1 构造
        // （见 ChannelSwapSettings.plan(identityWhenDisabled:)）。
        // 回归点：先前启动日志会打出"左(第1声道) ↔ 左(第1声道)"。
        let identity = ChannelSwapPlan(sourceChannelCount: 8, firstChannel: 1, secondChannel: 1)
        #expect(identity.isIdentity)
        #expect(identity.swapDescription == "不交换")
        #expect(!identity.swapDescription.contains("↔"))
    }

    @Test("S1r 不可用原因含实际声道数与最小要求，且用 1-based 声道号")
    func unavailableReasonText() {
        let text = ChannelSwapPlan.unavailableReason(channels: 2)
        #expect(text.contains("2 声道"))
        #expect(text.contains("6 声道"))
        #expect(text.contains("第 3 声道") && text.contains("第 4 声道"))
    }

    // MARK: 与探针实测对照

    @Test("S1s 与探针实测写入并按听感确认生效的映射表逐项一致")
    func matchesProbeVerifiedMap() {
        // Probe/e2e_swap.swift 实测写入并**经左右互换听感确认生效**的那张表
        #expect(ChannelSwapPlan(sourceChannelCount: 8).swapMap == [0, 1, 3, 2, 4, 5, 6, 7])
        // 左右互换（用于验证机制的方向性对照）
        #expect(ChannelSwapPlan(sourceChannelCount: 8, firstChannel: 1, secondChannel: 2).swapMap
                == [1, 0, 2, 3, 4, 5, 6, 7])
    }
}
