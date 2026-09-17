import AppKit
import Combine
import Foundation
import TopologyKeeperCore

/// UI 状态。只在主线程访问（`@MainActor`）。
///
/// 与引擎的边界只传**值类型快照**（`RuleSnapshot` / `LogEntry`），
/// 不共享任何可变引用。
@MainActor
final class AppState: ObservableObject {

    @Published private(set) var snapshots: [RuleSnapshot] = []
    @Published private(set) var logEntries: [LogEntry] = []
    @Published var logExpanded: Bool = false
    @Published var lastError: String?

    /// 声道交换的当前状态（由 swapEngine 在 swapQueue 上推送，已 hop 到主线程）
    @Published private(set) var swapState: ChannelSwapState = .disabled
    /// 声道交换的诊断快照（打开面板/切换开关后刷新）
    @Published private(set) var swapDiagnostics = ChannelSwapDiagnostics()

    private let environment: AppEnvironment
    private let notifier = Notifier()

    /// 通知可用性（设置界面展示用）
    var notificationAvailability: Notifier.Availability { notifier.availability }

    /// 日志落盘路径（设置界面展示用）
    var logFilePath: String? { Log.shared.logFilePath }

    /// 上一轮日志备份的路径（`…log.1`）；不存在时为 nil。
    ///
    /// 启动时会做一次轮转（见 `Log.resetLogFileOnLaunch`），所以**上一轮的现场**
    /// 就在这个文件里 —— 设置页给它一个独立的入口，否则用户根本找不到。
    var rotatedLogFilePath: String? { Log.shared.rotatedLogFilePath }

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    // MARK: - 生命周期

    func start() {
        applyLogPreferences()
        reconcileLaunchAtLogin()
        if environment.store.config.showNotifications {
            notifier.requestAuthorizationIfNeeded()
        }

        environment.start { [weak self] snapshots in
            // 回调在 audioQueue 上，hop 到主线程
            DispatchQueue.main.async {
                self?.handleSnapshotUpdate(snapshots)
            }
        } notify: { [weak self] message in
            // 声道处理穷尽重试后的告警（用户确认：1-2-4-8 秒后仍不成功则提示）
            // 标题按**当前生效的模式**取名 —— 混音失败时不该说"声道交换未能启动"，
            // 直通（两个功能都关、但引擎开着）失败时同理。
            DispatchQueue.main.async {
                guard let self else { return }
                let mode = self.config.channelSwap.processingMode
                let function = mode == .passThrough ? "声道直通" : mode.displayName
                self.notifier.post(title: "\(function)未能启动", body: message)
                self.lastError = message
            }
        } publishSwapState: { [weak self] state in
            DispatchQueue.main.async {
                self?.swapState = state
                self?.lastError = state.needsAttention ? state.displayText : nil
            }
        }
        Log.shared.addObserver { [weak self] entry in
            DispatchQueue.main.async {
                self?.appendLog(entry)
            }
        }
        // 先灌入已有日志（observer 只能拿到增量）
        self.logEntries = Log.shared.snapshot()
        environment.refresh()
    }

    /// 快照更新：记录变更 + 在状态跃迁时发通知。
    ///
    /// 只在**状态真的变了**时才通知 —— 否则每次评估都会重复打扰。
    private func handleSnapshotUpdate(_ new: [RuleSnapshot]) {
        let previous = snapshots
        snapshots = new

        guard environment.store.config.showNotifications else { return }

        for snapshot in new {
            let old = previous.first { $0.ruleID == snapshot.ruleID }
            guard old?.state != snapshot.state else { continue }
            switch snapshot.state {
            case .locked where old?.state == .applying:
                notifier.notifyLocked(deviceName: snapshot.deviceName,
                                      preset: snapshot.preset.displayString)
            case .failed(let kind):
                notifier.notifyFailed(deviceName: snapshot.deviceName,
                                      reason: kind.displayText)
            default:
                break
            }
        }

        persistRuntimeDiagnostics(from: previous, to: new)
    }

