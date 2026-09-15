import CoreAudio
import Foundation
import TopologyKeeperCore

/// ★ **必须**用它读写 App 的配置。
///
/// 为什么（本会话踩到的真 bug）：`ConfigStore` 默认用 `UserDefaults.standard`，
/// 而 `tkctl` 不是 app bundle ⇒ 它的 `standard` 是**自己的应用域**，
/// 与 App 的 `com.iseku.topologykeeper`（suite）域**完全隔离**。
/// 于是 `tkctl mix show` 显示的从来不是 App 实际在用的配置，
/// `tkctl mix target/enable` 的修改 App 也看不见 ——
/// 现象就是"配置与行为不符"，而且极难定位。
/// （`tkctl seed` / `showconfig` 用的是 appDefaults，所以它们一直是对的；
///   只有后加的 `swap` / `mix` 系列漏了这一点。）
func appConfigStore() -> ConfigStore {
    ConfigStore(defaults: appDefaults() ?? UserDefaults.standard)
}

/// 改完配置后**通知正在运行的 App 重新加载并重新应用**。
///
/// 为什么必须：App 只在启动时读一次配置并缓存在内存里；`tkctl` 直接写
/// UserDefaults 时它毫无察觉，会继续按旧配置跑 ——
/// 现象是"CLI 显示改了、App 行为没变"，极难定位（本会话绕了很久）。
func notifyAppToReload() {
    DistributedNotificationCenter.default().postNotificationName(
        ConfigStore.externalChangeNotification, object: nil,
        userInfo: nil, deliverImmediately: true)
    // 给 App 一点时间反应，避免紧接着的读取看到的还是旧状态
    Thread.sleep(forTimeInterval: 0.4)
}


// tkctl —— 命令行诊断 / 验证工具。
//
// 用途：
//   * 验证 CoreAudioService + FormatApplier 在真实硬件上的行为
//   * 跑真实的睡眠/唤醒验证（不需要 UI）
//   * 长期：出问题时的诊断入口
//
// 用法见 printUsage()。

let service = CoreAudioService()
let applier = FormatApplier(service: service)

func printUsage() {
    print("""
    tkctl —— TopologyKeeper 诊断工具

    用法:
      tkctl list                          列出所有输出设备
      tkctl capability <uid|index>         dump 某设备的合法格式清单
      tkctl status   <uid|index>           显示当前格式与目标对比
      tkctl apply    <uid|index> <声道> <位深> <采样率>
                                           写入格式（含回读校验，一次性）
      tkctl lock     <uid|index> <声道> <位深> <采样率>
                                           启动完整守护：持续维持目标格式，
                                           用于验证睡眠/唤醒后自动恢复（Ctrl-C 退出）
      tkctl help

     配置（App 的 UserDefaults）
      tkctl showconfig                    显示 App 当前配置
      tkctl seed     <uid|index> <声道> <位深> <采样率>
                                          为 App 写入一条规则（无需 GUI）
      tkctl clearconfig                   清除 App 配置
      tkctl logs [行数]                   查看 App 的日志文件（默认末 60 行）

     开机自启动（LaunchAgent，无需代码签名）
      tkctl agent status                  查看自启动状态
      tkctl agent install [--app <路径>]    安装（默认用 Dist/TopologyKeeper.app）
      tkctl agent uninstall               卸载
      tkctl agent dump                    只打印将要写入的 plist

    提示: <uid|index> 可传设备 UID，或 `list` 输出里的序号。
    """)
}

// MARK: - 设备解析

func resolveDevice(_ token: String) -> DeviceDescriptor? {
    let devices = service.allOutputDevices()
    if let index = Int(token), index >= 0, index < devices.count {
        return devices[index]
    }
    return devices.first { $0.uid == token }
}

// MARK: - 子命令

func cmdList() {
    let devices = service.allOutputDevices()
    guard !devices.isEmpty else {
        print("（没有找到输出设备）")
        return
    }
    print("共 \(devices.count) 个输出设备：\n")
    for (index, device) in devices.enumerated() {
        let capability = service.capability(of: device.id)
        let current = service.currentPhysicalFormat(ofDevice: device.id)
        let nominal = service.nominalSampleRate(of: device.id)
        print("[\(index)] \(device.displayName)")
        print("     UID:        \(device.uid)")
        print("     声道数:      \(device.outputChannelCount)")
        print("     当前格式:    \(current.map(CoreAudioHelpers.describeShort) ?? "?")"
              + "  标称采样率 \(nominal.map(AudioFormatPreset.rateString) ?? "?")Hz")
        print("     能力清单:    \(capability.combinationCount) 个组合，"
              + "声道 \(capability.allChannelCounts)")
        print("     AudioDeviceID: \(device.id)  [注意] 会话级，重启/唤醒后会变")
        print("")
    }
}

func cmdCapability(_ token: String) {
    guard let device = resolveDevice(token) else {
        print("[失败] 找不到设备: \(token)"); return
    }
    let capability = service.capability(of: device.id)
    print("设备: \(device.displayName)")
    print("UID:  \(device.uid)")
    print("")
    if capability.isEmpty {
        print("（能力清单为空）")
        return
    }
    print("合法格式清单（共 \(capability.combinationCount) 个组合）:")
    print(capability.detailedDescription())
    print("")
    print("级联视图:")
    for channels in capability.allChannelCounts {
        let bitDepths = capability.bitDepths(forChannelCount: channels)
        print("  \(channels)ch → 位深 \(bitDepths)")
        for bits in bitDepths {
            let rates = capability.sampleRates(forChannelCount: channels, bitDepth: bits)
            print("      \(bits)bit → \(rates.map(AudioFormatPreset.rateString).joined(separator: ", "))")
        }
    }
}

func cmdStatus(_ token: String) {
    guard let device = resolveDevice(token) else {
        print("[失败] 找不到设备: \(token)"); return
    }
    let capability = service.capability(of: device.id)
    let current = service.currentPhysicalFormat(ofDevice: device.id)
    print("设备:     \(device.displayName)")
    print("当前格式: \(current.map(CoreAudioHelpers.describe) ?? "?")")
    print("标称采样率: \(service.nominalSampleRate(of: device.id).map(AudioFormatPreset.rateString) ?? "?")Hz")
    print("被占用:   \(service.isRunningSomewhere(device.id) ? "是（有其它进程在用）" : "否")")
    print("能力清单: \(capability.summary)")
}

func cmdApply(_ args: [String]) {
    guard args.count >= 4,
          let channels = UInt32(args[1]),
          let bits = UInt32(args[2]),
          let rate = Double(args[3]) else {
        print("[失败] 参数错误。用法: tkctl apply <uid|index> <声道> <位深> <采样率>")
        return
    }
    guard let device = resolveDevice(args[0]) else {
        print("[失败] 找不到设备: \(args[0])"); return
    }

    let capability = service.capability(of: device.id)
    guard let entry = capability.entry(channels: channels, bitDepth: bits, sampleRate: rate) else {
        // 这不是失败，而是"能力尚未就绪" —— 正确行为是等待下一次设备事件。
        print("[等待] 组合 \(channels)ch/\(bits)bit/\(AudioFormatPreset.rateString(rate))Hz "
              + "当前不在能力清单中")
        print("   当前能力: \(capability.summary)")
        print("   → 正确行为是等待设备就绪，而不是强行写入。")
        exit(2)
    }

    let preset = AudioFormatPreset(verbatim: entry, sampleRate: rate)
    print("设备:     \(device.displayName)")
    print("写入前:   \(service.currentPhysicalFormat(ofDevice: device.id).map(CoreAudioHelpers.describe) ?? "?")")
    print("目标格式: \(preset.compactString)  (bpf=\(preset.bytesPerFrame))")
    print("")

    let outcome = applier.apply(preset, to: device.id)

    print("写入后:   \(service.currentPhysicalFormat(ofDevice: device.id).map(CoreAudioHelpers.describe) ?? "?")")
    print("结果:     \(outcome.logDescription)")

    if outcome.isSuccess {
        print("\n成功")
        exit(0)
    } else if outcome.shouldWait {
        print("\n能力未就绪 —— 这不是失败，应等待下一次设备事件")
        exit(2)
    } else {
        print("\n失败")
        exit(1)
    }
}

