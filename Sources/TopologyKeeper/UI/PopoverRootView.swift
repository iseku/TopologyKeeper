import AppKit
import SwiftUI
import TopologyKeeperCore

/// 锁定状态 → 颜色。**表头图标与列表圆点共用同一套**，避免两处各写一份而漂移。
///
/// 色义（用户确认）：
/// * 已锁定 → `.accentColor`（跟随系统主题色，macOS 默认即蓝色）
/// * 正在应用 → `.teal`（**必须与已锁定区分**：两者原先一个绿一个蓝，
///   若把已锁定直接改成蓝色就会与"正在应用"撞色）
/// * 等待设备就绪 → 橙、失败 → 红、其余 → 次要色
///
/// 注意：这只影响弹出面板/设置页的列表着色。**菜单栏图标**走
/// `LockState.statusTint`（normal / inProgress / critical，无绿色），故不受影响。
func lockStatusColor(_ state: LockState) -> Color {
    switch state {
    case .locked:               return .accentColor
    case .applying:             return .teal
    case .waitingForCapability: return .orange
    case .failed:               return .red
    default:                    return .secondary
    }
}

/// 规则列表内容的**自然高度**，用于让首页列表自适应。
///
/// 为什么需要：原实现把列表写死 `.frame(maxHeight: 340)` ——
/// 加到第二条规则就出现滚动条，即使屏幕还有大量空间。
private struct RulesContentHeightKey: PreferenceKey {
    // `static let`（而非 `var`）：Swift 6 并发检查不允许非隔离的全局可变状态。
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// 面板中**除规则列表外**的固定部分（表头 / 日志 / 声道处理栏 / 底栏 + 分隔线）的高度。
private struct ChromeHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// 主面板（点击菜单栏图标弹出）。
///
/// 与早期设计的差异：**并排显示"预设"与"当前"**。
/// 原方案只显示一个"当前"，但实测证明写入可能静默失败，
/// 用户必须能一眼看出锁定到底有没有生效。
struct PopoverRootView: View {

    @ObservedObject var state: AppState
    let onOpenSettings: () -> Void
    /// 内容尺寸发生变化时回调，参数是**面板应有的总高度**（pt）。
    ///
    /// 为什么必须有这个回调：`NSPopover` **不会**自动跟随内容改尺寸。
    /// 只在打开时同步一次的话，**删除规则**这类"内容变矮"的改动不会生效，
    /// 必须关掉重开才显示正确（用户实测到的现象）。
    ///
    /// 为什么上报高度而不是让外层读 `fittingSize`：`fittingSize` 要等 SwiftUI
    /// **提交**新一轮布局才更新，而本回调发生在**测量之后、提交之前** ——
    /// 读它可能拿到旧值，于是又回到"不生效"。高度这里用刚测到的数值直接算出，确定。
    var onLayoutHeightChange: ((CGFloat) -> Void)?

    /// 规则列表实测的自然高度
    @State private var rulesContentHeight: CGFloat = 0
    /// 列表以外固定部分实测的高度
    @State private var chromeHeight: CGFloat = 0

    /// 面板整体高度上限 = 屏幕可见高度的 80%（判据在 `PopoverLayout`，有单测）
    private var maxContentHeight: CGFloat {
        PopoverLayout.maxContentHeight(
            screenVisibleHeight: NSScreen.main?.visibleFrame.height ?? 900)
    }

