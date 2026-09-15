import AppKit
import SwiftUI
import TopologyKeeperCore

/// 菜单栏图标与弹出面板管理。
@MainActor
final class StatusBarController: NSObject {

    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let appState: AppState
    private var cancellable: Any?
    private weak var settingsWindow: NSWindow?

    /// 设置窗口的**内容**尺寸，同时也是最小尺寸
    /// （SwiftUI 侧用同样的下限：`SettingsRootView` 里 `.frame(minWidth: 500, minHeight: 600)`）。
    ///
    /// 取值演进：原 720×560 → 432×560（用户实测**偏窄**）→ **500×600**（当前）。
    static let settingsInitialSize = CGSize(width: 500, height: 600)

    /// 摆位用的窗口 **frame** 尺寸 —— 含标题栏，可直接用于几何计算。
    ///
    /// 为什么不再运行时去读 `window.frame` / 做 `contentRect(forFrameRect:)` 换算：
    /// 宽度与 `settingsInitialSize` 相同（标题栏不影响宽度），高度是内容高度
    /// 加一个标题栏。而那次换算**本身是错的**：实测它给出 562，而 AppKit
    /// 显示后的真实 frame 是 638 —— 差值恰好 `2 × 38`，说明标题栏被算了两遍
    /// （该 API 在 `contentViewController` 赋值之后调用时如此）。
    /// 用错的尺寸算位置，就是"窗口先出现在屏幕下方再跳上来"那个闪动的来源。
    ///
    /// ⇒ 既然是常量且 SwiftUI 侧有同样的最小尺寸约束，就直接写死这个常量，
    ///   打开时不做任何尺寸读取。
    /// ⚠️ 改动 `settingsInitialSize` 或窗口样式（加工具栏等）时必须同步这里。
    static let settingsFrameSize = CGSize(width: 500, height: 638)

    init(appState: AppState) {
        self.appState = appState
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        configureStatusItem()
        configurePopover()
        observeState()
    }

