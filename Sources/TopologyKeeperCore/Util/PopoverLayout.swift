import Foundation

/// 弹出面板的高度几何 —— **纯计算，不依赖 AppKit/SwiftUI**。
///
/// ## 为什么放在 Core
///
/// 与 `StatusIconRenderer` 同理：把"布局规则"从 UI 框架里剥出来，
/// 才能在**没有界面的环境**下验证它。首页「规则列表自适应、超过屏幕才滚动」
/// 的全部判据就集中在下面这一个函数里。
///
/// 这尤其重要，因为**本机只有 4 台音频设备**，永远到不了滚动阈值 ——
/// 靠手工点界面无法覆盖那条分支，只能靠单测钉住。
public enum PopoverLayout {

    /// 列表最少保留的高度。
    ///
    /// 用途：尚未测量完（`contentHeight <= 0`）或固定部分异常大时兜底，
    /// 避免算出 0 高度 → 触发下一轮布局 → 反复震荡。
    public static let minimumListHeight: CGFloat = 80

    /// 面板整体高度上限 = 屏幕**可见**高度 × 该比例（用户确认 80%）。
    ///
    /// 用可见高度（`visibleFrame`）而不是屏幕全高（`frame`）：
    /// 后者含菜单栏与 Dock，算出的上限偏大，面板会被它们遮挡。
    public static let maxScreenFraction: CGFloat = 0.8

    /// 由屏幕可见高度算出面板整体高度上限。
    public static func maxContentHeight(screenVisibleHeight: CGFloat) -> CGFloat {
        screenVisibleHeight * maxScreenFraction
    }

    /// 规则列表**应当取的确切高度**。
    ///
    /// * 内容不高 ⇒ 取**内容高度**（列表不滚动）
    /// * 内容过高 ⇒ 取**上限 − 固定部分**（列表滚动）
    /// * 尚未测量（`contentHeight <= 0`）⇒ 先给足剩余空间
    ///
    /// 这里刻意返回"确切高度"而非上限：早期版本写的是
    /// `ScrollView.frame(maxHeight: 内容高度)` 再给外层加 `maxHeight` 封顶，
    /// 指望弹性的 ScrollView 被外层压小 —— 实测**没生效**，
    /// 因为那条链要同时依赖 SwiftUI 的弹性分配与 NSPopover 的自动改尺寸。
    /// 一次算准就不必依赖它们。
    public static func listHeight(contentHeight: CGFloat,
                                  chromeHeight: CGFloat,
                                  maxContentHeight: CGFloat) -> CGFloat {
        let room = max(maxContentHeight - chromeHeight, minimumListHeight)
        guard contentHeight > 0 else { return room }
        return min(contentHeight, room)
    }

    /// 在该内容高度下列表是否需要滚动（等价于"面板是否已顶到上限"）。
    public static func needsScrolling(contentHeight: CGFloat,
                                      chromeHeight: CGFloat,
                                      maxContentHeight: CGFloat) -> Bool {
        contentHeight > listHeight(contentHeight: contentHeight,
                                   chromeHeight: chromeHeight,
                                   maxContentHeight: maxContentHeight)
    }
}
