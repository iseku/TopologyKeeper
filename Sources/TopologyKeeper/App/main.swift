import AppKit
import Foundation
import TopologyKeeperCore

// 应用入口。
//
// 刻意**不用** SwiftUI 的 `@main App` 场景：
// 菜单栏应用需要完全控制 `NSStatusItem` 与激活策略，
// 直接用 `NSApplication` + `AppDelegate` 更直接，也避免 SwiftUI 场景
// （如 Settings 菜单项）与自建窗口重复。
//
// `LSUIElement=true`（见 Resources/Info.plist）使应用不出现在 Dock。
// 这里再显式设一次 `.accessory` 作为双保险。

// 日志先配好（含 stderr 回显），这样"被单实例保护拦下"这件事也能被记录与观察
Log.shared.configure(capacity: 800, echoToStderr: true)

// ── 单实例保护 ────────────────────────────────────────────────
// 必须在任何 UI / 引擎初始化**之前**判断。
// 实测 bug：开启「开机自动启动」时 `launchctl bootstrap` 会让 launchd
// 立刻再启动一个实例（因为 plist 里 RunAtLoad=true），用户就看到两个实例。
guard SingleInstanceGuard.acquire() else {
    Log.warn("已有实例在运行 —— 本次启动被单实例保护拦下，退出。")
    // 配置尚未加载，此时文件日志还没开；直接落盘留痕，否则无法排查
    Log.appendDirect(.warn, "已有实例在运行 —— 本次启动被单实例保护拦下，退出（PID \(getpid())）")
    FileHandle.standardError.write(
        Data("TopologyKeeper 已在运行，本次启动退出。\n".utf8))
    SingleInstanceGuard.activateExistingInstance()
    exit(0)
}

// 成为唯一实例后恢复正常日志配置（不再往 stderr 回显）
Log.shared.configure(capacity: 800, echoToStderr: false)
Log.info("TopologyKeeper 获得单实例锁")

let application = NSApplication.shared

let appDelegate = AppDelegate()
application.delegate = appDelegate
application.setActivationPolicy(.accessory)
application.run()
