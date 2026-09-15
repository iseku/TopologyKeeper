import AppKit
import Testing
@testable import TopologyKeeperCore

// T18：状态栏图标映射与符号可用性。
//
// 为什么值得测：SF Symbol 名字写错**不会报错**，只会渲染成空白 ——
// 用户在菜单栏看到一个"什么都没有"的图标，完全无从判断哪里出了问题。
// 这里直接向 AppKit 确认符号真实存在。

@Suite("T18 状态栏图标")
struct StatusIconTests {

    @Test("T18a 三符号制：已锁定用 checkmark，失败用 xmark，其余用 slash")
    func iconMapping() {
        #expect(LockState.locked.iconName == "waveform.badge.checkmark")
        #expect(LockState.failed(.notEffective).iconName == "waveform.badge.xmark")

        let notLocked: [LockState] = [
            .noRule,
            .deviceAbsent,
            .suspended(.sleeping),
            .suspended(.userPaused),
            .suspended(.conflictBackoff),
            .suspended(.policyOnConnectOnly),
            .waitingForCapability(availableMaxChannels: 2),
            .applying,
        ]
        for state in notLocked {
            #expect(state.iconName == "waveform.slash",
                    "\(state.displayText) 应使用 waveform.slash")
        }
    }

    @Test("T18b 着色：过渡态橙、失败红、其余跟随菜单栏外观")
    func tintMapping() {
        #expect(LockState.locked.statusTint == .normal)
        #expect(LockState.failed(.wrongFormat).statusTint == .critical)
        #expect(LockState.waitingForCapability(availableMaxChannels: 8).statusTint == .inProgress)
        #expect(LockState.applying.statusTint == .inProgress)
        #expect(LockState.deviceAbsent.statusTint == .normal)
        #expect(LockState.noRule.statusTint == .normal)
    }

    @Test("T18c 所有状态用到的 SF Symbol 在本机真实存在")
    func symbolsExistOnThisSystem() {
        var names = Set<String>()
        let allStates: [LockState] = [
            .noRule, .deviceAbsent,
            .waitingForCapability(availableMaxChannels: 2),
            .locked, .applying,
            .failed(.notEffective),
            .suspended(.sleeping),
        ]
        for state in allStates { names.insert(state.iconName) }

        #expect(names.count == 3, "应当只用到 3 个符号，实际 \(names)")
        for name in names {
            let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            #expect(image != nil, "SF Symbol 不存在：\(name)（名字写错会静默渲染为空白）")
        }
    }
}
