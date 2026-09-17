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

    /// **裸时间戳**（不含方括号），例 `09-16 14:32:07.418`。
    ///
    /// ⚠️ 展示层需要的是**带方括号**的形式（`[09-16 14:32:07.418]`）。
    ///    方括号刻意不放进这里：它属于"怎么显示"而不是"时间是什么"。
    ///    界面直接拼方括号即可（见 `PopoverRootView` / `SettingsRootView`）。
    public var timestampString: String {
        LogEntry.timestamp(for: date)
    }

    /// 任意时刻的时间戳（与 `timestampString` 同一格式）。
    ///
    /// 供不构造 `LogEntry` 的调用点使用（如 `tkctl` 的控制台输出），
    /// 避免它们在本地再写一个 `DateFormatter` 而与主格式漂移。
    public static func timestamp(for date: Date) -> String {
        formatter.string(from: date)
    }

    /// ★ 带 `MM-dd` 日期。
    ///
    /// 为什么不带年份：单个文件最多只覆盖"一次运行 + 上一次运行"
    /// （启动时轮转，见 `Log.resetLogFileOnLaunch`），
    /// 而**跨天**才是常态（长时间开机的机器）—— 只留 `HH:mm:ss` 会让
    /// 前后两天的记录看起来像同一天，所以月日是必须的。
    /// 完整年份则会让每行多占 5 个字符、挤压本来就窄的日志面板；
    /// 真要跨年（元旦前后对比两轮日志）靠 `date` 字段本身仍可判定。
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss.SSS"
        return f
    }()
}

/// 全局日志。
///
/// 设计要点：
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
    ///
    /// ⚠️ 本方法**不会**轮转/清空已有内容：它是"开关"，运行期反复切换时应当续写。
    ///    轮转只在启动时由 `resetLogFileOnLaunch()` 做**一次**。
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

    /// 上一轮日志的备份路径（`TopologyKeeper.log.1`）。
    ///
    /// 只保留**一份**备份：`resetLogFileOnLaunch` 会先删掉旧的 `.1`，再把当前
    /// 日志改名过来。见该方法的说明。
    public static func rotatedFileURL(for url: URL) -> URL {
        url.appendingPathExtension("1")
    }

    /// 默认日志文件路径（`~/Library/Logs/TopologyKeeper.log`）
    public static var defaultFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/TopologyKeeper.log")
    }

    /// ★ **每次启动轮转日志文件**（在配置加载之前调用一次）：
    ///
    /// ```
    /// TopologyKeeper.log      ← 已存在 → 改名到 .1（若 .1 已存在则先删掉）
    /// TopologyKeeper.log.1    ← 上一次运行的内容（唯一一份备份）
    /// TopologyKeeper.log      ← 新建空文件，本次运行写入这里
    /// ```
    ///
    /// ## 为什么不续写
    ///
    /// 续写会让文件**日益膨胀**：这个 App 是常驻菜单栏的，日志量不小
    /// （唤醒/设备事件的成簇记录、写入回读、重试回退……），
    /// 而用户几乎不会主动清理。实测本机几周就攒到 248 KB，
    /// 之后想"看看最近出了什么事"反而要先在巨型文件里翻找。
    ///
    /// ## 为什么保留一份备份，而不是直接删掉
    ///
    /// 直接清空的代价是"上一次运行的历史被丢弃"，而**上一轮往往正是要查的那一轮**
    /// —— 崩溃/异常退出后重启，现场就在上一轮日志里。留一份 `.1` 就够覆盖这个场景，
    /// 又不需要多份文件与保留策略（本项目的日志用途是**单次运行的现场排查**，
    /// 不是长期归档）。
    ///
    /// ## 失败处理
    ///
    /// 改名失败（跨卷、只读目录等）时**退回"直接重建空文件"**：宁可丢备份，
    /// 也要保证本次运行能落盘 —— 否则用户看到的是一个"永远空着的日志"，
    /// 比没有备份更难排查。失败信息打到 stderr（此时文件日志尚未开启）。
    public static func resetLogFileOnLaunch(url: URL? = nil) {
        let target = url ?? defaultFileURL
        let backup = rotatedFileURL(for: target)
        let fm = FileManager.default
        try? fm.createDirectory(at: target.deletingLastPathComponent(),
                                withIntermediateDirectories: true)

        // ① 只保留一份备份：先删掉旧的 .1
        //    用 `try?`：文件不存在是正常情况（首次运行）
        if fm.fileExists(atPath: backup.path) {
            do {
                try fm.removeItem(at: backup)
            } catch {
                // 删不掉就让下一步的改名去覆盖；仍失败则下面会退回重建
                reportRotationFailure("删除旧备份 \(backup.path) 失败", error)
            }
        }

        // ② 把当前日志改名成 .1（这一步就是"轮转"）
        var rotated = false
        if fm.fileExists(atPath: target.path) {
            do {
                try fm.moveItem(at: target, to: backup)
                rotated = true
            } catch {
                reportRotationFailure("把 \(target.path) 轮转为 \(backup.path) 失败", error)
            }
        }

        // ③ 新建空文件（原子写：即使上一步失败也保证目录里有一个可写的目标文件）
        do {
            try Data().write(to: target, options: .atomic)
        } catch {
            reportRotationFailure("新建日志文件 \(target.path) 失败", error)
        }

        if rotated, let size = fileSize(of: backup) {
            FileHandle.standardError.write(
                Data("上一轮日志已备份为 \(backup.path)（\(size) 字节）\n".utf8))
        }
    }

    private static func reportRotationFailure(_ what: String, _ error: Error) {
        FileHandle.standardError.write(
            Data("\(what)：\(error.localizedDescription)\n".utf8))
    }

    private static func fileSize(of url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int
    }

    /// 当前日志文件的路径（落盘关闭时为 nil）
    public var logFilePath: String? {
        lock.lock(); defer { lock.unlock() }
        return fileURL?.path
    }

    /// 上一轮日志备份的路径（`…log.1`）。
    ///
    /// ⚠️ **不随"是否开启落盘"变化**：备份是启动轮转产生的文件，与当前开关无关。
    ///    这样用户关掉落盘后仍能找到上一轮的现场。
    ///
    /// - Returns: 备份文件的路径；文件不存在时返回 nil（界面据此决定要不要显示入口）
    public var rotatedLogFilePath: String? {
        let backup = Self.rotatedFileURL(for: Self.defaultFileURL)
        return FileManager.default.fileExists(atPath: backup.path) ? backup.path : nil
    }

    /// 订阅新增日志。**在调用线程上同步触发**。
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
        let url = defaultFileURL
        // ★ 与正常落盘行**完全同格式**（含 MM-dd 日期）：两处格式不一致时，
        //   同一份日志里会出现"有的行带日期有的不带"，反而更难读。
        //   这里直接用 LogEntry 的格式化器，避免第二个 DateFormatter 漂移。
        let line = "[\(LogEntry(id: 0, date: Date(), level: level, message: message).timestampString)]"
            + " \(level.rawValue) \(message)\n"
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
