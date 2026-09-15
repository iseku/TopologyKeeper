import AppKit

/// 菜单栏图标渲染。
///
/// ## 为什么不能直接用 `NSImage(systemSymbolName:)`
/// 真机实测：`waveform.badge.checkmark` 直接用会**右侧和底部被裁切**。
/// 原因是带徽章（badge）的 SF Symbol，其 `size` 与状态栏按钮实际布局/裁剪
/// 的范围不一致 —— 徽章外溢的部分会被切掉。
///
/// ## 做法：自己控制画布
/// 把符号**等比缩放后居中画进一个固定尺寸的画布**：
/// * 画布尺寸由我们决定，必然落在菜单栏高度内 → 不会纵向裁切
/// * 符号四周留出边距 → 徽章不可能越界
/// * 三个符号按**统一墨迹高度**缩放 → 视觉重量一致
///
/// 之所以用 `draw(in:)` 而不是先缩成位图再画：SF Symbol 是矢量，
/// 直接画进目标矩形会按目标尺寸光栅化，不会糊。
///
/// 本类型刻意**只依赖 AppKit、不依赖 Core 的其它类型** ——
/// 这样它可以被单独编译进预览工具做视觉校验（见 `Scripts/preview_icon.sh`），
/// 同时放在 Core 里又能被单元测试覆盖几何不变量（T20）。
public enum StatusIconRenderer {

    /// 目标墨迹高度（pt）。菜单栏高 24pt，留足上下余量。
    public static let inkHeight: CGFloat = 15
    /// 画布四周留白（pt）
    public static let margin: CGFloat = 2

    /// 画布高度上限（pt）。菜单栏高 24pt，留 2pt 余量，
    /// 超过这个高度的图标会被菜单栏纵向裁切 —— 因此在渲染层**强制夹取**，
    /// 让"图标永远不会被裁"成为无条件保证，而不依赖调用方传对参数。
    public static let maxCanvasHeight: CGFloat = 22

    /// 生成菜单栏图标。
    /// - Parameter symbolName: SF Symbol 名（由 `LockState.iconName` 提供）
    /// - Returns: 模板图（`isTemplate = true`），着色交给 `contentTintColor`
    public static func image(symbolName: String,
                             inkHeight requestedInkHeight: CGFloat = StatusIconRenderer.inkHeight) -> NSImage {
        // 夹取，保证画布永不超出菜单栏
        let inkHeight = min(requestedInkHeight, maxCanvasHeight - margin * 2)
        let configuration = NSImage.SymbolConfiguration(pointSize: inkHeight, weight: .regular)
        let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)

        guard let symbol, symbol.size.height > 0, symbol.size.width > 0 else {
            // 符号不存在时给一个占位，避免菜单栏出现空白（名字写错会静默变空）
            let placeholder = NSImage(size: NSSize(width: inkHeight, height: inkHeight))
            placeholder.isTemplate = true
            return placeholder
        }

        // 等比缩放到统一墨迹高度
        let scale = inkHeight / symbol.size.height
        let scaled = NSSize(width: (symbol.size.width * scale).rounded(),
                            height: (symbol.size.height * scale).rounded())
        let canvas = NSSize(width: scaled.width + margin * 2,
                            height: scaled.height + margin * 2)

        let image = NSImage(size: canvas)
        image.lockFocus()
        symbol.draw(in: NSRect(x: margin, y: margin,
                               width: scaled.width, height: scaled.height),
                    from: .zero, operation: .sourceOver, fraction: 1.0)
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    /// 诊断用：返回画布尺寸描述
    public static func describe(symbolName: String, inkHeight: CGFloat = StatusIconRenderer.inkHeight) -> String {
        let image = self.image(symbolName: symbolName, inkHeight: inkHeight)
        return String(format: "%-26@ 画布 %.0fx%.0f pt",
                      symbolName as NSString, image.size.width, image.size.height)
    }
}