// MARK: - lock：完整引擎，用于真实睡眠/唤醒验证

/// 运行时配置持有者（CLI 内规则基本不变，但用 holder 以便统一接口）
final class CliConfigHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: AppConfig
    init(_ config: AppConfig) { storage = config }
    var value: AppConfig {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}

func cmdLock(_ args: [String]) {
    guard args.count >= 4,
          let channels = UInt32(args[1]),
          let bits = UInt32(args[2]),
          let rate = Double(args[3]) else {
        print("[失败] 参数错误。用法: tkctl lock <uid|index> <声道> <位深> <采样率>")
        print("   例:   tkctl lock 0 8 24 96000")
        exit(1)
    }
    guard let device = resolveDevice(args[0]) else {
        print("[失败] 找不到设备: \(args[0])"); exit(1)
    }

    let capability = service.capability(of: device.id)
    guard let entry = capability.entry(channels: channels, bitDepth: bits, sampleRate: rate) else {
        print("[等待] 组合 \(channels)ch/\(bits)bit/\(AudioFormatPreset.rateString(rate))Hz "
              + "当前不在能力清单中。")
        print("   当前能力: \(capability.summary)")
        print("   请等设备就绪后重试（唤醒后需要 19~28 秒）。")
        exit(2)
    }
    let preset = AudioFormatPreset(verbatim: entry, sampleRate: rate)

    let rule = DeviceRule(deviceUID: device.uid,
                          deviceName: device.name,
                          transportType: device.transportType,
                          preset: preset,
                          conflictPolicy: .enforceAlways)

    var config = AppConfig()
    config.rules = [rule]
    config.recordLogToFile = false

    // 环境变量覆盖 —— 便于在真机上验证争夺行为，也给用户一个调参入口
    let env = ProcessInfo.processInfo.environment
    if let value = env["TK_SELF_WRITE_SUPPRESS_MS"], let ms = Int(value) {
        config.selfWriteSuppressMs = ms
    }
    if let value = env["TK_THRASH_THRESHOLD"], let n = Int(value) {
        config.thrashThreshold = n
    }
    if let value = env["TK_THRASH_WINDOW_MS"], let ms = Int(value) {
        config.thrashWindowMs = ms
    }
    if let value = env["TK_CONFLICT_BACKOFF_MS"], let ms = Int(value) {
        config.conflictBackoffMs = ms
    }
    if let value = env["TK_CONFLICT_THRESHOLD"], let n = Int(value) {
        config.conflictBackoffThreshold = n
    }

    let holder = CliConfigHolder(config)

    // 详细日志打到 stderr，便于重定向到文件分析
    Log.shared.configure(capacity: 4000, echoToStderr: true)

    let queue = DispatchQueue(label: "com.iseku.topologykeeper.audio")
    let audioService = CoreAudioService()
    let watcher = DeviceWatcher(service: audioService,
                               queue: queue,
                               debounceMs: config.eventDebounceMs,
                               watchedUIDs: { [device.uid] })
    let sleepWake = SleepWakeObserver(hopQueue: queue,
                                      watchdogExecutor: makeQueueExecutor(queue))
    let policy = ApplyPolicy(config: { holder.value })
    let engine = RuleEngine(service: audioService,
                            watcher: watcher,
                            sleepWake: sleepWake,
                            policy: policy,
                            config: { holder.value },
                            queue: queue,
                            pollExecutor: makeQueueExecutor(queue))

    print(String(repeating: "=", count: 78))
    print("TopologyKeeper 锁定守护（M2 验证）")
    print(String(repeating: "=", count: 78))
    print("设备:     \(device.displayName)")
    print("UID:      \(device.uid)")
    print("目标格式: \(preset.displayString)")
    print("当前格式: \(service.currentPhysicalFormat(ofDevice: device.id).map(CoreAudioHelpers.describe) ?? "?")")
    print("冲突策略: 持续强制锁定")
    let thrashWindowSec = config.thrashWindowMs / 1000
    let backoffSec = config.conflictBackoffMs / 1000
    print("抖动检测: \(thrashWindowSec) 秒内超过 \(config.thrashThreshold) 次即退避 \(backoffSec) 秒")
    print("")
    print("现在可以睡眠 / 唤醒这台 Mac，观察是否自动恢复。Ctrl-C 退出。")
    print(String(repeating: "-", count: 78))

    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"

    // 状态变化时打印（在 audioQueue 回调，hop 到 main 输出）
    let previousStates = Collector2<UUID, LockState>()
    engine.onSnapshots = { snapshots in
        DispatchQueue.main.async {
            for snapshot in snapshots {
                let previous = previousStates.value(for: snapshot.ruleID)
                guard previous != snapshot.state else { continue }
                previousStates.set(snapshot.state, for: snapshot.ruleID)

                let time = formatter.string(from: Date())
                print("[\(time)] 状态 \(previous.map { "\($0.displayText) → " } ?? "")"
                      + "\(snapshot.state.displayText)")
                print("           预设 \(snapshot.preset.displayString)"
                      + "   当前 \(snapshot.currentFormatText)")
                if let error = snapshot.lastError {
                    print("           错误 \(error)")
                }
            }
        }
    }

    // 心跳：每 30 秒确认守护仍在运行
    let heartbeat = DispatchSource.makeTimerSource(queue: .main)
    heartbeat.schedule(deadline: .now() + 30, repeating: 30)
    heartbeat.setEventHandler {
        let current = service.currentPhysicalFormat(ofDevice: device.id)
        let target = preset.matchesCurrent(current ?? AudioStreamBasicDescription())
        print("[\(formatter.string(from: Date()))] · 心跳 | 当前 "
              + "\(current.map(CoreAudioHelpers.describeShort) ?? "设备不在")"
              + " | \(target ? "已是目标格式" : "与目标不一致（守护应正在处理）")")
    }
    heartbeat.resume()

    engine.start()

    // 全局队列上启动引擎，然后进入主线程事件循环
    queue.async {
        Log.info("引擎启动完成")
    }
    dispatchMain()
}

/// 极简的线程安全键值收集器（CLI 用）
final class Collector2<K: Hashable, V>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [K: V] = [:]
    func value(for key: K) -> V? {
        lock.lock(); defer { lock.unlock() }; return storage[key]
    }
    func set(_ value: V, for key: K) {
        lock.lock(); storage[key] = value; lock.unlock()
    }
}

// MARK: - seed / showconfig：操作 App 的配置（便于无 GUI 预配置与端到端测试）

let appConfigKey = ConfigStore.defaultKey

