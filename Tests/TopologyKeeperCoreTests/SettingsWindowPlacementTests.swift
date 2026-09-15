import CoreGraphics
import Testing
@testable import TopologyKeeperCore

// 设置窗口摆位的几何规则（用户三次实测反馈的产物）。
//
// 为什么必须有单测：本机**无法**用脚本点开设置窗口
// （点菜单栏图标需要辅助功能权限，`osascript` 会报 -10004 权限违例），
// 所以"窗口到底摆哪儿"没法用自动化界面操作验证 —— 只能把几何抽成纯函数钉住。
//
// 位置演进：
//   ① window.center()  → 与图标完全脱钩
//   ② 居中于图标        → ✅ 水平方向用户确认就是这个
//   ③ 居中于屏幕        → ❌ 误解，已撤回（W2 挡住它复活）
//   ④ 坐标系搞反        → ❌ 垂直把窗口甩到屏幕下方（W4/W5/W6 挡住它复活）
//
// 坐标系：**top-left 原点、y 向下增长**（与 NSWindow.frame / NSScreen.visibleFrame
// 一致）。下面所有数字都取自真机诊断日志的实测值。

@Suite("W 设置窗口摆位几何")
struct SettingsWindowPlacementTests {

    // MARK: 真机夹具（数值来自诊断日志）

    /// 屏幕可见区域实测 (55, 0, 1993, 1127)：顶边 y=0，底边 y=1127（向下增长）
    private let visible = CGRect(x: 55, y: 0, width: 1993, height: 1127)
    /// 菜单栏图标实测 frame=(1231, 1129, 25, 22) —— 注意它在可见区域**之上**
    private let icon = CGRect(x: 1231, y: 1129, width: 25, height: 22)
    /// 设置窗口实测 frame 尺寸 500×638（内容 500×600 + 标题栏）
    private let windowSize = CGSize(width: 500, height: 638)

    private func place(size: CGSize? = nil,
                       screen: CGRect? = nil,
                       iconFrame: CGRect? = nil) -> CGPoint {
        SettingsWindowPlacement.origin(windowSize: size ?? windowSize,
                                       screenVisibleFrame: screen ?? visible,
                                       iconFrame: iconFrame ?? icon)
    }

    // MARK: 水平