    // MARK: - 图标

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.action = #selector(togglePopover(_:))
        button.target = self
        applyIcon()
    }

    /// 三个符号 + 三种着色，随状态动态切换。
    /// * 已锁定 → waveform.badge.checkmark（正常色）
    /// * 失败   → waveform.badge.xmark（红）
    /// * 其余   → waveform.slash（过渡态橙、其余正常色）
    ///
    /// 渲染交给 `StatusIconRenderer`：真机实测直接用
    /// `NSImage(systemSymbolName:)` 会让带徽章的符号**右侧和底部被裁切**，
    /// 因此改为自己控制画布（详见该类型的说明）。
    private func icon(for state: LockState) -> NSImage {
        StatusIconRenderer.image(symbolName: state.iconName)
    }

    private func tintColor(for state: LockState) -> NSColor? {
        switch state.statusTint {
        case .normal:     return nil                    // 跟随菜单栏外观
        case .inProgress: return .systemOrange
        case .critical:   return .systemRed
        }
    }

    private func applyIcon() {
        guard let button = statusItem.button else { return }
        let state = appState.aggregateState
        button.image = icon(for: state)
        // 图标语义仍由**格式锁定**规则决定（既有行为不变）；
        // 但声道交换若需要关注（重试耗尽/出错），用红色着色提示 ——
        // 它没有独立的菜单栏图标，否则用户无从察觉。
        button.contentTintColor = appState.swapState.needsAttention
            ? .systemRed
            : tintColor(for: state)
        button.toolTip = "TopologyKeeper — \(appState.statusSummary)\(channelProcessingToolTipSuffix)"
    }

    /// 声道处理的附加提示（仅在启用或有异常时出现）
    ///
    /// 按**当前生效的模式**取名与取文案：交换与混音共用通路，
    /// 一律写"声道交换：交换中"会在开混音时误导用户；
    /// 直通模式下则说"声道处理：直通中"（它没有具体功能名）。
    private var channelProcessingToolTipSuffix: String {
        let diag = appState.swapDiagnostics
        guard diag.state != .disabled else { return "" }
        let title = diag.activeFunction == .passThrough
            ? "声道处理"
            : diag.activeFunction.displayName
        return "\n\(title)：\(diag.statusText)"
    }

    private func observeState() {
        // 用 Combine 订阅 @Published
        cancellable = appState.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshStatusItem()
                // ★ 数据变化（增删规则 → 列表行数变化）后也要重新同步面板尺寸。
                //   双保险：SwiftUI 侧的 onLayoutChange 在测量稳定后回调，
                //   这里在数据变化后兜一次，避免任一条路径遗漏。
                if self.popover.isShown { self.syncPopoverSize() }
            }
        }
    }

    private func refreshStatusItem() {
        applyIcon()
    }

    // MARK: - 弹出面板

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = NSHostingController(
            rootView: PopoverRootView(state: appState,
                                      onOpenSettings: { [weak self] in
                                          self?.openSettings()
                                      },
                                      onLayoutHeightChange: { [weak self] height in
                                          // 内容尺寸变了（增删规则、日志面板展开…）
                                          // ⇒ 让 popover 跟着改尺寸
                                          self?.applyPopoverHeight(height)
                                      }))
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        appState.refreshFromEngine()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        syncPopoverSize()
    }

    /// 按 SwiftUI 侧算出的内容高度设置面板尺寸。
    ///
    /// 用于**内容变化**的场景（增删规则、展开日志面板…）——
    /// `NSPopover` 不会自动跟随内容改尺寸，所以每次变化都要显式设置一次。
    private func applyPopoverHeight(_ height: CGFloat) {
        guard popover.isShown, height > 0 else { return }
        let width = popover.contentSize.width > 0 ? popover.contentSize.width : 380
        guard abs(height - popover.contentSize.height) > 0.5 else { return }
        // 延后一拍再设：本回调发生在 SwiftUI 测量之后、布局提交之前，
        // 立刻改窗口尺寸会与正在进行的布局打架。
        DispatchQueue.main.async { [weak self] in
            guard let self, self.popover.isShown else { return }
            self.popover.contentSize = NSSize(width: width, height: height)
        }
    }

    /// 把弹出面板的尺寸同步为 SwiftUI 内容的**实际拟合尺寸**（打开面板时用）。
    private func syncPopoverSize() {
        guard let host = popover.contentViewController else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.popover.isShown else { return }
            let fitting = host.view.fittingSize
            guard fitting.height > 0 else { return }
            if abs(fitting.height - self.popover.contentSize.height) > 0.5
                || abs(fitting.width - self.popover.contentSize.width) > 0.5 {
                self.popover.contentSize = fitting
            }
        }
    }

    // MARK: - 设置窗口

    func openSettings() {
        popover.performClose(nil)
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        // 尺寸：初始即按**新的最小尺寸**打开，便于直接评估窄版布局效果。
        // `.resizable` 此前缺失 —— 窗口根本无法调整大小。
        // 尺寸**不落盘**（未设 frameAutosaveName），符合"调整后不保留"的要求：
        // 本次运行内保留，退出后下次仍是初始尺寸。
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0,
                                width: Self.settingsInitialSize.width,
                                height: Self.settingsInitialSize.height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "TopologyKeeper 设置"
        window.contentViewController = NSHostingController(
            rootView: SettingsRootView(state: appState))
        window.isReleasedWhenClosed = false
        settingsWindow = window
        // 用**常量**尺寸先把位置摆好（此时还不可见）
        positionBelowStatusItem(window, frameSize: Self.settingsFrameSize)

        // ⚠️★ 关键：**先隐藏着显示**，等 AppKit 定完尺寸、位置确认无误，
        // 再让它可见 —— 这样任何尺寸/位置修正都发生在用户看到窗口之前。
        //
        // 为什么需要这一层保护：`makeKeyAndOrderFront` 之前窗口尺寸是
        // `1×66` 的占位值、显示之后 AppKit 才按内容撑开。实测正是这个过程
        // 让窗口先出现在屏幕下方、再跳上来（用户报的闪动）。
        // 位置虽已按常量尺寸 `settingsFrameSize` 算准，但保留一个不可见的
        // 兜底校准窗口期，代价为零、却能吸收任何尺寸偏差。
        //
        // 实测（临时诊断日志，已按用户要求清理）：两条摆位记录相隔一个 runloop
        // （21:49:47.349 → .377），期间窗口一直不可见，用户看到的就是校准后的最终位置。
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        calibrateSettingsWindowPosition(window)
    }

    /// 把设置窗口摆在**菜单栏图标正下方、水平居中对齐该图标**。
    ///
    /// 几何计算全部在 `SettingsWindowPlacement`（Core，纯函数、有单测）里：
    /// 本机无法用脚本点开设置窗口（菜单栏交互需要辅助功能权限），
    /// 所以这条布局规则只能靠单测钉住。
    ///
    /// - Parameter frameSize: 窗口 **frame** 尺寸（含标题栏），由调用方以常量传入。
    ///   ⚠️ 不要在这里读 `window.frame.size`、也不要用 `contentRect(forFrameRect:)`：
    ///   实测两者都不可靠（前者是 1×66 的占位值，后者会把标题栏算两遍得到 562，
    ///   而真实 frame 是 638）。见 `settingsFrameSize` 的说明。
    /// 取不到图标时（异常情况）退回 `window.center()`。
    private func positionBelowStatusItem(_ window: NSWindow, frameSize: CGSize) {
        guard let button = statusItem.button,
              let buttonWindow = button.window else {
            window.center()                       // 取不到图标（异常情况）时退回居中
            return
        }

        let iconFrame = buttonWindow.convertToScreen(
            button.convert(button.bounds, to: nil))
        // 优先用图标所在屏幕（多屏时不要把窗口摆到另一块屏上）
        let screen = buttonWindow.screen ?? NSScreen.main
        guard let screen else {
            window.center()
            return
        }

        let origin = SettingsWindowPlacement.origin(
            windowSize: frameSize,
            screenVisibleFrame: screen.visibleFrame,
            iconFrame: iconFrame)
        window.setFrameOrigin(origin)
    }

    /// 窗口**显示之后**用真实尺寸校准位置，然后把它显示出来。
    ///
    /// ⚠️ 为什么需要校准：窗口刚创建时 `window.frame` 还是占位值
    /// （诊断实测 `1×66`），AppKit 要到 `makeKeyAndOrderFront` 之后才按内容
    /// 把尺寸撑成 `500×638`。尺寸一变，之前算好的原点就不再等于"图标正下方"。
    /// 所以在下一个 runloop（布局已提交）用**真实 frame 尺寸**重算一次。
    ///
    /// ★ 校准必须在窗口**不可见**（`alphaValue == 0`）时完成 —— 否则用户会看到
    /// 窗口从"按估算尺寸算出的位置"跳到正确位置（实测到的那个闪动）。
    private func calibrateSettingsWindowPosition(_ window: NSWindow) {
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            defer { window.alphaValue = 1 }        // 无论走哪条分支，都必须露面

            guard let button = self.statusItem.button,
                  let buttonWindow = button.window,
                  let screen = buttonWindow.screen ?? NSScreen.main else {
                window.center()
                return
            }

            let iconFrame = buttonWindow.convertToScreen(
                button.convert(button.bounds, to: nil))
            let origin = SettingsWindowPlacement.origin(
                windowSize: window.frame.size,          // ← 此刻已是真实尺寸
                screenVisibleFrame: screen.visibleFrame,
                iconFrame: iconFrame)
            window.setFrameOrigin(origin)
        }
    }
}
