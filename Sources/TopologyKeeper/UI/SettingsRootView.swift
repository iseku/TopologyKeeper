import AppKit
import SwiftUI
import TopologyKeeperCore

/// 设置窗口根视图。
struct SettingsRootView: View {

    @ObservedObject var state: AppState
    @State private var selection = 0

    var body: some View {
        TabView(selection: $selection) {
            RulesSettingsTab(state: state)
                .tabItem { Label("锁定规则", systemImage: "slider.horizontal.3") }
                .tag(0)

            ChannelSwapSettingsTab(state: state)
                .tabItem { Label("声道处理", systemImage: "arrow.left.arrow.right") }
                .tag(1)

            GeneralSettingsTab(state: state)
                .tabItem { Label("通用设置", systemImage: "gearshape") }
                .tag(2)

            FullLogTab(state: state)
                .tabItem { Label("日志", systemImage: "text.alignleft") }
                .tag(3)

            AboutTab()
                .tabItem { Label("关于", systemImage: "info.circle") }
                .tag(4)
        }
        .padding(14)
        // 最小尺寸与窗口的 `settingsInitialSize` **保持一致**（500×600）。
        // 历史：700×540（宽度被锁死，窄版布局做不到）→ 432×560（实测偏窄）→ 当前。
        // 若内容在这个宽度下显示不开，SwiftUI 会按内容最小宽度抬高下限，
        // 窗口不会把内容挤坏。
        .frame(minWidth: 500, minHeight: 600)
    }
}

// MARK: - Tab 1：设备规则

struct RulesSettingsTab: View {

    @ObservedObject var state: AppState
    @State private var editingRule: DeviceRule?
    @State private var isAddingRule = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("锁定规则")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    isAddingRule = true
                } label: {
                    Label("添加规则", systemImage: "plus")
                }
            }

            if state.snapshots.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "speaker.slash")
                        .font(.system(size: 26))
                        .foregroundStyle(.tertiary)
                    Text("还没有规则")
                        .foregroundStyle(.secondary)
                    Text("点击「添加规则」为某台音频设备设定目标格式，\n之后唤醒 / 插拔时它会自动恢复到该格式。")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(state.snapshots) { snapshot in
                            SettingsRuleCard(snapshot: snapshot, state: state) {
                                if let rule = state.ruleForEditing(snapshot.ruleID) {
                                    editingRule = rule
                                }
                            }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $isAddingRule) {
            RuleEditorView(state: state, existingRule: nil)
        }
        .sheet(item: $editingRule) { rule in
            RuleEditorView(state: state, existingRule: rule)
        }
    }
}