    /// 把运行时诊断写回配置，让重启后仍能看到上次结果。
    ///
    /// 只在状态真正跃迁时写，避免每次评估都打 UserDefaults。
    private func persistRuntimeDiagnostics(from previous: [RuleSnapshot],
                                           to current: [RuleSnapshot]) {
        for snapshot in current {
            let old = previous.first { $0.ruleID == snapshot.ruleID }
            guard old?.state != snapshot.state else { continue }
            switch snapshot.state {
            case .locked where old?.state == .applying:
                environment.store.recordRuntime(ruleID: snapshot.ruleID,
                                                lastAppliedAt: snapshot.lastAppliedAt ?? Date(),
                                                lastError: nil,
                                                failures: 0)
            case .failed(let kind):
                environment.store.recordRuntime(ruleID: snapshot.ruleID,
                                                lastAppliedAt: snapshot.lastAppliedAt,
                                                lastError: kind.displayText,
                                                failures: snapshot.consecutiveFailures)
            default:
                break
            }
        }
    }

    private func applyLogPreferences() {
        let config = environment.store.config
        Log.shared.configure(capacity: config.logRingCapacity, echoToStderr: false)
        Log.shared.configureFileLogging(enabled: config.recordLogToFile)
    }
    func stop() {
        environment.stop()
    }

    private func appendLog(_ entry: LogEntry) {
        logEntries.append(entry)
        let capacity = environment.store.config.logRingCapacity
        if logEntries.count > capacity {
            logEntries.removeFirst(logEntries.count - capacity)
        }
    }

    // MARK: - 聚合状态（菜单栏图标）

    /// 菜单栏总状态。规则全部停用时立即变为"未启用锁定"（图标 waveform.slash）。
    var aggregateState: LockState {
        LockStateAggregator.aggregate(snapshots)
    }

    var statusIconName: String { aggregateState.iconName }

    var statusSummary: String {
        LockStateAggregator.summary(snapshots)
    }

    var allRulesDisabled: Bool {
        LockStateAggregator.allDisabled(snapshots)
    }

    var hasFailure: Bool {
        snapshots.contains { if case .failed = $0.state { return true }; return false }
    }

    // MARK: - 配置访问

    var config: AppConfig { environment.store.config }