func appDefaults() -> UserDefaults? {
    UserDefaults(suiteName: "com.iseku.topologykeeper")
}

func cmdSeed(_ args: [String]) {
    guard args.count >= 4,
          let channels = UInt32(args[1]),
          let bits = UInt32(args[2]),
          let rate = Double(args[3]) else {
        print("[失败] 参数错误。用法: tkctl seed <uid|index> <声道> <位深> <采样率>")
        exit(1)
    }
    guard let device = resolveDevice(args[0]) else {
        print("[失败] 找不到设备: \(args[0])"); exit(1)
    }
    let capability = service.capability(of: device.id)
    guard let entry = capability.entry(channels: channels, bitDepth: bits, sampleRate: rate) else {
        print("[等待] 组合不在能力清单中，无法写入配置。当前能力: \(capability.summary)")
        exit(2)
    }
    guard let defaults = appDefaults() else {
        print("[失败] 无法打开 App 的 UserDefaults 域"); exit(1)
    }

    let preset = AudioFormatPreset(verbatim: entry, sampleRate: rate)
    let rule = DeviceRule(deviceUID: device.uid,
                          deviceName: device.name,
                          transportType: device.transportType,
                          preset: preset,
                          conflictPolicy: .enforceAlways)

    var config = AppConfig()
    if let data = defaults.data(forKey: appConfigKey),
       let existing = try? JSONDecoder().decode(AppConfig.self, from: data) {
        config = existing
    }
    config.rules = [rule]
    // ★ 不要动 launchAtLogin：它是用户在设置里的选择，seed 只负责规则
    // --log：把日志落盘，这样睡眠/唤醒过程可以在事后从日志里回看
    let wantsLog = args.contains("--log")
    if wantsLog { config.recordLogToFile = true }

    do {
        defaults.set(try JSONEncoder().encode(config), forKey: appConfigKey)
        defaults.synchronize()
    } catch {
        print("[失败] 编码失败: \(error)"); exit(1)
    }

    print("[成功] 已写入 App 配置")
    print("   设备:   \(device.displayName)")
    print("   UID:    \(device.uid)")
    print("   预设:   \(preset.displayString)   (bpf=\(preset.bytesPerFrame) flags=\(preset.formatFlags))")
    print("   日志落盘: \(config.recordLogToFile ? "已开启 → ~/Library/Logs/TopologyKeeper.log" : "关闭（加 --log 可开启）")")
}

// MARK: - logs：查看 App 的日志文件

func cmdLogs(_ args: [String]) {
    let count = args.first.flatMap { Int($0) } ?? 60
    let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/TopologyKeeper.log")

    guard FileManager.default.fileExists(atPath: url.path) else {
        print("（日志文件不存在：\(url.path)）")
        print("提示：需在配置里开启 recordLogToFile —— 用 `tkctl seed <设备> <声道> <位深> <采样率> --log`")
        return
    }
    guard let content = try? String(contentsOf: url, encoding: .utf8) else {
        print("[失败] 无法读取 \(url.path)"); exit(1)
    }
    let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
    print("=== \(url.path)（最后 \(min(count, lines.count)) 行 / 共 \(lines.count) 行）===")
    for line in lines.suffix(count) { print(line) }
}

func cmdShowConfig() {
    guard let defaults = appDefaults() else {
        print("[失败] 无法打开 App 的 UserDefaults 域"); exit(1)
    }
    guard let data = defaults.data(forKey: appConfigKey) else {
        print("（App 尚无配置）")
        return
    }
    guard let config = try? JSONDecoder().decode(AppConfig.self, from: data) else {
        print("[失败] 配置无法解析"); exit(1)
    }
    print("规则数: \(config.rules.count)")
    for rule in config.rules {
        print("  · \(rule.deviceName) [\(rule.deviceUID)]")
        print("      预设: \(rule.preset.displayString)  bpf=\(rule.preset.bytesPerFrame)"
              + " flags=\(rule.preset.formatFlags)")
        print("      策略: \(rule.conflictPolicy.displayText)  启用: \(rule.isEnabled)")
    }
    print("开机自启动: \(config.launchAtLogin)")
    print("抑制窗口:   \(config.selfWriteSuppressMs)ms")
    print("退避阈值:   \(config.conflictBackoffThreshold) 次 / \(config.conflictBackoffMs)ms")
}

func cmdClearConfig() {
    guard let defaults = appDefaults() else { exit(1) }
    defaults.removeObject(forKey: appConfigKey)
    defaults.synchronize()
    print("[成功] 已清除 App 配置")
}

// MARK: - agent：LaunchAgent 开机自启动

func cmdAgent(_ args: [String]) {
    let sub = args.first ?? "status"
    // 默认指向已构建的 .app；也可用 --app 指定
    var appPath = "\(FileManager.default.currentDirectoryPath)/Dist/TopologyKeeper.app"
    if let index = args.firstIndex(of: "--app"), args.count > index + 1 {
        appPath = args[index + 1]
    }
    let executable = "\(appPath)/Contents/MacOS/TopologyKeeper"

    let manager = LaunchAtLoginManager(executablePath: executable,
                                       forceLaunchAgent: true)

    switch sub {
    case "status":
        let executableExists = FileManager.default.isExecutableFile(atPath: executable)
        print("模式:        \(manager.mode.displayText)")
        print("plist:       \(manager.agentPlistURL.path)")
        print("已安装:      \(manager.isEnabled ? "是" : "否")")
        print("目标可执行:  \(manager.executablePath)")
        print("可执行存在:  \(executableExists ? "是" : "否")")
        // ★ 失效安装检测：plist 还在但目标已被移动/删除，
        //   launchd 会静默启动失败（登录后什么都不发生，很难排查）
        if manager.isEnabled && !executableExists {
            print("")
            print("[注意] 自启动项已失效：plist 存在，但它指向的可执行文件不存在。")
            print("    常见原因：把 TopologyKeeper.app 移动/删除/改名了，或重新构建到了别的路径。")
            print("    修复：先 uninstall，再用正确的 --app 路径重新 install。")
            exit(3)
        }

    case "install":
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            print("[失败] 找不到可执行文件: \(executable)")
            print("   先运行 Scripts/build_app.sh")
            exit(1)
        }
        do {
            try manager.setEnabled(true)
            print("[成功] 已安装 LaunchAgent")
            print("   \(manager.agentPlistURL.path)")
            print("   下次登录将自动启动 TopologyKeeper")
        } catch {
            print("[失败] 安装失败: \(error)"); exit(1)
        }

    case "uninstall":
        do {
            try manager.setEnabled(false)
            print("[成功] 已移除 LaunchAgent")
        } catch {
            print("[失败] 移除失败: \(error)"); exit(1)
        }

    case "dump":
        // 打印将要写入的 plist 内容（不实际安装）
        let plist: [String: Any] = [
            "Label": LaunchAtLoginManager.agentLabel,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProcessType": "Interactive",
        ]
        let data = try? PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0)
        print(String(data: data ?? Data(), encoding: .utf8) ?? "(生成失败)")

    default:
        print("用法: tkctl agent <status|install|uninstall|dump> [--app <path>]")
    }
}

// MARK: - swap：声道交换诊断

