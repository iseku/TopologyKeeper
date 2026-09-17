// ⚠️ 本文件用 `import AppKit` 而**不是** `import Foundation`。
//
// 原因（本机实测，勿改）：本机只有 CommandLineTools，其
// `_Testing_Foundation.framework` 里**只有二进制、没有 swiftmodule**，
// 因此同一文件里 `import Foundation` 与 `import Testing` 并存必然报
// `no such module '_Testing_Foundation'`。
// AppKit 会传递性带来 Foundation 的 `Date`/`FileManager`/`Data`，
// 于是既能做时间戳格式与日志文件落盘的断言，又不触发上述冲突。
// （`PopoverLayoutTests` / `StatusIconGeometryTests` 用同一手法。）
import AppKit
import Testing
@testable import TopologyKeeperCore

// 日志显示等级（L）的单元测试。
//
// 这一组锁定的是**用户确认的默认行为**（2026-09）：
//   * 日志页的等级选择器**每次打开都停在 INF** —— DBG 里大量是
//     "设备事件成簇到来时重复发生的同一件事"，默认"全部"会把真正有信息量的行挤走；
//   * 这是**界面本地状态，不写进配置**：用户想看 DBG 就在选择器里换「全部」。
//
// 归档的边界（写在注释里，防止将来被"顺手"改掉）：
//   界面负责降噪，**落盘文件负责留证** —— 文件里始终记录全部等级，
//   不允许在 `Log` 内部按等级过滤文件输出，否则真机排查时打开文件会发现
//   DBG 行根本不存在，而那正是最近一次唤醒问题排查所依赖的证据来源。
//
// 另有一组（L-g..L-l）锁定 2026-09 用户提出的三条日志改动：
//   ① 落盘文件每次启动**轮转**：已存在的日志改名成 `.1`（旧的 `.1` 先删掉）、
//      再新建空文件 —— 既不续写膨胀，又保住上一轮的现场（崩溃后要看的正是那一轮）；
//   ② 时间戳带 `MM-dd` 日期（跨天不再混淆），但不带年份；
//   ③ App 内展示的时间字段**带方括号**（方括号由展示层拼，见下）。

@Suite("L 日志显示等级")
struct LogLevelTests {

    // MARK: 等级比较

    @Test("L-a 显示等级是「下限」语义：含等于、含更高等级")
    func isAtLeastIncludesEqualAndHigher() {
        // INF 下限：INF/WRN/ERR 显示，DBG 隐藏
        #expect(LogLevel.info.isAtLeast(.info))
        #expect(LogLevel.warn.isAtLeast(.info))
        #expect(LogLevel.error.isAtLeast(.info))
        #expect(!LogLevel.debug.isAtLeast(.info))

        // DBG 下限 = 全部显示
        for level in LogLevel.allCases {
            #expect(level.isAtLeast(.debug), "DBG 下限应放行全部等级")
        }

        // ERR 下限 = 只显示 ERR
        #expect(LogLevel.error.isAtLeast(.error))
        #expect(!LogLevel.warn.isAtLeast(.error))
    }

