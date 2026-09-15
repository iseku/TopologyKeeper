import Foundation
import Security
import ServiceManagement

/// 开机自启动。
///
/// 设计：
/// 本机**没有代码签名身份**，`SMAppService` 已知会报 "Operation not permitted"。
/// 因此：
/// * 有有效签名（含 team identifier）→ 用 `SMAppService`（官方推荐）
/// * 无签名 → 用**手写 LaunchAgent plist** 兜底（免费且可行）
///
/// 两种模式对用户透明，但 UI 必须**如实标注**当前用的是哪种。
public enum LaunchAtLoginMode: Equatable, Sendable {
    case smAppService
    case launchAgent
    case unavailable(reason: String)

    public var displayText: String {
        switch self {
        case .smAppService:            return "SMAppService（已签名）"
        case .launchAgent:             return "LaunchAgent（未签名）"
        case .unavailable(let reason): return "不可用：\(reason)"
        }
    }
}

public final class LaunchAtLoginManager: @unchecked Sendable {

    public static let agentLabel = "com.iseku.topologykeeper"

    private let executablePathOverride: String?
    private let plistURLOverride: URL?
    /// 强制走 LaunchAgent（CLI 场景下没有 .app bundle，签名探测无意义）
    private let forceLaunchAgent: Bool

    /// - Parameters:
    ///   - executablePath: 覆盖可执行文件路径（默认取 `Bundle.main`）
    ///   - plistURL: 覆盖 LaunchAgent plist 路径（测试用）
    ///   - forceLaunchAgent: 跳过签名探测，直接使用 LaunchAgent
    public init(executablePath: String? = nil,
                plistURL: URL? = nil,
                forceLaunchAgent: Bool = false) {
        self.executablePathOverride = executablePath
        self.plistURLOverride = plistURL
        self.forceLaunchAgent = forceLaunchAgent
    }

    // MARK: - 模式探测

    /// 是否存在有效的（非 ad-hoc）代码签名
    public static func hasValidSignature() -> Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { return false }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
                staticCode, SecCSFlags(rawValue: kSecCSSigningInformation),
                &information) == errSecSuccess,
              let dictionary = information as? [String: Any] else { return false }
        // ad-hoc 签名没有 team identifier
        return dictionary[kSecCodeInfoTeamIdentifier as String] != nil
    }

    public var mode: LaunchAtLoginMode {
        if forceLaunchAgent { return .launchAgent }
        let bundlePath = Bundle.main.bundlePath
        guard bundlePath.hasSuffix(".app") else {
            return .unavailable(reason: "不在 .app bundle 内运行")
        }
        return Self.hasValidSignature() ? .smAppService : .launchAgent
    }

    // MARK: - LaunchAgent 路径

    public static var defaultAgentPlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
            .appendingPathComponent("\(agentLabel).plist")
    }

    public var agentPlistURL: URL {
        plistURLOverride ?? Self.defaultAgentPlistURL
    }

    public var executablePath: String {
        executablePathOverride ?? Bundle.main.executablePath ?? CommandLine.arguments[0]
    }

    // MARK: - 查询状态

    public var isEnabled: Bool {
        switch mode {
        case .smAppService:
            return SMAppService.mainApp.status == .enabled
        case .launchAgent:
            // 以 plist 是否存在为准：它在下次登录时由 launchd 自动加载
            return FileManager.default.fileExists(atPath: agentPlistURL.path)
        case .unavailable:
            return false
        }
    }

    // MARK: - 设置

    public enum LaunchError: Error, CustomStringConvertible {
        case smAppServiceFailed(String)
        case launchAgentFailed(String)

        public var description: String {
            switch self {
            case .smAppServiceFailed(let detail): return "SMAppService 失败：\(detail)"
            case .launchAgentFailed(let detail):  return "LaunchAgent 失败：\(detail)"
            }
        }
    }

    public func setEnabled(_ enabled: Bool) throws {
        switch mode {
        case .smAppService:
            try setViaSMAppService(enabled)
        case .launchAgent:
            try setViaLaunchAgent(enabled)
        case .unavailable(let reason):
            throw LaunchError.launchAgentFailed(reason)
        }
    }

    private func setViaSMAppService(_ enabled: Bool) throws {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                Log.info("已通过 SMAppService 注册开机自启动")
            } else {
                try SMAppService.mainApp.unregister()
                Log.info("已通过 SMAppService 取消开机自启动")
            }
        } catch {
            throw LaunchError.smAppServiceFailed(error.localizedDescription)
        }
    }

    private func setViaLaunchAgent(_ enabled: Bool) throws {
        let fileManager = FileManager.default
        let plistURL = agentPlistURL

        if !enabled {
            if fileManager.fileExists(atPath: plistURL.path) {
                bootout()
                try? fileManager.removeItem(at: plistURL)
                Log.info("已移除 LaunchAgent：\(plistURL.path)")
            }
            return
        }

        let directory = plistURL.deletingLastPathComponent()
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "Label": Self.agentLabel,
            "ProgramArguments": [executablePath],
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProcessType": "Interactive",
        ]

        do {
            let data = try PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
        } catch {
            throw LaunchError.launchAgentFailed(error.localizedDescription)
        }

        // ★ 刻意**不**在这里执行 `launchctl bootstrap`。
        //   plist 里 RunAtLoad=true，bootstrap 会让 launchd 立刻再启动一个实例
        //   —— 这正是"打开开机自启动后又冒出一个实例"的直接原因。
        //   `~/Library/LaunchAgents/` 下的 plist 会在**下次登录时**被 launchd 自动加载，
        //   所以安装时只需把文件写好即可。
        //
        //   注意：真正的根治手段是 App 侧的单实例保护（SingleInstanceGuard），
        //   因为重复启动的来源不止这一个。
        //
        //   这里顺手 bootout 一次，清掉可能存在的陈旧注册（未加载时返回非零，无害）。
        bootout()
        Log.info("已安装 LaunchAgent（下次登录生效）：\(plistURL.path) → \(executablePath)")
    }

    // MARK: - launchctl

    private func bootstrap() {
        runLaunchctl(["bootstrap", "gui/\(getuid())", agentPlistURL.path])
    }

    private func bootout() {
        runLaunchctl(["bootout", "gui/\(getuid())/\(Self.agentLabel)"])
    }

    private func runLaunchctl(_ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                                    encoding: .utf8) ?? ""
                Log.warn("launchctl \(arguments.joined(separator: " ")) 退出码 "
                         + "\(process.terminationStatus)：\(output.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        } catch {
            Log.warn("无法执行 launchctl：\(error.localizedDescription)")
        }
    }
}