/// 声道交换的诊断与一次性试跑。
///
/// 用法：
///   tkctl swap list             列出可用的源/目标设备
///   tkctl swap show             显示当前配置与引擎状态
///   tkctl swap run [秒数]       前台跑一次交换（会真正占用设备）
///   tkctl swap enable/disable   写配置开关（App 下次读取生效）
func cmdSwap(_ args: [String]) {
    let sub = args.first ?? "show"
    switch sub {
    case "list":    swapList()
    case "show":    swapShow()
    case "run":     swapRun(seconds: args.count >= 2 ? (Double(args[1]) ?? 5) : 5)
    case "enable":  swapSetEnabled(true)
    case "disable": swapSetEnabled(false)
    case "selftest":
        var secs = 8.0
        var pair: (Int, Int)? = nil
        var i = 1
        while i < args.count {
            if args[i] == "--swap", i + 1 < args.count {
                let parts = args[i + 1].split(separator: ",").compactMap { Int($0) }
                if parts.count == 2 { pair = (parts[0], parts[1]) }
                i += 2
            } else {
                if let v = Double(args[i]) { secs = v }
                i += 1
            }
        }
        swapSelfTest(seconds: secs, swapPair: pair)
    default:
        print("""
        swap 子命令：
          list              列出源（BlackHole）与目标（≥6 声道、非 BlackHole）设备
          show             显示当前配置与引擎状态
          run [秒]          按当前配置前台跑一次交换
          selftest [秒] [--swap a,b]
                            自测：用**生产版驱动**播逐段序列并交换（不需要外部音频源）
                            例：tkctl swap selftest 20 --swap 1,2   （左右互换，最易判定）
          enable / disable  改写配置开关
        """)
    }
}

private func swapResolver() -> CoreAudioChannelSwapResolver { CoreAudioChannelSwapResolver() }

private func swapList() {
    let r = swapResolver()
    print("\n声道交换 · 设备清单")
    print("（目标筛选条件：输出声道 ≥\(ChannelSwapPlan.minimumChannelCount) 且非 BlackHole）\n")

    print("源设备候选（BlackHole）：")
    let bh = r.device(uid: nil, namePrefix: "BlackHole")
    if let bh {
        print("  · \(bh.name)  UID=\(bh.uid)")
        print("    输出 \(bh.outputChannels) 声道 / 输入 \(bh.inputChannels) 声道  "
              + "\(Int(bh.nominalSampleRate))Hz")
    } else {
        print("  （未安装 BlackHole —— 声道交换需要它作为输入源）")
    }

    print("\n目标设备候选（≥\(ChannelSwapPlan.minimumChannelCount) 声道且非 BlackHole）：")
    let best = r.preferredOutputDevice(excludingNamePrefix: "BlackHole")
    if let best {
        let plan = ChannelSwapPlan(sourceChannelCount: best.outputChannels)
        print("  · \(best.name)  UID=\(best.uid)")
        print("    \(best.outputChannels) 声道  \(Int(best.nominalSampleRate))Hz")
        print("    默认交换：\(plan.swapDescription)")
        if let map = plan.swapMap {
            print("    ChannelMap（API 0-based）= \(map)")
        }
    } else {
        print("  （没有符合条件的设备）")
    }

    if let d = r.defaultOutputDevice() {
        let isTarget = (d.uid == best?.uid)
        print("\n系统默认输出：\(d.name)")
        print("  → 输出单元将使用：\(isTarget ? "DefaultOutput（跟随默认输出）" : "HALOutput（显式绑设备）")")
    }
    print("")
}

private func swapShow() {
    let config = appConfigStore().config
    let s = config.channelSwap
    print("\n声道交换配置")
    print("  开关:        \(s.isEnabled ? "启用" : "停用")")
    print("  交换声道:    \(s.swapDescription)   ← 对外 1-based")
    print("  输入设备:    \(s.inputDeviceUID ?? "自动（第一个 BlackHole）")")
    print("  输出设备:    \(s.outputDeviceUID ?? "自动（≥\(ChannelSwapPlan.minimumChannelCount) 声道中最多者）")")
    print("  采样率对齐:  \(s.alignInputSampleRate ? "开（只写 BlackHole）" : "关")")
    print("  重试回退:    \(s.backoffDescription)（\(s.retryBackoffMs)）")
    print("  耗尽后通知:  \(s.notifyOnGiveUp ? "开" : "关")")
    print("")
    print("提示：引擎状态只在 App 进程内可得；本命令显示的是持久化配置。")
    print("      要看实时状态请用 `tkctl swap run` 或 App 的菜单栏面板。")
    print("")
}

// MARK: - LFE 混音（tkctl mix）

/// 读目标设备**自己声明的**声道布局（低音/中置各在第几条声道）。
///
/// 这一步是本功能的关键：本项目原先假定"第 3=中置、第 4=低音"恒成立，
/// 而本机 27C3A Pro 声明的是 **L R LFE C**，正好相反。
/// 混音混错方向 = 混进没有声音的通道，且不报错（静默失效）。
private func mixDeclaredIndices() -> (device: ChannelSwapDeviceInfo,
                                      indices: CoreAudioHelpers.ChannelIndices?)? {
    let resolver = CoreAudioChannelSwapResolver()
    let config = appConfigStore().config.channelSwap
    // ⚠ 回落路径不能传 "BlackHole" 作为 namePrefix —— 那是**输入**设备的命名约定，
    //    会把源设备当成目标设备解析出来（我第一版就是这个 bug，
    //    `tkctl mix show` 于是显示"目标设备: BlackHole 16ch"）。
    let output = config.outputDeviceUID.flatMap { uid in
        uid.isEmpty ? nil : resolver.device(uid: uid, namePrefix: "")
    } ?? resolver.preferredOutputDevice(excludingNamePrefix: "BlackHole")
    guard let output else { return nil }
    return (output, resolver.declaredChannelIndices(of: output))
}

