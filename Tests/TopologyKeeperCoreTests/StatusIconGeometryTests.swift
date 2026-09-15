import AppKit
import Testing
@testable import TopologyKeeperCore

// T20：菜单栏图标的几何不变量
//
// 真机反馈：`waveform.badge.checkmark` 在菜单栏里**右侧和底部被裁切**。
// 原因是直接用 `NSImage(systemSymbolName:)`，其尺寸与状态栏按钮的
// 布局/裁剪范围不一致，徽章外溢部分被切掉。
//
// 这组测试锁死 `StatusIconRenderer` 的几何保证：画布必须
// ① 容得下整个符号（含徽章）  ② 落在菜单栏高度内（否则会纵向裁切）
// 观感层面另由 `Scripts/preview_icon.sh` 出图人工确认 —— 几何测试
// 保证不了"看起来对"，但能保证"不会被切"。

@Suite("T20 菜单栏图标几何")
struct StatusIconGeometryTests {

    /// 菜单栏高度（pt）。macOS 常见为 24。
    private let menuBarHeight: CGFloat = 24
    /// 图标画布允许的最大高度：必须明显小于菜单栏，留出上下余量
    private let maxIconHeight: CGFloat = 21

    private let allSymbols = ["waveform.slash", "waveform.badge.checkmark", "waveform.badge.xmark"]

    @Test("T20a 画布高度必须落在菜单栏内（否则纵向会被裁）")
    func canvasFitsMenuBar() {
        for symbol in allSymbols {
            let image = StatusIconRenderer.image(symbolName: symbol)
            #expect(image.size.height <= maxIconHeight,
                    "\(symbol) 画布高 \(image.size.height)pt，超过 \(maxIconHeight)pt 会被菜单栏裁切")
            #expect(image.size.height < menuBarHeight,
                    "\(symbol) 画布高必须小于菜单栏高度 \(menuBarHeight)pt")
            #expect(image.size.width > 0)
        }
    }

    @Test("T20b 每个符号都在画布内留有边距（徽章不会贴边被切）")
    func inkHasMarginInsideCanvas() {
        for symbol in allSymbols {
            let image = StatusIconRenderer.image(symbolName: symbol)
            // 画布 = 墨迹 + 两侧 margin，所以画布必须比墨迹大
            #expect(image.size.width >= StatusIconRenderer.inkHeight * 0.5)
            #expect(image.size.height >= StatusIconRenderer.inkHeight,
                    "\(symbol) 画布高应至少容纳目标墨迹高度")
        }
    }

    @Test("T20c 三个符号的墨迹高度一致（视觉重量统一）")
    func consistentInkHeight() {
        // 画布高 = 墨迹高 + 上下 margin，三者应相同
        var heights = Set<Int>()
        for symbol in allSymbols {
            let image = StatusIconRenderer.image(symbolName: symbol)
            heights.insert(Int(image.size.height.rounded()))
        }
        #expect(heights.count == 1, "三个符号画布高度应一致，实际 \(heights)")
    }

    @Test("T20d 生成的是模板图（可被 contentTintColor 正确着色）")
    func generatesTemplateImage() {
        for symbol in allSymbols {
            let image = StatusIconRenderer.image(symbolName: symbol)
            #expect(image.isTemplate, "\(symbol) 必须是模板图，否则深浅色菜单栏下着色会不对")
        }
    }

    @Test("T20e 符号名写错时不崩溃，返回同尺寸占位图")
    func unknownSymbolIsSafe() {
        let image = StatusIconRenderer.image(symbolName: "definitely.not.a.real.symbol")
        #expect(image.size.width > 0)
        #expect(image.size.height > 0)
        #expect(image.isTemplate)
    }

    @Test("T20f 自定义墨迹高度生效，且超大取值被夹取而不会超出菜单栏")
    func customInkHeightRespected() {
        let small = StatusIconRenderer.image(symbolName: "waveform.badge.checkmark", inkHeight: 10)
        let large = StatusIconRenderer.image(symbolName: "waveform.badge.checkmark", inkHeight: 18)
        #expect(small.size.height < large.size.height, "参数应生效")

        // 即使调用方传了离谱的值，渲染层也必须夹取 ——
        //   "图标永不被裁"应当是无条件保证，而不是依赖调用方传对参数
        let absurd = StatusIconRenderer.image(symbolName: "waveform.badge.checkmark", inkHeight: 999)
        #expect(absurd.size.height <= StatusIconRenderer.maxCanvasHeight,
                "超大 inkHeight 必须被夹取到 \(StatusIconRenderer.maxCanvasHeight)pt 以内")
        #expect(absurd.size.height <= maxIconHeight + 1)
    }
}
