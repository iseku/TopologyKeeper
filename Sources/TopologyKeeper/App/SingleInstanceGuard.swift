import AppKit
import Darwin
import Foundation

/// 单实例保护。
///
/// ## 为什么必须有
/// 实测 bug：在设置里打开「开机自动启动」后**又冒出一个实例**。
/// 原因是安装 LaunchAgent 时会执行 `launchctl bootstrap`，
/// 而 plist 里 `RunAtLoad=true` —— launchd 会立刻把 App 再启动一遍。
///
/// 单实例保护是**根治手段**，因为重复启动的来源不止一个：
/// * LaunchAgent 的 `RunAtLoad` 立即加载
/// * 登录时 LaunchAgent 启动，而用户又手动打开了一次
/// * 用户把 App 放在两个位置各点了一次
///
/// ## 实现
/// 用 `flock` 对 `~/Library/Application Support/TopologyKeeper/instance.lock`
/// 加**非阻塞独占锁**。进程退出时内核自动释放，不存在陈旧锁问题。
///
/// 刻意不依赖 `NSRunningApplication`：文件锁与 LaunchServices 状态无关，
/// 更确定，也不受 ad-hoc 签名/bundle 路径差异影响。
enum SingleInstanceGuard {

    /// 尝试成为唯一实例。
    /// - Returns: `true` = 本进程是唯一实例，可以继续；
    ///            `false` = 已有实例在运行，本进程应退出。
    static func acquire() -> Bool {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TopologyKeeper", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)

        let path = directory.appendingPathComponent("instance.lock").path
        let descriptor = open(path, O_CREAT | O_RDWR, 0o644)

        // 打不开锁文件时**放行**：不能因为锁机制本身的问题让 App 起不来
        guard descriptor >= 0 else { return true }

        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            // 刻意**不关闭** descriptor：锁一直持有到进程退出，
            // 内核会自动释放，因此不存在陈旧锁问题。
            // 也因此不需要保存 fd 到任何全局状态里。
            return true
        }

        close(descriptor)
        return false
    }

    /// 把已在运行的实例带到前台（菜单栏应用没有窗口，这里主要是激活它）。
    static func activateExistingInstance() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let currentPID = getpid()
        for application in NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
        where application.processIdentifier != currentPID {
            application.activate(options: [])
        }
    }
}