private func mixShow() {
    let config = appConfigStore().config
    let s = config.channelSwap
    print("\nLFE 混音配置")
    print("  开关:        \(s.mixEnabled ? "启用" : "停用")")
    let db = s.mixGainDB
    let gain = LfeMixPlan.gain(fromDB: db)
    print(String(format: "  增益:        %.1fdB（线性 %.4f）", db, gain))
    let srcDesc = "第 \(s.mixSourceChannel) 声道"
        + (s.mixSourceChannel == LfeMixPlan.defaultInputChannel ? "（默认，实测的低音通道）" : "")
    let tgtDesc = "第 \(s.mixTargetChannel) 声道"
        + (s.mixTargetChannel == LfeMixPlan.defaultOutputChannel ? "（默认，macOS 默认中置）" : "")
    print("  输入声道:    \(srcDesc)   ← CH\(s.mixSourceChannel)-I（BlackHole 缓冲区）")
    print("  输出声道:    \(tgtDesc)   ← CH\(s.mixTargetChannel)-O（真实设备）")
    // ⚠ 上游(I)/下游(O) 是两个空间，编号相同合法 —— 这里不做任何"无效组合"判断

    print("  允许范围:    \(LfeMixPlan.gainRangeDB.lowerBound)…\(LfeMixPlan.gainRangeDB.upperBound) dB")

    guard let (output, declared) = mixDeclaredIndices() else {
        print("  [注意] 找不到目标设备，无法解析实际混音位置")
        print("")
        return
    }
    // ⚠ 必须**同时**检查 `isEnabled` 与"计划是否恒等"：
    //    `plan(forOutputChannels:)` 只描述"若交换会怎么换"，
    //    即使交换功能**处于停用**它也会返回一个非恒等计划。
    //    （我第一版只看计划，于是"停用交换"后仍被报成"交换生效"，
    //      进而把混音误判成互斥不可用。）
    let swapPlan = s.isEnabled ? s.plan(forOutputChannels: output.usableChannels) : nil
    let effectiveSwap = (swapPlan?.isIdentity ?? true) ? nil : swapPlan
    let plan = s.mixPlan(forOutputChannels: output.usableChannels,
                         declared: declared,
                         swapPlan: effectiveSwap)
    print("")
    print("目标设备:      \(output.name)（\(output.usableChannels) 声道）")
    print("  设备声明:    \(declared.map(CoreAudioHelpers.describe) ?? "读不到 —— 将回落到默认值")")
    print("  交换态势:    \(effectiveSwap == nil ? "未交换（恒等）" : "交换 \(s.swapDescription)")")

    // ★ 互斥检查放在最前：这是"配置非法"而不是"计划不可用"，
    //   必须给出**明确原因**，不能把内部哨兵（0 声道）当成技术错误暴露出去。
    if effectiveSwap != nil && s.mixEnabled {
        print("")
        print("  [失败] **混音当前不生效**：「交换」与「混音」互斥，两者同时开启时以交换为准。")
        print("     请执行 `tkctl swap disable` 或 `tkctl mix disable` 关掉其中一个。")
        print("     为什么互斥（两者对应不同的音响条件）：")
        print("       交换 → 音响**有**低音炮，只是软件把 C/LFE 输出反了")
        print("       混音 → 音响**没有**低音炮，需把低音搬到中置")
        print("")
        return
    }

    // 混音没开时不必解析计划：直接说清楚"当前用的是什么"，
    // 免得把内部的"不可用"哨兵当成技术错误暴露出去。
    guard s.mixEnabled else {
        print("  * 实际混音:  未启用（当前使用：\(effectiveSwap != nil ? "声道交换" : "两者都未启用")）")
        print("")
        print("提示：引擎状态只在 App 进程内可得；本命令显示的是持久化配置与解析结果。")
        print("")
        return
    }

    print("  * 实际混音:  \(s.mixDescription(channels: output.usableChannels, declared: declared, swapPlan: effectiveSwap))")
    if let r = plan.resolved() {
        // ★ 把完整接线画出来 —— 这是本功能的核心，纯文字描述最容易误解。
        //   规律（4 组实测用例确认）：
        //     · 直通的输入 = 与 CH-O **不同**的那条输入
        //     · 不连的下游 = 与 CH-O **不同**的那条下游
        //     · 衰减施加在用户选中的那条 CH-I 上
        let g = String(format: "%.3f", r.gain)
        let pair = LfeMixPlan.selectableChannels
        let other = { (ch: Int) in ch == pair.lowerBound ? pair.upperBound : pair.lowerBound }
        let direct = other(r.inputChannel)    // 直通的输入：与 CH-I 不同的那条
        let cut = other(r.outputChannel)      // 不连的下游：与 CH-O 不同的那条
        print("     * 接线：")
        print("        CH\(r.inputChannel)-I ──[× \(g)]──* CH\(r.outputChannel)-O   （选中的那条：衰减）")
        print("        CH\(direct)-I ──────────────* CH\(r.outputChannel)-O   （直通，不衰减）")
        print("        CH\(cut)-O                  x            （不连 ⇒ 静音）")
        print("        其余声道（L/R、环绕）───* 原样直通")
        print("     → 结果：CH\(r.outputChannel)-O = "
              + "CH\(direct)-I + CH\(r.inputChannel)-I × \(g)")
        // ★ 把**实际索引**写清楚：排查时直接与 PLVS 的通道号对照，不靠名称推断
        let rateIdx = r.inputAPIIndex
        let directIdx = other(r.inputChannel) - 1
        let targetIdx = r.outputAPIIndex
        let cutIdx = other(r.outputChannel) - 1
        print("     → 实际索引：读 plane[\(rateIdx)]（衰减那条） + plane[\(directIdx)]（直通那条）"
              + "  →  写 output[\(targetIdx)]")
        print("       output[\(cutIdx)] = 0；其余 output 原样")
    } else {
        print("     [失败] 计划不可用：\(plan.unavailableReason ?? "参数不合法")")
    }
    print("")
    print("提示：引擎状态只在 App 进程内可得；本命令显示的是持久化配置与解析结果。")
    print("")
}

private func mixSetEnabled(_ enabled: Bool) {
    let store = appConfigStore()
    var turnedOffSwap = false
    store.update { cfg in
        cfg.channelSwap.mixEnabled = enabled
        // ★ 互斥：开了混音就关交换
        if enabled && cfg.channelSwap.isEnabled {
            cfg.channelSwap.isEnabled = false
            turnedOffSwap = true
        }
    }
    if turnedOffSwap { print("（已自动关闭「声道交换」—— 两者互斥）") }
    print("已\(enabled ? "启用" : "停用")LFE 混音（App 会在配置变更后自动重新应用）")
    notifyAppToReload()
}

private func mixSetGain(_ db: Double) {
    let clamped = min(max(db, LfeMixPlan.gainRangeDB.lowerBound), LfeMixPlan.gainRangeDB.upperBound)
    let store = appConfigStore()
    store.update { $0.channelSwap.mixGainDB = clamped }
    if clamped != db {
        print("[注意] 增益 \(db)dB 超出允许范围，已钳制到 \(clamped)dB")
    }
    print(String(format: "混音增益已设为 %.1fdB（线性 %.4f）", clamped, LfeMixPlan.gain(fromDB: clamped)))
    notifyAppToReload()
}

/// `tkctl mix source <n>`：选择**衰减并从它取低音**的声道（3 或 4）。
/// 目标由配对推导（另一条），所以不需要单独配置。
private func mixSetSource(_ value: String) {
    guard let n = Int(value), LfeMixPlan.selectableChannels.contains(n) else {
        let allowed = LfeMixPlan.selectableChannels
            .map { "第 \($0) 声道" }.joined(separator: " / ")
        print("[失败] 只能指定 \(allowed)（实测这两个声道的组合就是 C/LFE 那一对）")
        return
    }
    let store = appConfigStore()
    store.update { $0.channelSwap.mixSourceChannel = n }
    print("已选择衰减第 \(n) 声道（混音目标不变：第 \(store.config.channelSwap.mixTargetChannel) 声道）")
    if n == LfeMixPlan.defaultInputChannel {
        print("  （第 3 声道 = 实测的低音通道，是默认值）")
    } else {
        print("  [注意] 非默认：适用于「软件把 C/LFE 顺序写反」的情况")
    }
    notifyAppToReload()
}

/// `tkctl mix target <n>`：选择把衰减后的内容叠加到哪条声道（3 或 4）。
/// 与来源**独立**设置 —— 输入侧情况复杂时由用户自行判断。
private func mixSetTarget(_ value: String) {
    guard let n = Int(value), LfeMixPlan.selectableChannels.contains(n) else {
        let allowed = LfeMixPlan.selectableChannels
            .map { "第 \($0) 声道" }.joined(separator: " / ")
        print("[失败] 只能指定 \(allowed)")
        return
    }
    let store = appConfigStore()
    store.update { $0.channelSwap.mixTargetChannel = n }
    print("混音目标已设为 CH\(n)-O（输出声道）")
    print("  （输入声道不变：CH\(store.config.channelSwap.mixSourceChannel)-I；"
          + "两者是不同空间，编号相同也合法）")
    notifyAppToReload()
}