    @Test("W1 水平居中于图标（窗口跟着图标走）")
    func centersHorizontallyOnIcon() {
        let origin = place()
        let midX = origin.x + windowSize.width / 2
        #expect(abs(midX - icon.midX) < 0.5,
                "窗口水平中心应落在图标中心（实际 \(midX)，图标 \(icon.midX)）")
        #expect(abs(origin.x - 993.5) < 0.5)      // 1243.5 − 250
    }

    @Test("W2 不是居中于屏幕（挡住'又改回屏幕居中'这个误解）")
    func isNotCenteredOnScreen() {
        let screenCenteredX = visible.midX - windowSize.width / 2      // 996.5
        // 图标在 1243.5、屏幕中心 1051.5 —— 两者只差 192pt，故阈值取 150
        #expect(place().x > screenCenteredX + 150,
                "图标在右侧 ⇒ 窗口应贴图标，而不是屏幕正中（实际 \(place().x)）")
    }

    @Test("W3 图标水平移动，窗口跟着移动相同距离")
    func followsIconHorizontally() {
        let a = place()
        let b = place(iconFrame: icon.offsetBy(dx: -300, dy: 0))
        #expect(abs((a.x - b.x) - 300) < 0.5, "图标左移 300，窗口也该左移 300")
        #expect(a.y == b.y, "同一行的图标，垂直位置应一致")
    }

    // MARK: 垂直（坐标系陷阱的回归防线）

    @Test("W4 垂直：顶边贴图标下沿（y 向上增长 ⇒ 减高度，不是加）")
    func sitsJustBelowStatusItem() {
        // 图标下沿 = minY = 1129；顶边 = 1129 − 4 = 1125；底边 = 1125 − 638 = 487。
        // 窗口占据 y 487…1125，正好铺在图标正下方、可见区之上。
        let expected = icon.minY - SettingsWindowPlacement.gap - windowSize.height   // 487
        #expect(place().y == expected,
                "窗口底边应为 \(expected)（实际 \(place().y)）")
        let top = place().y + windowSize.height
        #expect(abs(top - (icon.minY - SettingsWindowPlacement.gap)) < 0.5,
                "窗口顶边应比图标下沿低 4pt（实际 \(top)，图标下沿 \(icon.minY)）")
        // 实测坐标（诊断日志）：图标 y=1129 ⇒ 窗口占 y 487…1125
        #expect(place().y == 487,
                "本机真机坐标：窗口底边应为 487（实际 \(place().y)）")
        #expect(place().y > 0, "窗口必须完全落在可见区域内、而不是溢到屏幕下方")
    }

    @Test("W5 可见区域不够高时，底边被抬回可见区域（不压住 Dock）")
    func neverSinksBelowVisibleArea() {
        // 普通 600 高窗口：顶边 1125、底边 525 —— 远高于可见区底边 0，无需夹紧
        let normal = CGSize(width: 500, height: 600)
        #expect(place(size: normal).y == icon.minY - SettingsWindowPlacement.gap - normal.height)
        // 超矮可见区（只有 400 高）+ 300 高窗口：底边会算到 (−) 而被抬回 0
        // 图标在 402（桌面底部 Dock 之上），窗口高 300：
        // 直接算会得到 402 − 4 − 300 = 98，尚在可见区域 [0,400] 内 ⇒ 不夹紧
        let tiny = CGRect(x: 0, y: 0, width: 1280, height: 400)
        let origin = place(size: CGSize(width: 500, height: 300), screen: tiny,
                           iconFrame: CGRect(x: 900, y: 402, width: 25, height: 22))
        #expect(origin.y == 402 - SettingsWindowPlacement.gap - 300)
        #expect(origin.y >= tiny.minY, "底边不得沉到可见区域之下")
        #expect(origin.y + 300 <= tiny.maxY + 0.5, "顶边不得越出可见区域")
    }

    @Test("W6 窗口比可见区域还高时，顶部优先可见（顶边不越出可见区）")
    func clampsWithTopPriorityWhenTallerThanScreen() {
        let tall = CGSize(width: 500, height: 1400)     // 可见区域高 1127
        let origin = place(size: tall)
        // 顶边 = 1127（可见区顶边），底边 = 1127 − 1400 = −273（允许溢出到 Dock 之下）
        #expect(origin.y + tall.height == visible.maxY,
                "顶边应钉在可见区域顶边（实际 \(origin.y + tall.height)，顶边 \(visible.maxY)）")
        #expect(origin.y < visible.minY, "底边允许溢出到可见区域下方")
    }

    // MARK: 边缘与多屏

    @Test("W7 窗口比可见区域还宽时仍保证左边可见")
    func clampsWhenWindowWiderThanScreen() {
        #expect(place(size: CGSize(width: 3000, height: 600)).x == visible.minX)
    }

    @Test("W8 图标贴屏幕左边缘时窗口被夹紧，整窗可见")
    func clampsAtLeftEdge() {
        let origin = place(iconFrame: CGRect(x: 57, y: 1129, width: 25, height: 22))
        #expect(origin.x == visible.minX)
        #expect(origin.x + windowSize.width <= visible.maxX)
    }

    @Test("W9 小屏幕上仍居中于图标")
    func centersOnSmallScreen() {
        let small = CGRect(x: 0, y: 0, width: 1280, height: 800)
        let smallIcon = CGRect(x: 900, y: 802, width: 25, height: 24)
        let origin = place(size: CGSize(width: 500, height: 600),
                           screen: small, iconFrame: smallIcon)
        #expect(abs(origin.x + 250 - smallIcon.midX) < 0.5)
    }

    // MARK: 极端情况：图标位置可变，弹窗绝不能跑到屏幕外

    @Test("W11 扫描所有图标位置 × 窗口宽度：左右边界绝不越出屏幕")
    func horizontalBoundsHoldAcrossAllIconPositions() {
        // 状态栏图标会随其它菜单栏项目增减而左右移动（用户提出的关注点）。
        // 这里穷举图标位置（含贴两端、甚至完全越出可见区）与窗口宽度，
        // 逐点验证"左边界在屏内"这条不变量 —— 靠人工点界面不可能覆盖这些组合。
        let widths: [CGFloat] = [380, 500, 760, 1400, 1993, 2200]   // 含超宽（> 可见区）
        let iconXs: [CGFloat] = [10, 55, 200, 800, 1243, 1900, 2030, 2100, 3000]

        for width in widths {
            for iconX in iconXs {
                let icon = CGRect(x: iconX, y: 1129, width: 25, height: 22)
                let origin = SettingsWindowPlacement.origin(
                    windowSize: CGSize(width: width, height: 600),
                    screenVisibleFrame: visible, iconFrame: icon)

                // ① 左边界必须留在可见区域内（否则整窗跑到屏幕外）
                #expect(origin.x >= visible.minX - 0.5,
                        "w=\(width) iconX=\(iconX)：左边界 \(origin.x) 跑到屏幕左边外")
                // ② 左边界不得越过可见区域右边界
                #expect(origin.x <= visible.maxX + 0.5,
                        "w=\(width) iconX=\(iconX)：左边界 \(origin.x) 跑到屏幕右边外")
                // ③ 装得下时，右边界也必须在屏内
                if width <= visible.width {
                    #expect(origin.x + width <= visible.maxX + 0.5,
                            "w=\(width) iconX=\(iconX)：右边界 \(origin.x + width) 越界")
                }
            }
        }
    }

    @Test("W12 窗口比可见区域还宽：保证左边界，不整体推出去")
    func oversizedWindowKeepsLeftEdgeOnScreen() {
        let oversized = CGSize(width: 2200, height: 600)      // 可见区宽 1993
        for iconX: CGFloat in [55, 1000, 2030] {
            let origin = place(size: oversized,
                               iconFrame: CGRect(x: iconX, y: 1129, width: 25, height: 22))
            #expect(origin.x == visible.minX,
                    "超宽窗口应从可见区左边界开始（iconX=\(iconX) 时得 \(origin.x)）")
        }
    }

    @Test("W13 进度边界：窗口宽度正好等于可见区宽度")
    func widthExactlyEqualToVisibleArea() {
        let exact = CGSize(width: visible.width, height: 600)
        // 图标在极右：居中会把窗口推到屏外，夹紧后必须正好铺满可见区
        let origin = place(size: exact,
                           iconFrame: CGRect(x: 2030, y: 1129, width: 25, height: 22))
        #expect(origin.x == visible.minX, "应正好铺满可见区（实际 \(origin.x)）")
        #expect(origin.x + exact.width == visible.maxX)
    }

    @Test("W10 副屏（坐标带偏移）以**该屏**图标为基准")
    func centersOnSecondaryScreenIcon() {
        // 副屏在主屏右侧；图标取在副屏中部（不触发水平夹紧）
        let secondary = CGRect(x: 2048, y: 0, width: 1920, height: 1000)
        let secondaryIcon = CGRect(x: 3000, y: 1002, width: 25, height: 24)
        let origin = place(size: CGSize(width: 500, height: 600),
                           screen: secondary, iconFrame: secondaryIcon)
        // 1920 无法被 500 整除，居中后两侧各差约 2pt
        #expect(abs(origin.x + 250 - secondaryIcon.midX) < 2.5)
    }
}