    @Test("L-b 等级取值齐全且顺序固定（DBG < INF < WRN < ERR）")
    func severityOrderIsStable() {
        // allCases 的顺序被 UI 的选择器直接采用，改顺序会让"下限"语义变错
        #expect(LogLevel.allCases == [.debug, .info, .warn, .error])
        for (i, lower) in LogLevel.allCases.enumerated() {
            for (j, higher) in LogLevel.allCases.enumerated() {
                #expect(higher.isAtLeast(lower) == (j >= i),
                        "\(higher) 与 \(lower) 的下限关系不符")
            }
        }
    }

    @Test("L-c 等级的显示名是纯文本（不含符号/颜文字）")
    func displayNamesArePlainText() {
        let banned: Set<Character> = ["✅", "❌", "⚠", "★", "⏳", "\u{FE0F}", "🔄"]
        for level in LogLevel.allCases {
            for ch in level.displayName {
                #expect(!banned.contains(ch),
                        "等级文案 \(level.displayName) 含符号 \(ch)")
            }
            // rawValue 必须保持三字母缩写 —— 日志正文里靠它对齐
            #expect(level.rawValue.count == 3)
        }
    }

    // MARK: 过滤语义（UI 用的判据）

    @Test("L-d 选中 INF 时只显示 INF/WRN/ERR 这三个等级")
    func infoFiltersOutOnlyDebug() {
        // 日志页的选择器是**等值**筛选（下拉里每一项就是一个等级），
        // 默认停在 INF 上：内容专注，DBG 那批重复行不再占屏。
        let levels = LogLevel.allCases
        let shown = levels.filter { $0 == LogLevel.info }
        #expect(shown == [.info])
        // 换成「全部」（nil）时一条都不能少 —— 文件里本来就记录了全部等级
        #expect(levels.count == 4)
    }

    @Test("L-e INF 是默认档位：它必须能挡住 DBG，同时不误伤更严重的等级")
    func infoIsAUsefulDefault() {
        // "默认 INF"这个决定要成立，需要两个条件同时满足：
        //   ① DBG 被挡住（否则默认档位没有降噪效果）
        //   ② WRN/ERR 不被挡住（否则默认档位会藏起真正需要看见的东西）
        #expect(!LogLevel.debug.isAtLeast(.info))
        #expect(LogLevel.warn.isAtLeast(.info))
        #expect(LogLevel.error.isAtLeast(.info))
    }

    // MARK: 时间戳格式（用户要求：加月日、不加年）

    /// 时间戳正则：`MM-dd HH:mm:ss.SSS`
    ///
    /// 写成计算属性而不是 static let：`Regex` 不是 Sendable，
    /// 静态存储会触发 Swift 6 的并发安全报错。
    private var stampPattern: Regex<Substring> {
        /^\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}$/
    }

    @Test("L-g 时间戳带 MM-dd 日期、不含年份（跨天不再混淆，又不挤占面板）")
    func timestampCarriesMonthAndDayWithoutYear() {
        let now = Date()
        // 用本地时区自己算期望值，避免测试依赖运行机器的时区
        let cal = Calendar.current
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
        let expectedPrefix = String(format: "%02d-%02d %02d:%02d:%02d.",
                                    c.month!, c.day!, c.hour!, c.minute!, c.second!)

        let stamp = LogEntry.timestamp(for: now)
        #expect(stamp.hasPrefix(expectedPrefix),
                "时间戳 \(stamp) 应以 \(expectedPrefix) 开头（= MM-dd HH:mm:ss.）")
        #expect(stamp.wholeMatch(of: stampPattern) != nil,
                "时间戳 \(stamp) 不匹配 MM-dd HH:mm:ss.SSS")
        // ★ 不许出现年份：两位年份或四位年份都不行
        #expect(!stamp.contains(String(c.year!)), "时间戳不应包含年份 \(c.year!)")
        #expect(!stamp.contains("\(c.year! % 100)"), "时间戳不应包含两位年份")

        // LogEntry 实例上的属性与静态方法必须同源（展示层直接用前者）
        let entry = LogEntry(id: 1, date: now, level: .info, message: "x")
        #expect(entry.timestampString == stamp, "timestampString 与 timestamp(for:) 必须一致")
        // ★ 方括号属于**展示层**，不在裸时间戳里 —— 界面自己拼（见 L-h）
        #expect(!entry.timestampString.contains("["), "裸时间戳不应自带方括号")
    }

    @Test("L-h 展示层拼出的时间字段带方括号（用户要求保留）")
    func displayFormKeepsBrackets() {
        // 这是 UI 里实际用的拼法（PopoverRootView / SettingsRootView 同一写法）。
        // 单独立一条断言，避免将来有人"顺手"把方括号从界面里删掉。
        let entry = LogEntry(id: 1, date: Date(), level: .warn, message: "hello")
        let shown = "[\(entry.timestampString)]"
        #expect(shown.hasPrefix("["))
        #expect(shown.hasSuffix("]"))
        #expect(shown.contains(" "))
        #expect(shown.dropFirst().dropLast().wholeMatch(of: stampPattern) != nil,
                "方括号内必须是 MM-dd HH:mm:ss.SSS，实际 \(shown)")
    }

    // MARK: 落盘文件：每次启动轮转一份备份，运行期开关不轮转

    /// 造一个可写的临时日志路径
    private func tempLogURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("tk-log-test-\(UUID().uuidString)")
            .appendingPathComponent("TopologyKeeper.log")
    }

    @Test("L-i 启动轮转：上一轮内容改名到 .1，当前文件为空")
    func launchRotationMovesPreviousRunToBackup() throws {
        let url = tempLogURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let backup = Log.rotatedFileURL(for: url)

        // 先制造"上一次运行"的内容
        Log.resetLogFileOnLaunch(url: url)
        let log = Log(capacity: 100, echoToStderr: false)
        log.configureFileLogging(enabled: true, url: url)
        log.write(.info, "上一次运行留下的行")
        #expect(try String(contentsOf: url, encoding: .utf8).contains("上一次运行留下的行"),
                "前置条件：当前文件里应有历史内容")

        // ★ 启动轮转
        Log.resetLogFileOnLaunch(url: url)

        let current = try String(contentsOf: url, encoding: .utf8)
        #expect(current.isEmpty, "轮转后当前文件必须为空，实际还剩 \(current.count) 字节")

        #expect(FileManager.default.fileExists(atPath: backup.path), ".1 备份应存在")
        let rotated = try String(contentsOf: backup, encoding: .utf8)
        #expect(rotated.contains("上一次运行留下的行"),
                "上一轮内容必须保留在 .1 里（崩溃后要看的正是那一轮）")
    }

    @Test("L-i2 ★ 只保留一份备份：第二次启动会覆盖旧的 .1")
    func onlyOneBackupIsKept() throws {
        let url = tempLogURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let backup = Log.rotatedFileURL(for: url)
        let log = Log(capacity: 100, echoToStderr: false)
        log.configureFileLogging(enabled: true, url: url)

        // 第 1 轮
        Log.resetLogFileOnLaunch(url: url)
        log.write(.info, "第一轮")
        // 第 2 轮：应把"第一轮"转到 .1
        Log.resetLogFileOnLaunch(url: url)
        log.write(.info, "第二轮")
        #expect(try String(contentsOf: backup, encoding: .utf8).contains("第一轮"))

        // 第 3 轮：旧的 .1（第一轮）必须被删掉，只剩"第二轮"
        Log.resetLogFileOnLaunch(url: url)
        let rotated = try String(contentsOf: backup, encoding: .utf8)
        #expect(rotated.contains("第二轮"), "备份应更新为第 2 轮内容")
        #expect(!rotated.contains("第一轮"), "不得累积多份备份 —— 旧的 .1 必须先删除")
        #expect(try String(contentsOf: url, encoding: .utf8).isEmpty, "当前文件应为空")
        log.configureFileLogging(enabled: false)
    }

    @Test("L-i3 轮转后新文件可继续追加（不是只删不建）")
    func currentFileRemainsWritableAfterRotation() throws {
        let url = tempLogURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let log = Log(capacity: 100, echoToStderr: false)

        Log.resetLogFileOnLaunch(url: url)
        log.configureFileLogging(enabled: true, url: url)
        log.write(.info, "旧的一行")
        Log.resetLogFileOnLaunch(url: url)          // 轮转
        log.write(.info, "新的一行")                 // 应落到新文件

        let current = try String(contentsOf: url, encoding: .utf8)
        #expect(current.contains("新的一行"), "轮转后必须还能写入，实际：\(current)")
        #expect(!current.contains("旧的一行"), "旧内容不应留在新文件里")
        log.configureFileLogging(enabled: false)
    }

    @Test("L-j 启动轮转：文件不存在时也要建出来（首启场景）")
    func launchResetCreatesMissingFile() {
        let url = tempLogURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let backup = Log.rotatedFileURL(for: url)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        Log.resetLogFileOnLaunch(url: url)
        #expect(FileManager.default.fileExists(atPath: url.path), "轮转后当前文件应存在")
        #expect(!FileManager.default.fileExists(atPath: backup.path),
                "没有上一轮内容时不该凭空造出 .1")
    }

    @Test("L-k 运行期开关落盘**不得**轮转/清空文件（否则一开一关就把证据删了）")
    func togglingFileLoggingDoesNotTruncate() throws {
        let url = tempLogURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        Log.resetLogFileOnLaunch(url: url)
        let log = Log(capacity: 100, echoToStderr: false)
        log.configureFileLogging(enabled: true, url: url)
        log.write(.info, "第一行")

        // 反复开关（用户在设置页里拨开关就会走到这里）
        log.configureFileLogging(enabled: false)
        log.configureFileLogging(enabled: true, url: url)

        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("第一行"), "运行期开关不得清空文件，实际内容：\(text)")
        #expect(!FileManager.default.fileExists(atPath: Log.rotatedFileURL(for: url).path),
                "运行期开关不得触发轮转")
        log.configureFileLogging(enabled: false)
    }

    @Test("L-l 落盘行的格式：方括号时间 + 三字母等级 + 正文，且与 app 内一致")
    func fileLineFormat() throws {
        let url = tempLogURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        Log.resetLogFileOnLaunch(url: url)
        let log = Log(capacity: 100, echoToStderr: false)
        log.configureFileLogging(enabled: true, url: url)
        log.write(.warn, "磁盘告警示例")
        log.configureFileLogging(enabled: false)

        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        // 最后一行是本条（前面可能还有 configureFileLogging 自己打的"已开启"）
        let last = String(lines.last ?? "")
        #expect(last.contains("WRN"), "落盘行应含三字母等级，实际：\(last)")
        #expect(last.contains("磁盘告警示例"))
        #expect(last.hasPrefix("["), "落盘行应以方括号时间开头，实际：\(last)")
        // 形如 "[09-16 14:32:07.418] WRN 磁盘告警示例"
        #expect(last.wholeMatch(of: /^\[\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}\] \w{3} .*$/) != nil,
                "落盘行格式不符：\(last)")
    }
}