/// `tkctl mix monitor [秒数]`：启动混音通路并**实时打印每路输出峰值**。
///
/// 为什么需要它：混音方向对不对，靠"看 PLVS 波形"容易被路由/命名干扰；
/// 直接量出每条**下游输出声道**的电平才是硬证据。
/// 用法：另开一个终端放音乐，然后看下面哪个 CH-O 有电平、哪个是 0。
private func mixMonitor(seconds: Double) {
    let store = appConfigStore()
    let s = store.config.channelSwap
    guard s.mixEnabled else {
        print("[失败] 混音未启用。先执行：tkctl mix enable")
        return
    }
    let r = swapResolver()
    guard let input = r.device(uid: nil, namePrefix: "BlackHole"),
          let output = r.preferredOutputDevice(excludingNamePrefix: "BlackHole") else {
        print("[失败] 找不到 BlackHole 或目标设备"); return
    }
    let declared = r.declaredChannelIndices(of: output)
    let plan = s.mixPlan(forOutputChannels: output.usableChannels,
                         declared: declared, swapPlan: nil)
    guard let mix = plan.resolved() else {
        print("[失败] 混音计划不可用：\(plan.unavailableReason ?? "参数不合法")"); return
    }
    // 交换关闭 ⇒ 恒等映射
    let identity = ChannelSwapPlan(sourceChannelCount: output.usableChannels,
                                   firstChannel: 1, secondChannel: 1)
    let driver = ChannelSwapAudioDriver()
    print("\n混音监视 \(Int(seconds)) 秒：\(mix.description)")
    print("  * 请**另开终端播放音乐**，然后看下面哪条 CHn-O 有电平")
    if let declared { print("  设备声明：\(CoreAudioHelpers.describe(declared))") }
    let other = { (ch: Int) in
        ch == LfeMixPlan.selectableChannels.lowerBound
            ? LfeMixPlan.selectableChannels.upperBound
            : LfeMixPlan.selectableChannels.lowerBound
    }
    let directCh = other(mix.inputChannel)
    print("  预期：CH\(mix.outputChannel)-O = CH\(directCh)-I + CH\(mix.inputChannel)-I × "
          + String(format: "%.3f", mix.gain))
    print("        CH\(other(mix.outputChannel))-O = 0（不连）")
    do {
        _ = try driver.start(plan: identity, input: input, output: output,
                             outputIsSystemDefault: (r.defaultOutputDevice()?.uid == output.uid),
                             mix: mix)
    } catch {
        print("[失败] 启动失败：\(error)"); return
    }
    var tick = 0
    while tick < Int(seconds) {
        Thread.sleep(forTimeInterval: 1)
        tick += 1
        let st = driver.stats()
        let peaks = st.channelPeaks.enumerated()
            .map { "CH\($0.offset + 1)-O=\(String(format: "%.4f", $0.element))" }
            .joined(separator: " ")
        print("[\(tick)s] \(peaks)")
    }
    let final = driver.stats()
    driver.stop()
    print("\n输入读取情况：帧 \(final.framesIn)、非零 \(final.nonZeroInFrames)、"
          + "渲染失败 \(final.renderFailures)")
    if final.nonZeroInFrames == 0 {
        print("  [注意] 输入端是静音 —— 本命令读 BlackHole 需要**麦克风授权**，")
        print("     命令行程序通常没有。要验证混音逻辑请用 `tkctl mix verify`（用内置自测信号）；")
        print("     要验证端到端请直接放音乐并听 App 的输出。")
    }
    print("\n判读：")
    print("  · CH\(mix.outputChannel)-O 应明显大于 0（有输出）")
    print("  · CH\(other(mix.outputChannel))-O 应为 0（不连）")
    print("  · 其余 CHn-O 应与不放音乐时一致（直通，峰值为 0 说明该路本来就没内容）")
}

/// `tkctl mix verify`：**不需要任何音频输入**的客观验证。
///
/// 原理：驱动的诊断自测会在**每条上游 plane** 上合成一个 0.5 幅度的逐段序列。
/// 于是"哪条输入去了哪条输出、有没有被衰减"可以直接从**每路输出峰值**读出来。
///
/// 期望（gain=0.316）：
///   CH-O  = 直通那条(0.5) + 被衰减那条(0.5×0.316=0.158) = 0.658（两段轮流）
///   被切断的那条 downstream = 0
/// 这是判断"混音到底有没有按预期接线"的**硬证据**，比看 PLVS 波形可靠。
private func mixVerify(seconds: Double) {
    let s = appConfigStore().config.channelSwap
    let r = swapResolver()
    guard let input = r.device(uid: nil, namePrefix: "BlackHole"),
          let output = r.preferredOutputDevice(excludingNamePrefix: "BlackHole") else {
        print("[失败] 找不到设备"); return
    }
    let declared = r.declaredChannelIndices(of: output)
    let plan = s.mixPlan(forOutputChannels: output.usableChannels,
                         declared: declared, swapPlan: nil)
    guard let mix = plan.resolved() else {
        print("[失败] 混音计划不可用：\(plan.unavailableReason ?? "参数不合法")"); return
    }
    let pair = LfeMixPlan.selectableChannels
    let other = { (ch: Int) in ch == pair.lowerBound ? pair.upperBound : pair.lowerBound }
    let directCh = other(mix.inputChannel)
    let cutCh = other(mix.outputChannel)
    let expected = 0.5 + 0.5 * Double(mix.gain)

    print("\n混音客观验证（用合成序列，无需播放内容）")
    print("  配置：CH\(mix.inputChannel)-I 衰减 ×\(String(format: "%.3f", mix.gain))"
          + " → CH\(mix.outputChannel)-O；CH\(directCh)-I 直通")
    print("  期望：CH\(mix.outputChannel)-O 出现两种峰值 → 直通段 ≈0.500、混合段 ≈"
          + String(format: "%.3f", expected))
    print("        CH\(cutCh)-O 恒为 0")
    print("  [成功] 本命令用驱动内置自测信号，**不读 BlackHole、不受麦克风授权影响**，")
    print("     因此结论只反映「输出侧 + 混音接线」是否正确。")
    print("     若这里正确但实际放音仍不对，问题在输入端（BlackHole 读取 / TCC）。")

    let identity = ChannelSwapPlan(sourceChannelCount: output.usableChannels,
                                   firstChannel: 1, secondChannel: 1)
    let driver = ChannelSwapAudioDriver()
    do {
        _ = try driver.start(plan: identity, input: input, output: output,
                             outputIsSystemDefault: (r.defaultOutputDevice()?.uid == output.uid),
                             mix: mix)
    } catch {
        print("[失败] 启动失败：\(error)"); return
    }
    // ★ 用驱动内置的**自测信号**：不读 BlackHole ⇒ 不受麦克风授权影响，
    //   也不需要外部播放内容。量的就是"输出侧 + 混音接线"是否正确。
    //   注意必须在 start() **之后**设：start() 内部会先 stop() 做幂等清理。
    driver.selfTestSignal = true
    var tick = 0
    while tick < Int(seconds) {
        Thread.sleep(forTimeInterval: 0.7)
        tick += 1
        let st = driver.stats()
        let peaks = st.channelPeaks.enumerated()
            .map { "CH\($0.offset + 1)-O=\(String(format: "%.4f", $0.element))" }
            .joined(separator: " ")
        print("[\(tick)] 入回调 \(st.inputCallbackCount) / 出回调 \(st.outputCallbackCount)"
              + " / 帧出 \(st.framesOut) | \(peaks)")
    }
    driver.stop()

    // 自动判读
    let st = driver.stats()
    print("\n判读：")
    if mix.outputAPIIndex < st.channelPeaks.count {
        let v = st.channelPeaks[mix.outputAPIIndex]
        print("  CH\(mix.outputChannel)-O 峰值 = \(String(format: "%.4f", v))"
              + (v > 0.4 ? "  有输出" : "  几乎没有输出"))
    }
    if cutCh - 1 < st.channelPeaks.count {
        let v = st.channelPeaks[cutCh - 1]
        print("  CH\(cutCh)-O 峰值 = \(String(format: "%.4f", v))"
              + (v == 0 ? "  已切断" : "  未切断（应为 0）"))
    }
}

