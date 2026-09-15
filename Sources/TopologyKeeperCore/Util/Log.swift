import Foundation

public enum LogLevel: String, Sendable, CaseIterable {
    case debug = "DBG"
    case info  = "INF"
    case warn  = "WRN"
    case error = "ERR"

    /// 严重程度序号（越大越严重）。用于"显示等级下限"的比较。
    private var severity: Int {
        switch self {
        case .debug: return 0
        case .info:  return 1
        case .warn:  return 2
        case .error: return 3
        }
    }

    /// 本等级是否**达到**给定下限（含等于）。
    ///
    /// 用途：日志界面按"显示等级下限"降噪 —— 默认 `.info` 时
    /// 隐藏 DBG，但 WRN/ERR 一律保留。
    public func isAtLeast(_ minimum: LogLevel) -> Bool {
        severity >= minimum.severity
    }

    /// 界面文案（避免用户对着 "DBG/INF/WRN/ERR" 猜含义）。
    ///
    /// ⚠️ 与 `rawValue` 分工：`rawValue` 是**日志正文里的等级列**（必须保持
    /// 三字母、等宽对齐），`displayName` 只用于**选择器**，可读优先。
    public var displayName: String {
        switch self {
        case .debug: return "DBG 调试"
        case .info:  return "INF 信息"
        case .warn:  return "WRN 警告"
        case .error: return "ERR 错误"
        }
    }
}

public struct LogEntry: Equatable, Sendable, Identifiable {
    public let id: UInt64
    public let date: Date
    public let level: LogLevel
    public let message: String

    public var timestampString: String {
        LogEntry.formatter.string(from: date)
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}

/// 全局日志。
///
/// 设计要点（《详细设计.md》§10.4）：
/// 日志必须记录 **"发出值 vs 回读值"** —— 这是排查静默失败的唯一手段，
/// 因为实测写入可能返回 `noErr` 却毫无效果。因此涉及写入的地方
/// 一定要把目标格式与实际回读格式都打出来。
public final class Log: @unchecked Sendable {

    public static let shared = Log()

    private let lock = NSLock()
    private var ring: [LogEntry] = []
    private var nextID: UInt64 = 1
    private var capacity: Int
    private var echoToStderr: Bool
    private var fileURL: URL?
    /// 文件写入单独串行化。
    /// `write()` 会在 unlock 之后落盘，多线程（audioQueue / 主线程）并发追加
    /// 会让日志行互相穿插；用串行队列保证整行原子写入且顺序正确。
    private let fileQueue = DispatchQueue(label: "com.iseku.topologykeeper.log.file")

    /// 新增日志时的回调（UI 订阅用）。在调用线程上同步触发。
    private var observers: [(LogEntry) -> Void] = []

    public init(capacity: Int = 500, echoToStderr: Bool = false) {
        self.capacity = capacity
        self.echoToStderr = echoToStderr
    }

    public func configure(capacity: Int, echoToStderr: Bool) {
        lock.lock(); defer { lock.unlock() }
        self.capacity = max(50, capacity)
        self.echoToStderr = echoToStderr
        trimIfNeeded()
    }

    /// 开关日志落盘。默认写到 `~/Library/Logs/TopologyKeeper.log`。
    public func configureFileLogging(enabled: Bool, url: URL? = nil) {
        let target: URL?
        if enabled {
            target = url ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/TopologyKeeper.log")
        } else {
            target = nil
        }
        lock.lock(); fileURL = target; lock.unlock()

        guard let target else {
            Log.info("日志落盘已关闭")
            return
        }
        try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: target.path) {
            FileManager.default.createFile(atPath: target.path, contents: nil)
        }
        Log.info("日志落盘已开启：\(target.path)")
    }

    public var logFilePath: String? {
        lock.lock(); defer { lock.unlock() }
        return fileURL?.path
    }

    public func addObserver(_ observer: @escaping (LogEntry) -> Void) {
        lock.lock(); defer { lock.unlock() }
        observers.append(observer)
    }

    public func snapshot() -> [LogEntry] {
        lock.lock(); defer { lock.unlock() }
        return ring
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        ring.removeAll()
    }

    /// 导出为纯文本（每行一条）
    public func exportText() -> String {
        snapshot().map { "[\($0.timestampString)] \($0.level.rawValue) \($0.message)" }
            .joined(separator: "\n")
    }

    /// 直接追加到默认日志文件，**无视配置**。
    ///
    /// 用途：极端早期（配置尚未加载）或进程即将退出时留痕。
    /// 典型场景是单实例保护拦下重复启动 —— 否则那次退出完全不可观测，
    /// 用户只会看到"点了没反应"，无从排查。
    public static func appendDirect(_ level: LogLevel, _ message: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/TopologyKeeper.log")
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let line = "[\(formatter.string(from: Date()))] \(level.rawValue) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    public static func debug(_ message: String) { shared.write(.debug, message) }
    public static func info(_ message: String)  { shared.write(.info, message) }
    public static func warn(_ message: String)  { shared.write(.warn, message) }
    public static func error(_ message: String) { shared.write(.error, message) }

    public func write(_ level: LogLevel, _ message: String) {
        lock.lock()
        let entry = LogEntry(id: nextID, date: Date(), level: level, message: message)
        nextID += 1
        ring.append(entry)
        trimIfNeeded()
        let observers = self.observers
        let echo = echoToStderr
        let target = fileURL
        lock.unlock()

        let line = "[\(entry.timestampString)] \(level.rawValue) \(message)\n"
        if echo {
            FileHandle.standardError.write(Data(line.utf8))
        }
        if let target, let data = line.data(using: .utf8) {
            // sync：保证 write() 返回时该行已落盘，且顺序与调用顺序一致
            fileQueue.sync { Self.appendToFile(data, at: target) }
        }
        for observer in observers { observer(entry) }
    }

    private static func appendToFile(_ data: Data, at url: URL) {
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    /// 调用方必须已持有 lock
    private func trimIfNeeded() {
        if ring.count > capacity {
            ring.removeFirst(ring.count - capacity)
        }
    }
}
