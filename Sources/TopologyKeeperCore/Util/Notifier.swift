import Foundation
import UserNotifications

/// 系统通知。
///
/// 设计取舍（《详细设计.md》§15 O5）：
/// 本机**没有代码签名身份**，`UNUserNotificationCenter` 在这种环境下
/// 可能直接失败。因此这里的策略是**试一次、失败就静默降级**为
/// 仅菜单栏状态提示，绝不因为通知不可用而影响核心功能。
///
/// 另外注意：`UNUserNotificationCenter.current()` 在**没有 bundle identifier**
/// 的进程里（例如 CLI 工具）会崩溃，所以必须先做可用性判断。
public final class Notifier: @unchecked Sendable {

    public enum Availability: Equatable, Sendable {
        case unknown
        case available
        case unavailable(reason: String)

        public var displayText: String {
            switch self {
            case .unknown:                  return "未确定"
            case .available:                return "可用"
            case .unavailable(let reason):  return "不可用：\(reason)"
            }
        }
    }

    private let lock = NSLock()
    private var _availability: Availability = .unknown
    private var authorized = false

    public var availability: Availability {
        lock.lock(); defer { lock.unlock() }
        return _availability
    }

    public init() {}

    /// 是否具备使用通知的基本条件（有 bundle id 且能拿到 center）
    private var hasBundleIdentity: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    /// 请求授权。**只调用一次**；失败不抛错，只记录状态。
    public func requestAuthorizationIfNeeded() {
        guard hasBundleIdentity else {
            setAvailability(.unavailable(reason: "进程没有 bundle identifier"))
            return
        }
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]) { [weak self] granted, error in
                guard let self else { return }
                if let error {
                    self.setAvailability(.unavailable(reason: error.localizedDescription))
                    Log.warn("通知授权失败，将降级为仅菜单栏提示：\(error.localizedDescription)")
                } else if granted {
                    self.setAvailability(.available)
                    self.lock.lock(); self.authorized = true; self.lock.unlock()
                    Log.info("通知已授权")
                } else {
                    self.setAvailability(.unavailable(reason: "用户未授权"))
                    Log.info("用户未授权通知，降级为仅菜单栏提示")
                }
            }
    }

    private func setAvailability(_ value: Availability) {
        lock.lock(); _availability = value; lock.unlock()
    }

    /// 发送通知。不可用时**静默忽略**（调用方无需判断）。
    public func post(title: String, body: String, identifier: String = UUID().uuidString) {
        guard hasBundleIdentity else { return }
        lock.lock()
        let ready = authorized
        let availability = _availability
        lock.unlock()

        guard ready, case .available = availability else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = nil                       // 音频工具，别用提示音打扰

        let request = UNNotificationRequest(identifier: identifier,
                                            content: content,
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Log.warn("通知发送失败：\(error.localizedDescription)")
            }
        }
    }

    // MARK: - 语义化封装

    public func notifyLocked(deviceName: String, preset: String) {
        post(title: "已锁定 \(deviceName)",
             body: "格式已恢复为 \(preset)",
             identifier: "locked-\(deviceName)")
    }

    public func notifyFailed(deviceName: String, reason: String) {
        post(title: "\(deviceName) 锁定失败",
             body: reason,
             identifier: "failed-\(deviceName)")
    }
}