func cmdMix(_ args: [String]) {
    let sub = args.first ?? "show"
    switch sub {
    case "show":    mixShow()
    case "monitor": mixMonitor(seconds: args.count >= 2 ? (Double(args[1]) ?? 10) : 10)
    case "verify":  mixVerify(seconds: args.count >= 2 ? (Double(args[1]) ?? 3) : 3)
    case "enable":  mixSetEnabled(true)
    case "disable": mixSetEnabled(false)
    case "gain":    args.count >= 2 ? mixSetGain(Double(args[1]) ?? LfeMixPlan.defaultGainDB)
                                    : print("用法: tkctl mix gain <dB>（\(LfeMixPlan.gainRangeDB.lowerBound)…\(LfeMixPlan.gainRangeDB.upperBound)）")
    case "source":  args.count >= 2 ? mixSetSource(args[1])
                                    : print("用法: tkctl mix source <3|4>")
    case "target":  args.count >= 2 ? mixSetTarget(args[1])
                                    : print("用法: tkctl mix target <3|4>")
    default:
        print("""
        mix 子命令（LFE 混音：把选中的那条输入声道内容衰减后混入 CHn-O）：
          show                显示配置 + **接线图** + 实际索引
          verify  [秒]        * 客观验证：内置自测信号，无需播放内容/不受麦克风授权影响
          monitor [秒]        实时打印每路输出峰值（需 BlackHole 有音频流过）
          enable | disable    开关（写配置，**运行中的 App 会立即重新应用**）
          gain <dB>           增益（默认 \(LfeMixPlan.defaultGainDB)dB，范围 \(LfeMixPlan.gainRangeDB.lowerBound)…\(LfeMixPlan.gainRangeDB.upperBound)）
          source <3|4>        输入声道 CHn-I：从 BlackHole 哪条缓冲区读（默认 3）
          target <3|4>        输出声道 CHn-O：衰减并叠加输入内容的目标（默认 4）

        * 输入声道(I) 与输出声道(O) 是**两个空间**，编号相同完全合法：
            两条输入声道都进 CHn-O —— 选中的那条 × gain，另一条直通；
            与 CHn-O 不同的那条输出声道不连 ⇒ 静音；其余声道照常直通。
          例：source 3 + target 4 → CH4-O = CH4-I + CH3-I × gain；CH3-O = 0

        [注意] 「交换」与「混音」互斥（对应两种音响条件）：
            交换 → 音响**有**低音炮，只是软件把 C/LFE 输出反了
            混音 → 音响**没有**低音炮
          开启一个会自动关闭另一个。

        [注意] `monitor` 读 BlackHole 需要**麦克风授权**，命令行程序通常没有
           ⇒ 它常显示全 0；判断混音逻辑请用 `verify`。
        """)
    }
}

private func swapSetEnabled(_ enabled: Bool) {
    let store = appConfigStore()
    var turnedOffMix = false
    store.update { cfg in
        cfg.channelSwap.isEnabled = enabled
        // ★ 互斥：开了交换就关混音（两者对应不同的音响条件，见 `tkctl mix help`）
        if enabled && cfg.channelSwap.mixEnabled {
            cfg.channelSwap.mixEnabled = false
            turnedOffMix = true
        }
    }
    if turnedOffMix { print("（已自动关闭「LFE 混音」—— 两者互斥）") }
    print("已\(enabled ? "启用" : "停用")声道交换（App 会在配置变更后自动重新应用）")
    notifyAppToReload()
}

/// 前台跑一次真实交换：读 BlackHole → 交换 → 写目标设备
private func swapRun(seconds: Double) {
    let r = swapResolver()
    guard let input = r.device(uid: nil, namePrefix: "BlackHole") else {
        print("[失败] 未找到 BlackHole 输入设备"); return
    }
    guard let output = r.preferredOutputDevice(excludingNamePrefix: "BlackHole") else {
        print("[失败] 未找到 ≥\(ChannelSwapPlan.minimumChannelCount) 声道的输出设备"); return
    }
    // ★ 交换是否真的生效，由设置决定；只开混音时必须用**恒等**计划，
    //   否则会按默认的 3↔4 平白对调 C/LFE，让混音的语义错位。
    //   （`swap run` 这条诊断路径以前无条件按 3↔4 交换，是个陷阱。）
    let cfg = appConfigStore().config.channelSwap
    let swapWanted = cfg.isEnabled
    let plan = ChannelSwapPlan(sourceChannelCount: output.outputChannels,
                               firstChannel: swapWanted ? cfg.firstChannel : 1,
                               secondChannel: swapWanted ? cfg.secondChannel : 1)
    guard plan.swapMap != nil else {
        print("[失败] 目标设备声道数不足，无法交换"); return
    }

    print("\n声道交换试跑 \(Int(seconds)) 秒")
    print("  源:   \(input.name)（输入 \(input.inputChannels) 声道，\(Int(input.nominalSampleRate))Hz）")
    print("  目标: \(output.name)（\(output.outputChannels) 声道，\(Int(output.nominalSampleRate))Hz）")
    print("  交换: \(swapWanted ? plan.swapDescription : "未启用（恒等映射）")")

    // 采样率对齐（只写输入设备）
    if abs(input.nominalSampleRate - output.nominalSampleRate) > 0.5 {
        let status = r.setNominalSampleRate(output.nominalSampleRate, on: input)
        print("  采样率对齐: BlackHole → \(Int(output.nominalSampleRate))Hz "
              + "(\(status == noErr ? "noErr" : "失败 \(status)"))")
    }

    let driver = ChannelSwapAudioDriver()
    let isDefault = (r.defaultOutputDevice()?.uid == output.uid)
    print("  输出单元: \(isDefault ? "DefaultOutput" : "HALOutput（绑设备）")")
    // ★ LFE 混音（与交换互斥，正常只会有一个启用）
    let config = appConfigStore().config
    let swapped = config.channelSwap.isEnabled
    let mixResolved: LfeMixPlan.Resolved? = {
        guard config.channelSwap.mixEnabled, !swapped else { return nil }
        let declared = r.declaredChannelIndices(of: output)
        return config.channelSwap
            .mixPlan(forOutputChannels: output.usableChannels, declared: declared, swapPlan: nil)
            .resolved()
    }()
    if let m = mixResolved {
        // 与 mix show / UI 用**同一套规则**生成描述，避免三处文字各自漂移
        // （"手写说明与实现不一致"这几轮已经坑过两次）
        let pair = LfeMixPlan.selectableChannels
        let other = { (ch: Int) in ch == pair.lowerBound ? pair.upperBound : pair.lowerBound }
        let g = String(format: "%.3f", m.gain)
        print("  * LFE 混音: \(m.description)")
        print("     CH\(m.outputChannel)-O = CH\(other(m.inputChannel))-I + CH\(m.inputChannel)-I × \(g)")
        print("     CH\(other(m.outputChannel))-O = 0（不连）")
    }
    do {
        let map = try driver.start(plan: plan, input: input, output: output,
                                  outputIsSystemDefault: isDefault, mix: mixResolved)
        print("  * ChannelMap（API 0-based）= \(map)  ← 已写入并回读")
        print("\n跑起来了。请播放音频（经 BlackHole 路由），或另开终端观察。\n")
        var tick = 0
        let total = Int(seconds)
        while tick < total {
            Thread.sleep(forTimeInterval: 1)
            tick += 1
            let st = driver.stats()
            print("[\(tick)s] 输入回调 \(st.inputCallbackCount) / 帧 \(st.framesIn)"
                  + " | 输出回调 \(st.outputCallbackCount) / 帧 \(st.framesOut)"
                  + " | 欠载 \(st.underruns) | 渲染失败 \(st.renderFailures)")
            if !st.channelPeaks.isEmpty {
                let outs = st.channelPeaks.enumerated()
                    .map { "CH\($0.offset + 1)-O=\(String(format: "%.4f", $0.element))" }
                    .joined(separator: " ")
                print("        输出声道：\(outs)")
                // 被切断的声道会显示 0，正好用来核对"上游那条的输出关掉了没"
                if let m = mixResolved, m.inputChannel != m.outputChannel,
                   m.inputAPIIndex < st.channelPeaks.count {
                    let cut = st.channelPeaks[m.inputAPIIndex]
                    print("        * CH\(m.inputChannel)-O（被切断的那条）当前峰值 = "
                          + "\(String(format: "%.4f", cut))"
                          + (cut == 0 ? "  已切断" : "  未切断（应为 0）"))
                }
            }
        }
        driver.stop()
        print("\n已停止。")
    } catch {
        print("[失败] 启动失败：\(error)")
    }
}

