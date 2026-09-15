// ⚠️ 用 `import AppKit` 而**不是** `import Foundation`：
//    本机只有 CLT，`import Foundation` + `import Testing` 会报
//    `no such module '_Testing_Foundation'`。
//    T20（图标几何）也是这么处理的；AppKit 顺带提供 CGFloat。
import AppKit
import Testing
@testable import TopologyKeeperCore

// P：弹出面板高度几何。
//
// 为什么值得单测：本机**只有 4 台音频设备**，规则列表永远到不了滚动阈值
// （实测每条约 97pt，阈值 714pt ⇒ 需 8 条左右），
// 所以"超过上限就滚动"这条分支**无法靠点界面验证**，只能用测试钉住。
//
// 数值取自真机实测日志：
//   上限 901、固定部分 187、2/3/4 条规则分别为 208/305/402。

@Suite("P 弹出面板高度几何")
struct PopoverLayoutTests {

    private let cap: CGFloat = 901
    private let chrome: CGFloat = 187

    @Test("P1 内容不高时列表取内容高度 ⇒ 不滚动（真机 4 条规则的情形）")
    func fitsWithoutScrolling() {
        let h = PopoverLayout.listHeight(contentHeight: 402, chromeHeight: chrome, maxContentHeight: cap)
        #expect(h == 402)
        #expect(!PopoverLayout.needsScrolling(contentHeight: 402, chromeHeight: chrome, maxContentHeight: cap))
    }

    @Test("P2 内容超过「上限 − 固定部分」时列表被压到剩余空间 ⇒ 滚动")
    func exceedsTriggersScrolling() {
        // 本机到不了这条分支，靠本测试覆盖
        let h = PopoverLayout.listHeight(contentHeight: 2000, chromeHeight: chrome, maxContentHeight: cap)
        #expect(h == cap - chrome)          // 714
        #expect(PopoverLayout.needsScrolling(contentHeight: 2000, chromeHeight: chrome, maxContentHeight: cap))
    }

    @Test("P3 边界：恰好等于剩余空间不滚动，多 1pt 就滚")
    func boundaryIsExact() {
        let room = cap - chrome                // 714
        #expect(!PopoverLayout.needsScrolling(contentHeight: room, chromeHeight: chrome, maxContentHeight: cap))
        #expect(PopoverLayout.needsScrolling(contentHeight: room + 1, chromeHeight: chrome, maxContentHeight: cap))
    }

    @Test("P4 尚未测量（内容为 0）时先给足剩余空间，不被压成 0")
    func unmeasuredGivesRoom() {
        #expect(PopoverLayout.listHeight(contentHeight: 0, chromeHeight: chrome, maxContentHeight: cap)
                == cap - chrome)
        // 固定部分异常大（例如日志面板展开）时仍有下限，避免 0 高度反复触发布局
        #expect(PopoverLayout.listHeight(contentHeight: 0, chromeHeight: 5000, maxContentHeight: cap)
                == PopoverLayout.minimumListHeight)
    }

    @Test("P5 面板上限 = 屏幕可见高度的 80%（真机 1126 → 901）")
    func capIsEightyPercent() {
        #expect(PopoverLayout.maxContentHeight(screenVisibleHeight: 1000) == 800)
        #expect(Int(PopoverLayout.maxContentHeight(screenVisibleHeight: 1126.5)) == 901,
                "与真机日志的「上限 901」一致")
    }

    @Test("P6 列表高度永不超过上限与内容高度两者（不变量）")
    func neverExceedsEither() {
        for content in stride(from: CGFloat(0), through: 3000, by: 250) {
            let h = PopoverLayout.listHeight(contentHeight: content,
                                             chromeHeight: chrome,
                                             maxContentHeight: cap)
            #expect(h <= cap - chrome, "列表不得把面板顶出上限")
            if content > 0 { #expect(h <= content, "内容装得下时不该被压缩") }
        }
    }
}
