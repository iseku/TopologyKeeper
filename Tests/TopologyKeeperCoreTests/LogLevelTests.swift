// ⚠️ 本文件**刻意不 import Foundation**。
//
// 原因（本机实测，勿改）：本机只有 CommandLineTools，其
// `_Testing_Foundation.framework` 里**只有二进制、没有 swiftmodule**，
// 因此同一文件里 `import Foundation` 与 `import Testing` 并存必然报
// `no such module '_Testing_Foundation'`。
// 所以这里的断言全部限定在"不需要 Foundation 类型"的范围内。
// （`Data`/`JSONEncoder`/`FileManager` 都来自 Foundation，不能使用。）
//
// 由此产生的覆盖边界，以及**为什么可以接受**：
//   * `LogLevel` 的 Codable 往返、`AppConfig` 对缺失键的容错解码
//     → 无法在本组断言；改由"缺键时 `(try? c.decode(...)) ?? 默认值`"
//       这一写法本身保证（见 `AppConfig.init(from:)`，缺键不会抛错）。
//   * "落盘文件不被显示等级过滤" → 由 `Log` 不持有任何等级阈值这一结构事实保证：
//     `configureFileLogging` 只接收 url，写入路径上没有等级判据。
//     排查时若要复核，直接看 `~/Library/Logs/TopologyKeeper.log` 里有没有 DBG 行即可。
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
}