/// 自测：用**生产版驱动**（`ChannelSwapAudioDriver`）播逐段序列并交换。
///
/// 为什么需要它：交换此前只在 `DefaultOutput` 上被听感确认，
/// 而 App 在"目标设备 ≠ 系统默认输出"时走 `HALOutput` 绑设备路径。
/// 本命令直接跑**生产驱动**，因此验证的就是 App 真正执行的代码。
///
/// 用法：`tkctl swap selftest [秒] [--swap a,b]`
///   默认交换 第3↔第4 声道（中置↔低音）。想一眼看出来就换左右：
///     tkctl swap selftest 20 --swap 1,2
private func swapSelfTest(seconds: Double, swapPair: (Int, Int)?) {
    let r = swapResolver()
    guard let output = r.preferredOutputDevice(excludingNamePrefix: "BlackHole") else {
        print("[失败] 未找到 ≥\(ChannelSwapPlan.minimumChannelCount) 声道的输出设备"); return
    }
    guard let input = r.device(uid: nil, namePrefix: "BlackHole") else {
        print("[失败] 未找到 BlackHole（自测也需要它来占位输入单元）"); return
    }
    let first = swapPair?.0 ?? ChannelSwapPlan.defaultFirstChannel
    let second = swapPair?.1 ?? ChannelSwapPlan.defaultSecondChannel
    let plan = ChannelSwapPlan(sourceChannelCount: output.outputChannels,
                               firstChannel: first, secondChannel: second)
    guard let map = plan.swapMap else {
        print("[失败] 交换计划不可用（声道数不足或声道号越界）"); return
    }

    let isDefault = (r.defaultOutputDevice()?.uid == output.uid)
    print("\n自测（走**生产版驱动**）")
    print("  源占位: \(input.name)（自测不读它的音频，只借它作输入单元）")
    print("  目标:   \(output.name)（\(output.outputChannels) 声道）")
    print("  输出单元: \(isDefault ? "DefaultOutput（目标就是系统默认输出）" : "HALOutput 绑设备（目标≠系统默认输出）")")
    print("  交换:   \(plan.swapDescription)")
    print("  置换表(API 0-based): \(map)")
    print("")
    print("播放内容：逐段序列，第 i 段只有第 i 个声道出声（频率 200+100*i）")
    for ch in 1...output.outputChannels {
        var freq = 200.0 + 100.0 * Double(ch - 1)
        // 交换后该声道实际发出的是"源第 map[ch-1] 声道"的频率
        let srcIdx = Int(map[ch - 1])
        freq = 200.0 + 100.0 * Double(srcIdx)
        let sem = ChannelSwapPlan.semanticName(forChannel: ch) ?? ""
        print(String(format: "  第 %d 段 = 第 %d 声道(%@) → 应听到 %4.0fHz", ch, ch, sem, freq))
    }
    let f1 = 200.0 + 100.0 * Double(Int(map[first - 1]))
    let f2 = 200.0 + 100.0 * Double(Int(map[second - 1]))
    print("")
    print("* 关键对照：第 \(first) 段应响 \(Int(f1))Hz、第 \(second) 段应响 \(Int(f2))Hz")
    if first == 1 && second == 2 {
        print("  （左右互换：第 1 段应是 300Hz、第 2 段应是 200Hz —— 顺序与未交换时相反）")
    }
    print("")

    let driver = ChannelSwapAudioDriver()
    driver.diagnosticToneEnabled = true
    do {
        _ = try driver.start(plan: plan, input: input, output: output,
                             outputIsSystemDefault: isDefault)
        var tick = 0
        while tick < Int(seconds) {
            Thread.sleep(forTimeInterval: 1)
            tick += 1
            let st = driver.stats()
            print("[\(tick)s] 帧 \(st.framesIn) / \(st.framesOut) | 欠载 \(st.underruns)"
                  + " | 渲染失败 \(st.renderFailures)")
        }
        driver.stop()
        print("\n已停止。")
    } catch {
        print("[失败] 启动失败：\(error)")
    }
}

// MARK: - 入口

let argv = Array(CommandLine.arguments.dropFirst())
guard let command = argv.first else {
    printUsage()
    exit(0)
}

switch command {
case "list":        cmdList()
case "capability":  argv.count >= 2 ? cmdCapability(argv[1]) : printUsage()
case "status":      argv.count >= 2 ? cmdStatus(argv[1]) : printUsage()
case "apply":       cmdApply(Array(argv.dropFirst()))
case "lock":        cmdLock(Array(argv.dropFirst()))
case "seed":        cmdSeed(Array(argv.dropFirst()))
case "showconfig":  cmdShowConfig()
case "clearconfig": cmdClearConfig()
case "agent":       cmdAgent(Array(argv.dropFirst()))
case "logs":        cmdLogs(Array(argv.dropFirst()))
case "swap":        cmdSwap(Array(argv.dropFirst()))
case "mix":         cmdMix(Array(argv.dropFirst()))
case "help", "-h", "--help": printUsage()
default:
    print("未知命令: \(command)\n")
    printUsage()
    exit(1)
}