    /// 规则列表应当取的确切高度。
    ///
    /// 计算本身在 `PopoverLayout.listHeight`（Core，纯函数、有单测）——
    /// 本机只有 4 台设备、到不了滚动阈值，那条分支只能靠测试覆盖。
    private var rulesListHeight: CGFloat {
        PopoverLayout.listHeight(contentHeight: rulesContentHeight,
                                 chromeHeight: chromeHeight,
                                 maxContentHeight: maxContentHeight)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            if state.snapshots.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(state.snapshots) { snapshot in
                            RuleRowView(snapshot: snapshot, state: state)
                        }
                    }
                    .padding(12)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(key: RulesContentHeightKey.self,
                                                   value: proxy.size.height)
                        }
                    )
                }
                .frame(height: rulesListHeight)
            }

            Divider()
            ChannelSwapRowView(state: state)

            if state.logExpanded {
                Divider()
                LogPanelView(entries: state.logEntries, state: state)
            }

            Divider()
            footer
        }
        .frame(width: 380)
        // ★ 量"除列表外的固定高度"：本视图在宽度已定、**尚未**封顶时的高度
        //   减去列表高度即是。列表高度是确定的，所以这个差值不随列表变化，无回环。
        //   空状态列表（没有 ScrollView）时列表高度不参与布局，故整高即固定部分 ——
        //   否则会算出负值，且随后添加第一条规则时首帧会用错的高度。
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: ChromeHeightKey.self,
                    value: state.snapshots.isEmpty
                        ? proxy.size.height
                        : max(proxy.size.height - rulesListHeight, 0))
            }
        )
        .onPreferenceChange(RulesContentHeightKey.self) { height in
            guard abs(height - rulesContentHeight) > 0.5 else { return }
            rulesContentHeight = height
            reportLayoutHeight(content: height, chrome: chromeHeight)
        }
        .onPreferenceChange(ChromeHeightKey.self) { height in
            guard abs(height - chromeHeight) > 0.5 else { return }
            chromeHeight = height
            reportLayoutHeight(content: rulesContentHeight, chrome: height)
        }
        // 兜底：即使上面的计算出现意外，也不让面板超过上限。
        //
        // ★ alignment 必须是 `.top` —— 这不是样式偏好，而是**消除"收起日志时
        //   闪一下"这个真 bug 的关键**（用户实测：内容先在正常位置**下方**出现，
        //   随后才跳回正常位置；手机录像定格可见两层内容相差约一个日志面板）。
        //
        //   机理：`.frame(maxHeight:)` 在"容器比内容高"时按 alignment 摆放内容，
        //   默认 `.center` 会把内容**垂直居中**。而收起日志的那一瞬间，SwiftUI
        //   内容已经变矮、NSPopover 窗口却还停在旧的大高度（窗口要等测量回调 +
        //   `applyPopoverHeight` 里延后的一拍才收缩）⇒ 那一帧里内容被居中，
        //   整体下移约 (日志面板高 ÷ 2)，窗口随后收缩又把它拉回原位。
        //   钉成 `.top` 后内容恒贴**菜单栏那一侧**：窗口偏大时只是底部多出空白，
        //   观感正是"从下方收上去"。
        //
        //   注意 AppKit 那一侧是对的、不要去改：`NSPopover` 改 contentSize 时
        //   **窗口顶边是同步保持的**（`Probe/popover_size_probe` 实测 Δtop = 0）；
        //   手动 `setFrameOrigin` 反而会引入 26pt 偏差。
        //   实测对照见 `Probe/popover_center_probe`：`.center` 偏移 100pt → `.top` 恒为 0。
        .frame(maxHeight: maxContentHeight, alignment: .top)
    }

    /// 把"面板应有的总高度"报给外层（AppKit 侧设置 `NSPopover.contentSize`）。
    ///
    /// 用**刚测到的数值**直接算，不读 `fittingSize`（理由见 `onLayoutHeightChange` 注释）。
    private func reportLayoutHeight(content: CGFloat, chrome: CGFloat) {
        guard let onLayoutHeightChange else { return }
        // 空状态没有列表，整高即固定部分
        let total = state.snapshots.isEmpty
            ? chrome
            : chrome + PopoverLayout.listHeight(contentHeight: content,
                                                chromeHeight: chrome,
                                                maxContentHeight: maxContentHeight)
        onLayoutHeightChange(total)
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: state.statusIconName)
                .foregroundStyle(iconColor)
            Text("TopologyKeeper")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Button {
                state.logExpanded.toggle()
            } label: {
                Image(systemName: state.logExpanded ? "text.alignleft" : "list.bullet.rectangle")
            }
            .buttonStyle(.borderless)
            .help("显示/隐藏日志")

            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("设置")

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.borderless)
            .help("退出")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var iconColor: Color { lockStatusColor(state.aggregateState) }

    // MARK: - 空状态

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("还没有设备规则")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Button("打开设置添加规则") { onOpenSettings() }
                .buttonStyle(.link)
                .font(.system(size: 12))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    // MARK: - 底部

    private var footer: some View {
        HStack {
            Button("立即应用全部") {
                state.applyAllNow()
            }
            .disabled(state.snapshots.isEmpty)

            Spacer()

            Text("\(state.snapshots.count) 条规则")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

// MARK: - 单条规则行

struct RuleRowView: View {
    let snapshot: RuleSnapshot
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(snapshot.deviceName)
                    .font(.system(size: 12, weight: .medium))
                Text(snapshot.transportName)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(Capsule())
                Spacer()
                Toggle("", isOn: Binding(
                    get: { snapshot.isEnabled },
                    set: { state.setRuleEnabled(snapshot.ruleID, $0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    // ★ 设备不在时开关不可用 —— 规则此时恒为「未连接」，
                    //   切换启用状态没有可观察效果，徒增困惑。
                    //   ⚠️ 这里**只禁用控件，绝不改动 isEnabled**：
                    //   用户设定的启用状态必须原样保留，设备回来自动恢复锁定
                    //   （引擎在设备重现后重新评估并锁定，无需人工干预）。
                    .disabled(!snapshot.devicePresent)
                    .help(snapshot.devicePresent
                          ? "启用或停用该规则"
                          : "设备未连接，暂时无法切换（设备接入后自动恢复锁定）")
            }

            // ★ 预设 vs 当前 并排 —— 静默失败时用户能立刻看出来
            HStack(alignment: .top, spacing: 0) {
                formatColumn(title: "预设", format: snapshot.preset.displayString,
                             highlighted: false)
                formatColumn(title: "当前", format: snapshot.currentFormatText,
                             highlighted: !snapshot.isFormatMatching && snapshot.devicePresent)
            }

            HStack(spacing: 6) {
                Image(systemName: snapshot.state.iconName)
                    .font(.system(size: 10))
                    .foregroundStyle(statusColor)
                Text(statusDetail)
                    .font(.system(size: 11))
                    .foregroundStyle(statusColor)
                Spacer()
            }

            if snapshot.matchedViaFallback {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                    Text("设备标识已变化，当前靠名称匹配")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("重新绑定") { state.rebindRule(snapshot.ruleID) }
                        .buttonStyle(.link)
                        .font(.system(size: 10))
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func formatColumn(title: String, format: String, highlighted: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Text(format)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(highlighted ? Color.orange : Color.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 等待能力就绪时补充说明（唤醒后典型状态）
    private var statusDetail: String {
        switch snapshot.state {
        case .waitingForCapability:
            return "等待设备就绪（当前最高 \(snapshot.capabilityMaxChannels)ch）"
        default:
            return snapshot.state.displayText
        }
    }

    private var statusColor: Color { lockStatusColor(snapshot.state) }
}

// MARK: - 日志面板

struct LogPanelView: View {
    let entries: [LogEntry]
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("日志")
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                Button("复制") { state.copyLogToPasteboard() }
                    .buttonStyle(.link).font(.system(size: 10))
                Button("清空") { state.clearLog() }
                    .buttonStyle(.link).font(.system(size: 10))
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(entries.suffix(120)) { entry in
                        HStack(alignment: .top, spacing: 6) {
                            // ★ 时间字段带方括号：与日志文件里的格式一致，
                            //   一眼就能把"时间"和后面的内容分开（用户要求保留方括号）。
                            Text("[\(entry.timestampString)]")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text(entry.message)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(color(for: entry.level))
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 150)
            .padding(.bottom, 8)
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

// MARK: - 声道交换（全局独立功能）

/// 面板上的声道交换一栏。
///
/// 定位提醒：本功能是**针对特定应用的补偿措施**
/// —— 只对"按默认声道布局输出、原本中置/重低音错位"的应用有效（如 WOW、Movist Pro），
/// 对本来布局就正确的应用无影响。UI 文案据此措辞，避免被误当成通用修正。
struct ChannelSwapRowView: View {

    @ObservedObject var state: AppState

    private var settings: ChannelSwapSettings { state.config.channelSwap }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                // ★ 标题与徽标按**用户上次使用的功能**（记忆）联动，真实状态在下面的状态行。
                //   为什么不用"当前生效的模式"：两个功能都关时模式是「直通」，
                //   标题会跳成「直通」而把用户自己的配置信息挤掉（用户实测反馈）。
                Text(modeTitle)
                    .font(.system(size: 12, weight: .medium))
                Text(modeBadge)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(Capsule())
                Spacer()
                // ★ 开关也联动：混音开启时它控制的是混音，不是交换。
                //   两个功能互斥，所以首页只需要**一个**开关，
                //   点它即在"当前生效的那个功能"上做开关。
                //   两种功能都关（直通）时它是关的，点开即从直通切到交换。
                Toggle("", isOn: Binding(
                    get: { settings.isEnabled || settings.mixEnabled },
                    set: { on in
                        if on {
                            // ★ 重开时恢复**用户上次用的那个功能**，而不是"现在哪个开着"。
                            //   读当前状态必然出错：关闭的那一刻 `mixEnabled` 已经是 false，
                            //   于是重开一定落进"否则开交换" —— 实测 bug：
                            //   混音用户关掉再打开会变成交换（用户反馈的"比较严重的问题"）。
                            switch settings.lastEnabledFeature {
                            case .swap: state.setChannelSwapEnabled(true)
                            case .mix:  state.setLfeMixEnabled(true)
                            }
                        } else if settings.mixEnabled {
                            state.setLfeMixEnabled(false)
                        } else {
                            state.setChannelSwapEnabled(false)
                        }
                    }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    // ★ 引擎总开关关闭时功能开关不生效 ⇒ 直接禁用（用户确认的做法），
                    //   避免"点了没反应"被误判成故障。
                    .disabled(!settings.engineEnabled)
                    .help(settings.engineEnabled
                          ? "启用或停用当前功能（交换 / 混音）"
                          : "声道处理引擎未启用，请先在「设置 → 声道处理」中开启")
            }

            Text(state.swapDiagnostics.statusText)
                .font(.system(size: 11))
                .foregroundStyle(statusTextColor)
                .fixedSize(horizontal: false, vertical: true)

            // 引擎关闭（全断）时补一句"去哪里开"，否则用户只会看到一个灰开关
            if !settings.engineEnabled {
                Text("声道处理引擎未启用：音频不经过本工具。"
                     + "可在「设置 → 声道处理」中开启。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // ★ needsAudioPath（= 引擎总开关）：通路在跑就照实显示 ——
            //   包括只开混音与直通两种情形。
            if settings.needsAudioPath, state.swapState.isRunning {
                let diag = state.swapDiagnostics
                VStack(alignment: .leading, spacing: 2) {
                    if let input = diag.inputDeviceName, let output = diag.outputDeviceName {
                        Text("\(input) → \(output)")
                    }
                    Text("映射：\(diag.mappingDescription)")
                    Text("帧 \(diag.framesIn) / \(diag.framesOut)　欠载 \(diag.underruns)")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }

            if case .gaveUp = state.swapState {
                Button("重试") { state.reapplyChannelSwap() }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(12)
        .onAppear { state.refreshSwapDiagnostics() }
    }

    /// 首页副标题：混音开启时显示"衰减哪条 → 混入哪条"
    private var mixSummary: String {
        "第\(settings.mixSourceChannel)→第\(settings.mixTargetChannel)声道"
    }

    /// 卡片标题 = **用户上次使用的功能**（记忆保持）。
    ///
    /// ⚠️ 刻意**不**用"当前生效的模式"（引擎的 `activeFunction`）：
    ///    两个功能都关时模式是「直通」，标题就会从「LFE 混音」跳成「直通」——
    ///    用户实测反馈原话："标题栏要记忆保持原先的状态，不要改成直通的标题，
    ///    只在下面的状态信息提示就行"。真实状态由下面的状态行给出（"直通中"）。
    private var modeTitle: String {
        settings.lastEnabledFeature.displayName
    }

    /// 卡片标题后的徽标：说明"用户那套设置是什么"
    ///
    /// 与标题同理，按**记忆的功能**取描述，而不是按当前模式 ——
    /// 否则功能全关时徽标会变成「原样转发」，把用户自己的配置信息挤掉。
    private var modeBadge: String {
        switch settings.lastEnabledFeature {
        case .swap: return settings.swapDescription
        case .mix:  return mixSummary
        }
    }

    /// 卡片左上角那个**圆点**：反映的是**功能开关**，不是"通路是否在跑"。
    ///
    /// ⚠️ 直通（引擎开着、两个功能都关）时圆点必须是**灰**的 ——
    ///    与 0.1.1 之前的实现保持一致（那时两个都关 ⇒ 通路不跑 ⇒ 圆点灰）。
    ///    "直通中"这件事**只在下面的状态行**体现（用户实测反馈）。
    ///    若不这样处理，直通时圆点会亮成强调色，看起来像"功能正在生效"。
    private var statusColor: Color {
        // 引擎关着时即使功能开关还开着也一律灰（state 会是 .disabled，见下面的分支）
        guard settings.isEnabled || settings.mixEnabled else { return .secondary }
        switch state.swapState {
        case .running:   return .accentColor
        case .starting:  return .blue
        case .waiting:   return .orange
        case .gaveUp, .failed: return .red
        case .disabled:  return .secondary
        }
    }

    /// **状态行文字**的颜色：与圆点分开 —— 它跟着真实状态走。
    ///
    /// 直通是"通路在跑但没做处理"，用次要色（不是警告，也不该亮成"功能生效"）；
    /// 交换/混音运行中才用强调色。
    private var statusTextColor: Color {
        switch state.swapState {
        case .running:
            return (settings.isEnabled || settings.mixEnabled) ? .accentColor : .secondary
        case .starting: return .blue
        case .waiting:  return .orange
        case .gaveUp, .failed: return .red
        case .disabled: return .secondary
        }
    }
}
