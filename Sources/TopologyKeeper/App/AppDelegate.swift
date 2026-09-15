import AppKit
import Foundation
import TopologyKeeperCore

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var environment: AppEnvironment?
    private var appState: AppState?
    private var statusBar: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("TopologyKeeper 启动")

        let environment = AppEnvironment()
        let appState = AppState(environment: environment)

        self.environment = environment
        self.appState = appState
        self.statusBar = StatusBarController(appState: appState)

        appState.start()
        logEnvironmentSummary()

        // ★ 监听"外部进程改了配置"（如 `tkctl mix/swap`），收到就重新加载并重新应用。
        //
        //   为什么需要：App 只在启动时读一次配置并缓存在内存里，外部直接写
        //   UserDefaults 时它毫无察觉，会继续按旧配置跑 ——
        //   现象是"CLI 显示改了、App 行为没变"，本会话为此绕了很久。
        //   （GUI 改配置走 `update`，所以一直不受影响。）
        //
        //   ⚠️ 闭包是 @Sendable / nonisolated，而 AppState 是主线程隔离的
        //   ⇒ 必须 `Task { @MainActor in ... }` 跳回去。先前写成直接调用：
        //      既编译告警，**实际也毫无反应**（通知发了但没有任何日志）。
        //   这里也不在闭包里捕获 self，避免 Sendable 告警。
        DistributedNotificationCenter.default().addObserver(
            forName: ConfigStore.externalChangeNotification,
            object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                guard let delegate = NSApp.delegate as? AppDelegate,
                      let state = delegate.appState else { return }
                let changed = delegate.environment?.store.reloadFromDefaults() ?? false
                Log.info("收到外部配置变更通知（changed=\(changed)），重新应用交换/混音")
                state.reapplyChannelSwap()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.info("TopologyKeeper 退出")
        appState?.stop()
    }

    /// 启动时把环境信息写进日志 —— 排查问题时这些信息很关键
    private func logEnvironmentSummary() {
        guard let environment else { return }
        let devices = environment.listOutputDevices()
        Log.info("系统输出设备共 \(devices.count) 台")
        for device in devices {
            let capability = environment.capability(forUID: device.uid)
            Log.info("  · \(device.displayName) | \(capability.summary)")
        }
        let rules = environment.store.config.rules
        if rules.isEmpty {
            Log.info("尚无规则 —— 打开设置添加")
        } else {
            for rule in rules {
                Log.info("  规则：\(rule.deviceName) → \(rule.preset.compactString)"
                         + "（\(rule.conflictPolicy.displayText)）")
            }
        }
    }
}