/// 设置页里的规则卡片（比弹出面板更详细）
struct SettingsRuleCard: View {
    let snapshot: RuleSnapshot
    @ObservedObject var state: AppState
    let onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(snapshot.deviceName)
                    .font(.system(size: 12, weight: .semibold))
                Text(snapshot.transportName)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("启用", isOn: Binding(
                    get: { snapshot.isEnabled },
                    set: { state.setRuleEnabled(snapshot.ruleID, $0) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    // 与首页保持一致：设备不在时不可切换，但**不改动** isEnabled
                    .disabled(!snapshot.devicePresent)
                    .help(snapshot.devicePresent
                          ? "启用或停用该规则"
                          : "设备未连接，暂时无法切换（设备接入后自动恢复锁定）")
                Button("编辑", action: onEdit)
                    .controlSize(.small)
                Button("删除") { state.removeRule(snapshot.ruleID) }
                    .controlSize(.small)
            }

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow {
                    Text("预设").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(snapshot.preset.displayString)
                        .font(.system(size: 11, design: .monospaced))
                }
                GridRow {
                    Text("当前").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(snapshot.currentFormatText)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(snapshot.isFormatMatching ? Color.primary : Color.orange)
                }
                GridRow {
                    Text("状态").font(.system(size: 11)).foregroundStyle(.secondary)
                    HStack(spacing: 5) {
                        Image(systemName: snapshot.state.iconName).font(.system(size: 10))
                        Text(snapshot.state.displayText).font(.system(size: 11))
                    }
                }
                GridRow {
                    Text("设备能力").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(snapshot.devicePresent
                         ? "\(snapshot.capabilityCombinationCount) 个组合，最高 \(snapshot.capabilityMaxChannels)ch"
                         : "设备未连接")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                GridRow {
                    Text("冲突策略").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(snapshot.conflictPolicy.displayText).font(.system(size: 11))
                }
            }

            if snapshot.matchedViaFallback {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10)).foregroundStyle(.orange)
                    Text("设备 UID 已变化（HDMI/DP 设备换端口或换显示器时会发生），"
                         + "目前靠「名称 + 传输类型」兜底匹配。")
                        .font(.system(size: 10)).foregroundStyle(.orange)
                    Button("重新绑定到当前设备") { state.rebindRule(snapshot.ruleID) }
                        .controlSize(.small)
                }
            }

            if let error = snapshot.lastError {
                Text(error)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Tab 2：通用

struct GeneralSettingsTab: View {

    @ObservedObject var state: AppState

    var body: some View {
        Form {
            Section("行为") {
                Toggle("应用成功后显示通知", isOn: binding(\.showNotifications))
                HStack(spacing: 6) {
                    Text("通知状态").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(state.notificationAvailability.displayText)
                        .font(.system(size: 11))
                    if case .unavailable = state.notificationAvailability {
                        Button("重试授权") { state.requestNotificationAuthorization() }
                            .buttonStyle(.link).font(.system(size: 11))
                    }
                }
                Toggle("记录日志到文件", isOn: binding(\.recordLogToFile))
                if let path = state.logFilePath {
                    HStack(spacing: 6) {
                        Text(path).font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button("显示") { state.revealLogFile() }
                            .buttonStyle(.link).font(.system(size: 10))
                    }
                }
                // ★ 上一轮日志的备份入口。
                //   启动时会轮转一份（见 `Log.resetLogFileOnLaunch`），
                //   而"上一轮"往往正是出问题的那一轮 —— 不给入口用户根本找不到。
                if let rotated = state.rotatedLogFilePath {
                    HStack(spacing: 6) {
                        Text("上一轮：\(rotated)").font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button("显示") { state.revealRotatedLogFile() }
                            .buttonStyle(.link).font(.system(size: 10))
                    }
                }
                Toggle("开机自动启动", isOn: Binding(
                    get: { state.launchAtLoginEnabled },     // ★ 读实际状态，不读配置意愿
                    set: { state.setLaunchAtLogin($0) }))
                Text("下次登录生效")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Section("时序参数") {
                intField("设备事件防抖（毫秒）", \.eventDebounceMs)
                intField("自身写入抑制窗口（毫秒）", \.selfWriteSuppressMs)
                intField("冲突退避阈值（连续失败次数）", \.conflictBackoffThreshold)
                intField("抖动检测窗口（毫秒）", \.thrashWindowMs)
                intField("抖动检测阈值（窗口内应用次数）", \.thrashThreshold)
                intField("冲突退避时长（毫秒）", \.conflictBackoffMs)
                intField("唤醒后轮询间隔（毫秒）", \.postWakePollIntervalMs)
                intField("唤醒后轮询时长（毫秒）", \.postWakePollDurationMs)
                Text("配置系统重启/唤醒后音频设备事件获取和执行锁定/交换/混音操作的时序及冲突退避参数，功能正常时请保持默认配置。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }


        }
        .formStyle(.grouped)
    }

    private func binding(_ keyPath: WritableKeyPath<AppConfig, Bool>) -> Binding<Bool> {
        Binding(get: { state.config[keyPath: keyPath] },
                set: { newValue in state.updateConfig { $0[keyPath: keyPath] = newValue } })
    }

    private func intField(_ label: String, _ keyPath: WritableKeyPath<AppConfig, Int>) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("", value: Binding(
                get: { state.config[keyPath: keyPath] },
                set: { newValue in state.updateConfig { $0[keyPath: keyPath] = newValue } }),
                      format: .number)
                .frame(width: 100)
                .textFieldStyle(.roundedBorder)
        }
    }
}

// MARK: - Tab 3：完整日志

struct FullLogTab: View {

    @ObservedObject var state: AppState

    /// 等级筛选。**初始值刻意是 `.info` 而不是 nil（全部）** —— 用户要求。
    ///
    /// 为什么：日志本体记录了**全部**等级（含大量 DBG），一上来"全部"打开会显得很乱 ——
    /// 例如唤醒时那批"设备与设置都未变，跳过重新装配"会占满整屏，
    /// 把真正有信息量的行挤走。默认停在 INF 上，内容就专注得多。
    ///
    /// ⚠️ 这里是**界面本地状态，刻意不写进配置**：
    /// 它只是一次查看时的临时偏好，不是需要持久化的行为参数；
    /// 用户随时可以在这个选择器里换成「全部」或其他等级。
    /// （每次重新打开日志页会回到 INF —— `@State` 随视图重建而重置。）
    @State private var filter: LogLevel? = .info

    private var filtered: [LogEntry] {
        guard let filter else { return state.logEntries }
        return state.logEntries.filter { $0.level == filter }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("操作日志")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Picker("", selection: $filter) {
                    Text("全部").tag(LogLevel?.none)
                    ForEach(LogLevel.allCases, id: \.self) { level in
                        Text(level.displayName).tag(LogLevel?.some(level))
                    }
                }
                .labelsHidden()
                .frame(width: 110)
                .help("默认显示 INF；换「全部」可看到 DBG（落盘文件始终记录全部等级）")
                Button("复制全部") { state.copyLogToPasteboard() }
                Button("清空") { state.clearLog() }
            }

            Text("日志记录「发出值 vs 回读值」，这是排查静默失败的唯一手段。"
                 + " 当前显示 \(filtered.count)/\(state.logEntries.count) 条。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(filtered) { entry in
                        HStack(alignment: .top, spacing: 8) {
                            // ★ 时间字段带方括号（与日志文件、首页面板统一）
                            Text("[\(entry.timestampString)]")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text(entry.level.rawValue)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(color(for: entry.level))
                                .frame(width: 26, alignment: .leading)
                            Text(entry.message)
                                .font(.system(size: 10, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(6)
            }
            .background(Color.secondary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func color(for level: LogLevel) -> Color {
        switch level {
        case .debug: return .secondary
        case .info:  return .primary
        case .warn:  return .orange
        case .error: return .red
        }
    }
}

// MARK: - Tab 4：关于

struct AboutTab: View {

    /// 版本号，取自打包进 `.app` 的 Info.plist。
    ///
    /// 非 bundle 运行（如 `swift run` / 单测）读不到时显示 `—`，
    /// 而不是显示空白或崩溃。
    private var versionText: String {
        guard let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        else { return "—" }
        guard let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        else { return short }
        return "\(short)（\(build)）"
    }

    var body: some View {
        VStack(spacing: 12) {
            // ★ 用**真实打包的 App 图标**，不再用 SF Symbol ——
            //   否则设置里的"关于"与访达/Dock 里看到的不是同一个图标。
            //   取不到时回落到符号，保证界面不空。
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 72, height: 72)
            } else {
                Image(systemName: "speaker.wave.3.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.tint)
            }
            Text("TopologyKeeper")
                .font(.system(size: 17, weight: .semibold))

            // ★ 功能列表（用户指定文案）：标题比正文**大一号**，正文沿用原来的 11pt。
            //   整块随父 VStack 居中；两行正文各自成 Text，靠父级居中而非自己撑宽。
            //   间距（用户要求"拉大一个空行"）：行内 12pt；与上方标题块再空 24pt
            //   （父级 12 + 自身 padding 12），免得挤在 TopologyKeeper 那行下面。
            VStack(spacing: 12) {
                Text("功  能")
                    .font(.system(size: 13, weight: .semibold))
                Text("音频设备「声道数•位深•采样率」锁定")
                    .font(.system(size: 11))
                Text("多声道设备「中置•低音」声道互换/混音")
                    .font(.system(size: 11))
            }
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.top, 12)

            Text("版本 \(versionText)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Tab 2：声道交换

/// 声道交换设置。
///
/// ⚠️ 功能定位：
/// 这是**针对特定应用的补偿措施**。实测只对"按默认声道布局输出、原本中置/重低音
/// 错位"的应用有效（如 WOW、Movist Pro）；对本来布局就正确的应用（如 IINA、MPV）
/// 无影响。界面顶部必须说清楚，否则用户会以为"没生效"。
struct ChannelSwapSettingsTab: View {

    @ObservedObject var state: AppState

    /// 「未找到 BlackHole 16ch」提示框的显示状态。
    ///
    /// ⚠️ 刻意**不**把"是否已提示过"写进配置：这不是需要持久化的行为参数，
    ///    每次重新打开设置页都会重置（与日志页的等级选择器同样的取舍）。
    @State private var showBlackHoleMissingAlert = false

    private var settings: ChannelSwapSettings { state.config.channelSwap }

    var body: some View {
        // BlackHole 检测只做一次：`hasBlackHole16chDevice()` 内部是
        // `audioQueue.sync` + 一次设备枚举，在 body 里反复调用纯属浪费
        // （而且它会随界面刷新被反复触发）。
        let hasBlackHole = state.hasBlackHole16chDevice()
        return Form {
            // ★★ 本页的**电源**（v0.1.1 新增，用户要求）：
            //    它决定"通路跑不跑"，下面的交换/混音只决定"怎么处理"。
            Section("声道处理引擎") {
                Toggle("启用声道处理引擎", isOn: Binding(
                    get: { settings.engineEnabled },
                    set: { newValue in
                        // ★ 开启前先查 BlackHole 16ch（用户要求）。
                        //   查不到就**不打开**开关，只弹提示 ——
                        //   否则用户会看到"已开启"却永远等不到通路，
                        //   真正的原因（缺驱动）只能去日志里找。
                        if newValue && !state.hasBlackHole16chDevice() {
                            showBlackHoleMissingAlert = true
                        } else {
                            state.setChannelProcessingEngineEnabled(newValue)
                        }
                    }))

                Text("使用声道交换/混音功能请先启用「声道处理引擎」，"
                     + "引擎关闭后会出现无声现象，请将系统音频输出切换至其它物理音频设备。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // 输入侧前提条件（缺失时明确写出来，不让用户去猜）
                HStack(spacing: 6) {
                    Image(systemName: hasBlackHole
                          ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(hasBlackHole ? .green : .red)
                    Text(hasBlackHole
                         ? "已检测到 BlackHole 16ch"
                         : "未检测到 BlackHole 16ch —— 引擎的输入源，需先安装该驱动")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            // ★ 公共区域：交换与混音**共用同一条音频通路、同一对设备**，
            //   所以设备选择只在这里出现一次，不再放在某个功能区块内
            //   （用户指出：放在"交换"区块里会让人以为只对交换生效）。
            Section("设备选择") {
                Picker("输入设备（源）", selection: Binding(
                    get: { settings.inputDeviceUID ?? "" },
                    set: { newValue in
                        state.setChannelSwapDevices(
                            inputUID: newValue.isEmpty ? nil : newValue,
                            outputUID: settings.outputDeviceUID)
                    })) {
                    Text("自动（第一个 BlackHole）").tag("")
                    ForEach(state.channelSwapInputCandidates(), id: \.uid) { device in
                        Text("\(device.name)（\(device.outputChannelCount) 声道）").tag(device.uid)
                    }
                }

                Picker("输出设备（目标）", selection: Binding(
                    get: { settings.outputDeviceUID ?? "" },
                    set: { newValue in
                        state.setChannelSwapDevices(
                            inputUID: settings.inputDeviceUID,
                            outputUID: newValue.isEmpty ? nil : newValue)
                    })) {
                    Text("自动（≥\(ChannelSwapPlan.minimumChannelCount) 声道中最多者）").tag("")
                    ForEach(state.channelSwapTargetCandidates(), id: \.uid) { device in
                        Text("\(device.displayName)（\(device.outputChannelCount) 声道）").tag(device.uid)
                    }
                }

                Text("目标设备需 ≥\(ChannelSwapPlan.minimumChannelCount) 声道（BlackHole 仅支持输入）。"
                     + "当前候选：\(state.channelSwapTargetCandidates().count) 台。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("声道交换") {
                Toggle("启用声道交换", isOn: Binding(
                    get: { settings.isEnabled },
                    set: { state.setChannelSwapEnabled($0) }))
                    // ★ 总开关关闭时功能开关不生效 —— 直接禁用（用户确认的做法），
                    //   避免"点了没反应"被误判成故障。
                    .disabled(!settings.engineEnabled)
                Text("交换任意两个声道的输出，主要用于解决部分应用（中置/低音）布局错误的问题，"
                     + "把中置与低音的声道互换后再输出到播放设备。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // 声道号一律**对外 1-based**（第 1…8 声道），与「音频MIDI设置」一致。
                // 标题带上**实际输出设备名**（用户要求）：交换作用在这台设备的声道上，
                // 写明设备名才不会有歧义（此前是固定文案）。
                Picker("第一个声道（\(state.channelProcessingOutputName)）", selection: Binding(
                    get: { settings.firstChannel },
                    set: { state.setChannelSwapChannels(first: $0, second: settings.secondChannel) })) {
                    ForEach(1...8, id: \.self) { ch in
                        Text(channelLabel(ch)).tag(ch)
                    }
                }
                Picker("第二个声道（\(state.channelProcessingOutputName)）", selection: Binding(
                    get: { settings.secondChannel },
                    set: { state.setChannelSwapChannels(first: settings.firstChannel, second: $0) })) {
                    ForEach(1...8, id: \.self) { ch in
                        Text(channelLabel(ch)).tag(ch)
                    }
                }
                // ★ 这里要讲清"为什么会有这个问题" —— 它就是本功能存在的理由。
                //   （我先前误解成"那句话写错了"，其实是行业标准 vs Apple 声明的差异。）
                Text("默认交换第 3 ↔ 第 4 声道。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 标题不再带固定的"（低音 → 可听声道）"：那是一个写死的语义描述，
            // 而两个声道号都可配置，语义会随配置变化（用户要求标题跟随实际设备/配置）。
            Section("LFE 混音") {
                Toggle("启用 LFE 混音", isOn: Binding(
                    get: { settings.mixEnabled },
                    set: { newValue in
                        state.updateConfig { cfg in
                            cfg.channelSwap.mixEnabled = newValue
                            // 互斥：开了混音就关交换
                            if newValue { cfg.channelSwap.isEnabled = false }
                        }
                    }))
                    // ★ 同上：总开关关闭时功能开关不生效，直接禁用
                    .disabled(!settings.engineEnabled)
                // ⚠️ 不要在这里写死"低音声道 / 中置声道"：下面两个下拉框允许改声道号，
                //    写死语义在用户改动后就变成错的（本轮修掉的问题）。
                //    实际语义由 `tkctl mix show` 的「设备声明」给出。
                Text("把输入声道的内容按增益叠加到输出声道，适用于没有 LFE 扬声器又需要保留 LFE 内容的场景。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                if settings.mixEnabled {
                    LabeledContent("增益") {
                        Text(String(format: "%.1f dB", settings.mixGainDB))
                            .monospacedDigit()
                    }
                    Slider(value: Binding(
                        get: { settings.mixGainDB },
                        set: { newValue in
                            state.updateConfig { $0.channelSwap.mixGainDB = newValue }
                        }),
                           in: LfeMixPlan.gainRangeDB,
                           step: 1.0)
                    Text("默认 −10dB：LFE 的校准电平比主声道高 10dB，"
                         + "按 −10dB 混入即与主声道**等响**。实测该增益下峰值约 0.55，"
                         + "远离削顶；调太高会让低音压过主声道并可能失真。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Picker("输入声道（\(state.channelProcessingInputName)）", selection: Binding(
                        get: { settings.mixSourceChannel },
                        set: { newValue in
                            state.updateConfig { $0.channelSwap.mixSourceChannel = newValue }
                        })) {
                        ForEach(Array(LfeMixPlan.selectableChannels), id: \.self) { ch in
                            Text("第 \(ch) 声道"
                                 + (ch == LfeMixPlan.defaultInputChannel ? "（默认）" : ""))
                                .tag(ch)
                        }
                    }
                    Picker("输出声道（\(state.channelProcessingOutputName)）", selection: Binding(
                        get: { settings.mixTargetChannel },
                        set: { newValue in
                            state.updateConfig { $0.channelSwap.mixTargetChannel = newValue }
                        })) {
                        ForEach(Array(LfeMixPlan.selectableChannels), id: \.self) { ch in
                            Text("第 \(ch) 声道"
                                 + (ch == LfeMixPlan.defaultOutputChannel ? "（默认）" : ""))
                                .tag(ch)
                        }
                    }

                    // ★ 实况预览：直接按"实际会执行的公式"生成，不手写文字。
                    //   为什么要这样：我手写的说明曾经与驱动实际行为不一致
                    //   （写成"CH4-O = 原内容 × g + CH3-I × g"，把 CH4-O 自己的内容也乘了增益），
                    //   用户一眼就看出来了。生成式描述不可能与逻辑漂移。
                    //
                    //   ★ 首行改用 `LfeMixPlan.transferFunctionLine` ——
                    //     与首页状态栏的「映射」一行**共用同一份生成逻辑**，
                    //     两处从此不可能再对不上。
                    //   ★ "不连的那条"同样走 `LfeMixPlan` 的纯函数，
                    //     不在界面层再算一遍配对（那个推导全仓库只允许有一份）。
                    let cutOut = LfeMixPlan.cutOutputChannel(forTarget: settings.mixTargetChannel)
                    Text("当前传递函数：\n"
                         + "  " + LfeMixPlan.transferFunctionLine(
                                inputChannel: settings.mixSourceChannel,
                                outputChannel: settings.mixTargetChannel,
                                gain: LfeMixPlan.gain(fromDB: settings.mixGainDB)) + "\n"
                         + "  CH\(cutOut)-O = 0（不连）\n"
                         + "  其余输出声道不变")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)

                }
            }

            Section("行为") {
                Toggle("按输出设备采样率对齐输入设备", isOn: Binding(
                    get: { settings.alignInputSampleRate },
                    set: { newValue in
                        state.updateConfig { $0.channelSwap.alignInputSampleRate = newValue }
                    }))
                Text("输入/输出设备采样率不一致时，把输入设备的采样率设成与输出设备一致，"
                     + "避免在实时回调里重采样。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Toggle("重试耗尽后发出通知", isOn: Binding(
                    get: { settings.notifyOnGiveUp },
                    set: { newValue in
                        state.updateConfig { $0.channelSwap.notifyOnGiveUp = newValue }
                    }))
                Text("条件不满足时按 \(settings.backoffDescription) 依次重试；"
                     + "仍不成功则停止并提示。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("状态") {
                // ★ 模式由**引擎**给出（`diagnostics.activeFunction`），界面不自己推导 ——
                //   否则"交换/混音/直通/全断"会出现两套判断，迟早对不上。
                LabeledContent("当前模式") {
                    Text(state.swapDiagnostics.activeFunction.displayName)
                        .foregroundStyle(settings.engineEnabled ? .primary : .secondary)
                }
                LabeledContent("当前状态") {
                    // 运行态下这里会随模式给出「交换中 / 混音中 / 直通中」；
                    // 引擎关闭时是「未启用」（= 全断）。
                    Text(state.swapDiagnostics.statusText)
                        .foregroundStyle(state.swapState.needsAttention ? .red : .secondary)
                }
                // ★ 判据是 needsAudioPath（= 引擎总开关）：只开混音、乃至直通模式，
                //   通路同样在跑，状态/诊断必须照常显示，否则用户会以为"没生效"。
                if settings.needsAudioPath {
                    LabeledContent("设备") {
                        Text(deviceSummary)
                    }
                    LabeledContent("实际映射") {
                        Text(state.swapDiagnostics.mappingDescription)
                    }
                    LabeledContent("实时统计") {
                        Text("帧 \(state.swapDiagnostics.framesIn) / "
                             + "\(state.swapDiagnostics.framesOut)　"
                             + "欠载 \(state.swapDiagnostics.underruns)　"
                             + "渲染失败 \(state.swapDiagnostics.renderFailures)")
                    }
                    if let aligned = state.swapDiagnostics.sampleRateAligned {
                        LabeledContent("采样率对齐") { Text(aligned) }
                    }
                }
                Button("重新评估 / 刷新") {
                    state.reapplyChannelSwap()
                }
            }


        }
        .formStyle(.grouped)
        .onAppear { state.refreshSwapDiagnostics() }
        // ★ 开启总开关时若没有 BlackHole 16ch：明确告诉用户去装驱动，
        //   而不是让他对着"已开启但一直在等待"的界面自己猜。
        .alert("未检测到 BlackHole 16ch 音频设备", isPresented: $showBlackHoleMissingAlert) {
            Button("好", role: .cancel) { }
        } message: {
            Text("「声道处理引擎」需要 BlackHole 16ch 作为输入源"
                 + "（它从虚拟设备的缓冲区读取音频，处理后再输出到播放设备）。\n\n"
                 + "请先安装 BlackHole 16ch 驱动（免费开源，官网 existential.audio/blackhole），"
                 + "安装后重新登录或重启，再回来开启本开关。")
        }
    }

    private var deviceSummary: String {
        let diag = state.swapDiagnostics
        guard let input = diag.inputDeviceName, let output = diag.outputDeviceName else {
            return "—"
        }
        return "\(input)（\(diag.inputChannelCount) 进） → "
            + "\(output)（\(diag.outputChannelCount) 声道）"
    }

    /// "第 3 声道（中置）"
    private func channelLabel(_ channel: Int) -> String {
        if let semantic = ChannelSwapPlan.semanticName(forChannel: channel) {
            return "第 \(channel) 声道（\(semantic)）"
        }
        return "第 \(channel) 声道"
    }
}