    func updateConfig(_ body: (inout AppConfig) -> Void) {
        // ★ 唯一收口点：强制"声道交换"与"LFE 混音"互斥（用户确认的产品定义）。
        //   放在这里而不是各个调用点 —— 漏掉任何一条路径都会形成非法组合，
        //   而非法组合的表现是"混音看起来开着、实际不生效"（静默失效）。
        //   规则：以 body 执行后的结果为准，若两者同时为真，则**保留后开启的那个**，
        //   关掉另一个（body 里通常是刚被改的那一个）。
        environment.store.update { cfg in
            let before = (swap: cfg.channelSwap.isEnabled, mix: cfg.channelSwap.mixEnabled)
            body(&cfg)
            let after = (swap: cfg.channelSwap.isEnabled, mix: cfg.channelSwap.mixEnabled)
            guard after.swap && after.mix else { return }
            if after.mix != before.mix {
                cfg.channelSwap.isEnabled = false      // 刚开了混音 → 关交换
            } else if after.swap != before.swap {
                cfg.channelSwap.mixEnabled = false     // 刚开了交换 → 关混音
            } else {
                cfg.channelSwap.mixEnabled = false     // 两者都已开（非法态）→ 保留交换
            }
        }
        applyLogPreferences()
        environment.configDidChange()
        // ★ 声道交换是独立引擎，必须单独把新设置推给它 ——
        //   只调 configDidChange() 只会通知 RuleEngine，开关会"看起来没反应"。
        environment.applyChannelSwap(environment.store.config.channelSwap)
        // 设置生效是异步的，稍后刷新一次诊断以反映真实状态
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.refreshSwapDiagnostics()
        }
    }

    /// 手动开启通知授权（设置界面按钮）
    func requestNotificationAuthorization() {
        notifier.requestAuthorizationIfNeeded()
    }

    /// 在访达里显示日志文件
    func revealLogFile() {
        guard let path = Log.shared.logFilePath else { return }
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }

    /// 在访达里显示**上一轮**的日志备份
    func revealRotatedLogFile() {
        guard let path = Log.shared.rotatedLogFilePath else { return }
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }

    func ruleForEditing(_ ruleID: UUID) -> DeviceRule? {
        environment.store.config.rules.first { $0.id == ruleID }
    }

    // MARK: - 自启动

    private static let launchManager = LaunchAtLoginManager()

    var launchAtLoginMode: LaunchAtLoginMode { Self.launchManager.mode }

    /// 开机自启动的**实际**状态（以 LaunchAgent 文件是否存在为准）。
    ///
    /// ⚠️ 不能只读 `config.launchAtLogin`：配置只是一个"意愿"记录，
    /// 真实状态由 plist 决定。两者会脱节（例如 plist 被手工删掉、
    /// 或 App 被移动到别的路径导致旧 plist 失效），
    /// 那时开关会显示"开"但实际什么都没装。
    var launchAtLoginEnabled: Bool { Self.launchManager.isEnabled }

    /// 启动时按配置纠正实际状态，消除"配置说开、实际没装"的脱节
    func reconcileLaunchAtLogin() {
        let desired = environment.store.config.launchAtLogin
        let actual = Self.launchManager.isEnabled
        guard desired != actual else { return }
        Log.warn("开机自启动状态不一致（配置=\(desired)，实际=\(actual)），按配置纠正")
        do {
            try Self.launchManager.setEnabled(desired)
        } catch {
            Log.error("纠正开机自启动失败：\(error)")
            // 纠正不了就以实际状态为准，避免 UI 骗人
            updateConfig { $0.launchAtLogin = actual }
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try Self.launchManager.setEnabled(enabled)
            updateConfig { $0.launchAtLogin = enabled }
        } catch {
            lastError = "\(error)"
            Log.error("设置开机自启动失败：\(error)")
            // 回滚 UI 状态，避免显示与实际不符
            objectWillChange.send()
        }
    }

    // MARK: - 刷新

    func refreshFromEngine() {
        environment.refresh()
        refreshSwapDiagnostics()
    }

    // MARK: - 声道交换（全局独立功能，与规则锁定解耦）

    /// 诊断快照（菜单/设置界面展示用）
    func refreshSwapDiagnostics() {
        let diag = environment.channelSwapDiagnostics()
        swapDiagnostics = diag
        swapState = diag.state
    }

    // MARK: - 声道处理：引擎总开关（v0.1.1）

    /// 声道处理引擎总开关的当前值（配置态）。
    var channelProcessingEngineEnabled: Bool { config.channelSwap.engineEnabled }

    /// 本机是否存在 **BlackHole 16ch** 设备。
    ///
    /// 为什么开总开关前必须查这一次（用户要求）：引擎的输入侧**只能是 BlackHole**
    /// —— 它从虚拟设备的缓冲区里读内容，再写到真实播放设备。
    /// 没有 BlackHole 时打开总开关毫无意义：通路永远起不来，
    /// 用户看到的会是"已开启 + 一直在等待"，而真正的原因（缺驱动）藏在日志里。
    /// ⇒ 与其让他自己猜，不如在**打开的那一刻**就明确告诉他去装。
    ///
    /// 判据用"名字以 BlackHole 开头 **且** 输出声道数 ≥ 16"而不是死抠字面名字：
    /// * 驱动可能被改名（`BlackHole 16ch` / `BlackHole 16ch (2)` 等）；
    /// * 而 16ch 是**能力要求** —— 引擎一次要取 8 条声道，2ch/8ch 版本不够用。
    func hasBlackHole16chDevice() -> Bool {
        listOutputDevices().contains {
            $0.name.hasPrefix("BlackHole") && $0.outputChannelCount >= 16
        }
    }

    /// 开关声道处理引擎（本页所有功能的总开关）。
    ///
    /// 语义（用户确认）：关闭 = **全断**（通路完全不跑、不占用任何音频设备）；
    /// 开启 = 通路必须跑，具体跑哪一种由交换/混音的开关决定，两者都关时是**直通**
    /// （被动进入，用户无法直接选择）。
    ///
    /// ⚠️ 调用方（UI）有责任在**开启前**先查 BlackHole：
    /// 见 `hasBlackHole16chDevice()` 与设置页的提示框。
    func setChannelProcessingEngineEnabled(_ enabled: Bool) {
        updateConfig { $0.channelSwap.engineEnabled = enabled }
    }

    /// 开关声道交换。
    ///
    /// ⚠️ 与「LFE 混音」**互斥**（用户确认）：两者对应不同的音响条件 ——
    /// 交换适用于"音响有低音炮、只是软件把 C/LFE 输出反了"，
    /// 混音适用于"音响没有低音炮"。同时开启没有意义且会互相干扰，
    /// 所以开启一个就自动关掉另一个。
    func setChannelSwapEnabled(_ enabled: Bool) {
        updateConfig { cfg in
            cfg.channelSwap.isEnabled = enabled
            if enabled { cfg.channelSwap.mixEnabled = false }
        }
    }

    /// 开关 LFE 混音。
    ///
    /// ⚠️ 与「声道交换」**互斥**（用户确认）：两者对应不同的音响条件 ——
    /// 交换适用于"音响有低音炮、只是软件把 C/LFE 输出反了"，
    /// 混音适用于"音响没有低音炮"。开启一个就自动关掉另一个。
    func setLfeMixEnabled(_ enabled: Bool) {
        updateConfig { cfg in
            cfg.channelSwap.mixEnabled = enabled
            if enabled { cfg.channelSwap.isEnabled = false }
        }
    }

    /// 指定输入/输出设备（nil = 自动）
    func setChannelSwapDevices(inputUID: String?, outputUID: String?) {
        updateConfig {
            $0.channelSwap.inputDeviceUID = inputUID
            $0.channelSwap.outputDeviceUID = outputUID
        }
    }

    /// 指定要交换的两个声道（**对外 1-based**）
    func setChannelSwapChannels(first: Int, second: Int) {
        updateConfig {
            $0.channelSwap.firstChannel = first
            $0.channelSwap.secondChannel = second
        }
    }

    /// 让交换/混音引擎重新评估。
    ///
    /// ⚠️ **必须**先把 store 里的当前设置推给引擎（`applyChannelSwap`），
    ///    不能只调 `channelSwapDevicesChanged()`：后者只声明"设备变了"，
    ///    而引擎的 `apply` 有幂等短路（设置没变且正在运行 → 直接 return），
    ///    于是**新配置永远进不去**。
    ///    本会话踩到：外部改了 `mixTargetChannel`，日志显示通知已收到、
    ///    changed=true，但装配仍是旧的 —— 就是漏了这一步。
    func reapplyChannelSwap() {
        environment.applyChannelSwap(environment.store.config.channelSwap)
        environment.channelSwapDevicesChanged()
        refreshSwapDiagnostics()
    }

    /// 当前可用于交换的目标设备（≥6 声道、非 BlackHole）—— 设置界面选择用
    func channelSwapTargetCandidates() -> [DeviceDescriptor] {
        listOutputDevices()
            .filter { $0.outputChannelCount >= ChannelSwapPlan.minimumChannelCount
                      && !$0.name.hasPrefix("BlackHole") }
            .sorted { $0.outputChannelCount > $1.outputChannelCount }
    }

    /// 候选输入设备（BlackHole）
    func channelSwapInputCandidates() -> [DeviceDescriptor] {
        listOutputDevices().filter { $0.name.hasPrefix("BlackHole") }
    }

    // MARK: - 声道处理：实际生效的设备名（界面标注用）

    /// 声道处理实际使用的**输入设备名**。
    ///
    /// 三级取值，保证界面任何时刻都有名字可显示：
    /// ① 引擎**实际解析**的结果（ground truth，最可靠）；
    /// ② 配置里指定的 UID 对应的设备；
    /// ③ 按「自动」规则的推算结果。
    ///
    /// 交换与混音**共用同一对设备**，所以这两个名字同时供两个功能的控件标注使用。
    var channelProcessingInputName: String {
        if let resolved = swapDiagnostics.inputDeviceName { return resolved }
        let candidates = channelSwapInputCandidates()
        if let uid = config.channelSwap.inputDeviceUID,
           let matched = candidates.first(where: { $0.uid == uid }) {
            return matched.name
        }
        return candidates.first?.name ?? "未找到"
    }

    /// 声道处理实际使用的**输出设备名**（取值策略同上）
    var channelProcessingOutputName: String {
        if let resolved = swapDiagnostics.outputDeviceName { return resolved }
        let candidates = channelSwapTargetCandidates()
        if let uid = config.channelSwap.outputDeviceUID,
           let matched = candidates.first(where: { $0.uid == uid }) {
            return matched.displayName
        }
        return candidates.first?.displayName ?? "未找到"
    }

    // MARK: - 动作

    func applyNow(ruleID: UUID) {
        environment.applyNow(ruleID: ruleID)
    }

    /// 立即应用全部：**设备规则 + 声道处理**。
    ///
    /// ⚠️ 只调 `environment.applyAllNow()` 是不够的 —— 它最终落到
    /// `RuleEngine.applyAllNow()`，那里**只遍历已启用的设备规则**，
    /// 完全不会重新装配交换 / 混音通路。
    /// 而首页把「规则」与「声道处理」两栏并列显示，用户按下"全部"时
    /// 预期两者都被应用（实测确认过这个缺口）。
    func applyAllNow() {
        environment.applyAllNow()
        reapplyChannelSwap()
    }

    func setRuleEnabled(_ ruleID: UUID, _ enabled: Bool) {
        environment.setRuleEnabled(ruleID, enabled)
    }

    func removeRule(_ ruleID: UUID) {
        environment.store.removeRule(id: ruleID)
        environment.configDidChange()
    }

    func listOutputDevices() -> [DeviceDescriptor] {
        environment.listOutputDevices()
    }

    func capability(forUID uid: String) -> DeviceCapability {
        environment.capability(forUID: uid)
    }

    func saveRule(_ rule: DeviceRule) {
        if environment.store.config.rules.contains(where: { $0.id == rule.id }) {
            environment.store.replaceRule(rule)
        } else {
            environment.store.addRule(rule)
        }
        // ★ 必须走 configDidChange（重新注册监听器 + 立即生效），
        //   只 refresh 的话新规则不会生效
        environment.configDidChange()
    }

    /// 把规则重新绑定到当前实际匹配到的设备。
    ///
    /// 使用场景：HDMI/DP 设备的 UID 由 EDID/端口派生，换端口或换显示器后会变，
    /// 规则会退化为"名称+传输类型"兜底匹配。此时应让用户一键更新 UID。
    func rebindRule(_ ruleID: UUID) {
        guard let rule = ruleForEditing(ruleID),
              let device = environment.deviceForFallbackMatch(of: rule) else {
            lastError = "找不到可绑定的设备"
            return
        }
        var updated = rule
        updated.deviceUID = device.uid
        updated.deviceName = device.name
        updated.transportType = device.transportType
        saveRule(updated)
        Log.info("已把规则「\(rule.deviceName)」重新绑定到 UID \(device.uid)")
    }

    /// 某设备当前的物理格式（"添加规则"界面用）
    func currentFormat(forUID uid: String) -> AudioFormatPreset? {
        environment.currentFormat(forUID: uid)
    }

    func copyLogToPasteboard() {
        let text = Log.shared.exportText()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func clearLog() {
        Log.shared.clear()
        logEntries.removeAll()
    }
}
