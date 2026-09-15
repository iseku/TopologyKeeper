import CoreAudio
import Foundation

/// 规则引擎 —— 持续维持"设备格式 == 预设格式"这个不变式。
///
/// 与原始设计的机制差异（实测依据）：
/// 原方案是「设备事件后固定延迟 800ms，执行一次」。
/// 但实测从睡眠到设备能力到位需要 **19.0s / 28.0s 且不稳定**（是 800ms 的 24~35 倍），
/// 固定延迟必然在能力未就绪时执行 → 必然失败。
///
/// 因此改为：**每次触发都重新评估，格式不符就修**。
/// 能力未就绪时**什么都不做**，等下一次 `devices-list` 事件自然重来
/// —— 实测每次唤醒设备会重建 2~3 次，事件必然再来。
public final class RuleEngine: @unchecked Sendable {

    /// 快照变更回调（在 `queue` 上触发；UI 层负责 hop 到主线程）
    public var onSnapshots: (@Sendable ([RuleSnapshot]) -> Void)?

    /// ★ 声道处理（交换 / LFE 混音）该重新评估了 —— 在 `queue` 上触发。
    ///
    /// **为什么必须由本引擎广播**（这曾是一个真 bug，症状是"睡眠唤醒后
    /// 交换/混音静默失效，必须手动点一次重试"）：
    /// 声道处理跑在**另一条队列、另一个引擎**上（`ChannelSwapSupervisor` /
    /// `swapQueue`），它与 `RuleEngine` 零交互；而它的驱动把 `AudioDeviceID`
    /// **烧进了 AUHAL 单元**。唤醒时设备被销毁重建（实测 id 289 → 317 → 347），
    /// 旧单元随之失效 —— 但**没有任何人**通知它重新装配，
    /// `swapEngine.devicesChanged()` 自始至终是一次都没被调用的死代码。
    ///
    /// 触发点有两个，缺一不可（顺序也正确：本引擎先锁定格式，再轮到声道处理）：
    /// * **设备拓扑变化**（出现/消失/重建/音频服务重启/系统唤醒）——
    ///   覆盖"设备带着全部能力被创建"这一步；
    /// * **规则刚刚锁定**（`waitingForCapability` → `locked`）——
    ///   覆盖"设备已就绪但拓扑事件已用完"的情形：声道数门控要求 ≥6 声道，
    ///   而唤醒早期设备只有 2 声道（实测），此时若不再通知一次，
    ///   等待/回退序列耗尽后就会停在 `gaveUp`。
    ///
    /// - Parameter devicesDisappeared: 设备**被销毁**时为 true —— 消费方据此
    ///   强制重建音频通路（旧单元绑定的 `AudioDeviceID` 已失效）；
    ///   为 false 时消费方可以幂等短路，避免事件成簇时反复重启造成音频中断。
    ///
    /// 消费者（`AppEnvironment`）负责把它投递到 `swapQueue`；
    /// 本引擎**不认识**声道处理的任何类型（分层：Core 内部不反向依赖上层装配）。
    public var onChannelProcessingNeeded: (@Sendable (Bool) -> Void)?

    /// 上一轮报告时处于"已锁定"的规则。用于识别 `→ locked` 的**跃迁**，
    /// 避免"本来就锁着"的规则在每次兜底轮询里都重复通知（那些通知毫无信息量）。
    private var lastLockedRuleIDs: Set<UUID> = []

    private let service: CoreAudioServiceProtocol
    private let watcher: DeviceWatching
    private var sleepWake: SleepWakeObserving
    private let policy: ApplyPolicy
    private let applier: FormatApplier
    private let configProvider: @Sendable () -> AppConfig
    private let queue: DispatchQueue
    private let pollExecutor: DelayedExecutor?

    private var snapshots: [UUID: RuleSnapshot] = [:]
    private var pollGeneration: UInt64 = 0
    private var started = false

    /// 评估次数统计（测试与诊断用）
    public private(set) var evaluationCount = 0
    /// 实际写入次数统计（测试用：验证"不该写时一次都不写"）
    public private(set) var writeAttemptCount = 0

    public init(service: CoreAudioServiceProtocol,
                watcher: DeviceWatching,
                sleepWake: SleepWakeObserving,
                policy: ApplyPolicy,
                config: @escaping @Sendable () -> AppConfig,
                queue: DispatchQueue,
                pollExecutor: DelayedExecutor? = nil) {
        self.service = service
        self.watcher = watcher
        self.sleepWake = sleepWake
        self.policy = policy
        self.configProvider = config
        self.queue = queue
        self.pollExecutor = pollExecutor
        self.applier = FormatApplier(service: service)
    }

    /// 仅测试用：替换睡眠观察器（真实实现带看门狗，mock 没有）
    public func replaceSleepWakeForTesting(_ observer: SleepWakeObserving) {
        self.sleepWake = observer
    }

    // MARK: - 生命周期

    public func start() {
        guard !started else { return }
        started = true

        watcher.onEvent = { [weak self] event in
            self?.handle(event)
        }
        sleepWake.onSleep = { [weak self] in
            guard let self else { return }
            // 睡眠期间不评估，但要把状态刷新成"挂起"，让 UI 显示正确
            self.policy.resetForNewSession()
            self.evaluateAll(trigger: .deviceEvent)
        }
        sleepWake.onWake = { [weak self] in
            guard let self else { return }
            self.policy.resetForNewSession()
            self.beginPostWakePolling()
            self.evaluateAll(trigger: .systemWake)
            // ★ 唤醒的**第一手信号**（`didWake` / `screensDidWake`）：
            //   立刻让声道处理重新评估一次。
            //   不能只依赖随后的 `devices-list` 事件 —— 实测 `didWake` 会丢
            //   （两次睡眠只来 1 次），而 `screensDidWake` 反而两次都到；
            //   两个信号都转成通知，多通知一次只是多一次评估，不会漏。
            self.notifyChannelProcessingNeeded(reason: "系统唤醒")
        }

        watcher.start()
        sleepWake.start()
        // ★ 先把"启动瞬间就已锁定"的规则记下来，作为**跃迁**的基线：
        //   否则首次评估会把它们全当成"刚锁定"，白白通知一轮声道处理。
        lastLockedRuleIDs = Set(configProvider().rules.compactMap { rule in
            snapshots[rule.id]?.state == .locked ? rule.id : nil
        })
        evaluateAll(trigger: .deviceEvent)
        Log.info("RuleEngine 已启动，共 \(configProvider().rules.count) 条规则")
    }

    public func stop() {
        guard started else { return }
        started = false
        watcher.stop()
        sleepWake.stop()
        pollGeneration &+= 1        // 让挂起的轮询任务自行失效
    }

    // MARK: - 事件分发

    private func handle(_ event: WatchEvent) {
        switch event {
        case .devicesChanged, .deviceAppeared:
            evaluateAll(trigger: event.trigger)
            notifyChannelProcessingNeeded(reason: "设备拓扑变化")
        case .deviceDisappeared:
            // 设备被销毁：旧音频单元随之失效，消费方必须**强制**重建
            evaluateAll(trigger: .deviceEvent)
            notifyChannelProcessingNeeded(reason: "设备已消失", devicesDisappeared: true)
        case .nominalRateChanged, .physicalFormatChanged:
            evaluateAll(trigger: .inPlaceChange)
        case .systemRestarted:
            policy.resetForNewSession()
            evaluateAll(trigger: .deviceEvent)
            notifyChannelProcessingNeeded(reason: "音频服务重启", devicesDisappeared: true)
        case .woke:
            policy.resetForNewSession()
            evaluateAll(trigger: .systemWake)
            notifyChannelProcessingNeeded(reason: "系统唤醒")
        case .poll:
            evaluateAll(trigger: .poll)
        }
    }

    // MARK: - 对外动作

    /// 手动"立即应用"（单条规则）。
    ///
    /// 会清掉抑制窗口与退避 —— 用户按下按钮是明确指令，应当立即生效。
    public func applyNow(ruleID: UUID) {
        guard let rule = configProvider().rules.first(where: { $0.id == ruleID }) else { return }
        policy.clearBackoff(ruleID)
        evaluate(rule: rule, trigger: .manual, bypassSuppression: true)
        publish()
    }

    /// 手动"立即应用全部"
    public func applyAllNow() {
        let rules = configProvider().rules.filter(\.isEnabled)
        for rule in rules {
            policy.clearBackoff(rule.id)
            evaluate(rule: rule, trigger: .manual, bypassSuppression: true)
        }
        publish()
    }

    /// 刷新快照（打开弹出面板 / 定时刷新时调用）。
    ///
    /// **会真正评估一遍**，因此顺带修正漂移。
    /// 触发类型用 `.inPlaceChange`：这属于"顺带检查"，
    /// 对 `onConnectOnly` 策略的规则不应算作"接入"。
    public func refreshSnapshots() {
        watcher.rearm()                       // ★ 受监控集合可能变了（见 configDidChange）
        evaluateAll(trigger: .inPlaceChange)
    }

    /// 配置发生变化（新增 / 删除 / 编辑规则、启用状态变化）后调用。
    ///
    /// **必须做两件事**（否则有严重 bug）：
    /// 1. `watcher.rearm()` —— 受监控的设备集合变了。
    ///    实测踩到的现象：给一台**已连接且空闲**的设备新增规则后，
    ///    `DeviceWatcher` 从未为它注册监听器（re-arm 只在设备事件时发生），
    ///    于是就地变更检测失效、持续锁定形同虚设。
    /// 2. 以 `.manual` 立即评估 —— 用户刚添加规则就是明确意图，应当马上生效，
    ///    而不是等下一次设备事件（那可能是几小时后的唤醒）。
    public func configDidChange() {
        Log.info("配置已变更（共 \(configProvider().rules.count) 条规则），重新注册监听器并立即评估")
        watcher.rearm()
        evaluateAll(trigger: .manual)
    }

    public func currentSnapshots() -> [RuleSnapshot] {
        configProvider().rules.compactMap { snapshots[$0.id] }
    }

    // MARK: - 核心评估

    public func evaluateAll(trigger: TriggerKind) {
        evaluationCount += 1
        for rule in configProvider().rules where rule.isEnabled {
            evaluate(rule: rule, trigger: trigger, bypassSuppression: false)
        }
        // 未启用的规则也要有快照（UI 要显示）
        for rule in configProvider().rules where !rule.isEnabled {
            refreshSnapshot(for: rule)
        }
        publish()
    }

    private func evaluate(rule: DeviceRule, trigger: TriggerKind, bypassSuppression: Bool) {
        // ── 1. 睡眠期间一律不动作────────────────────────────────
        if sleepWake.isSleeping {
            report(rule, state: .suspended(.sleeping))
            return
        }

        // ── 2. 解析设备 ─────────────────────────────────────────
        guard let resolved = resolveDevice(for: rule) else {
            report(rule, state: .deviceAbsent)
            return
        }
        let descriptor = resolved.descriptor

        // ── 3. 读当前格式 ───────────────────────────────────────
        guard let currentASBD = service.currentPhysicalFormat(ofDevice: descriptor.id) else {
            report(rule, state: .deviceAbsent, descriptor: descriptor,
                   matchedViaFallback: resolved.viaFallback)
            return
        }
        let currentFormat = AudioFormatPreset(asbd: currentASBD)

        // ── 4. 幂等：已经是目标格式 ─────────────────────────────
        if rule.preset.matchesCurrent(currentASBD) {
            policy.resetFailures(rule.id)
            report(rule, state: .locked, descriptor: descriptor,
                   matchedViaFallback: resolved.viaFallback, currentFormat: currentFormat)
            return
        }

        // ── 5. 冲突策略 ─────────────────────────────────────────
        switch rule.conflictPolicy {
        case .paused:
            report(rule, state: .suspended(.userPaused), descriptor: descriptor,
                   matchedViaFallback: resolved.viaFallback, currentFormat: currentFormat)
            return
        case .onConnectOnly where !trigger.isConnectLike:
            report(rule, state: .suspended(.policyOnConnectOnly), descriptor: descriptor,
                   matchedViaFallback: resolved.viaFallback, currentFormat: currentFormat)
            return
        case .enforceAlways, .onConnectOnly:
            break
        }

        // ── 6. 自身写入抑制──────────────────────────────────────
        //   注意：这里直接 return 而不更新状态，保持上一次的状态显示。
        if !bypassSuppression, policy.isSuppressed(rule.id) {
            Log.debug("规则 \(rule.deviceName)：处于自身写入抑制窗口内，跳过本次评估")
            return
        }

        // ── 7. 冲突退避 ─────────────────────────────────────────
        if policy.isInBackoff(rule.id) {
            report(rule, state: .suspended(.conflictBackoff), descriptor: descriptor,
                   matchedViaFallback: resolved.viaFallback, currentFormat: currentFormat)
            return
        }

        // ── 8. ★ 能力门控───────────────────────────────────────
        let capability = service.capability(of: descriptor.id)
        guard capability.supports(rule.preset) else {
            // 这不是失败 —— 设备能力尚未到位（唤醒后 0~28 秒内必然出现）。
            // 什么都不做，等下一次 devices-list 事件。
            policy.resetFailures(rule.id)
            report(rule, state: .waitingForCapability(
                        availableMaxChannels: capability.maxChannelCount),
                   descriptor: descriptor,
                   matchedViaFallback: resolved.viaFallback,
                   currentFormat: currentFormat,
                   capability: capability)
            return
        }

        // ── 9. 写入 ────────────────────────────────────────────
        report(rule, state: .applying, descriptor: descriptor,
               matchedViaFallback: resolved.viaFallback, currentFormat: currentFormat,
               capability: capability)

        writeAttemptCount += 1
        Log.info("规则 \(rule.deviceName)：当前 \(currentFormat.compactString) "
                 + "→ 目标 \(rule.preset.compactString)（触发：\(trigger.displayText)）")

        let outcome = applier.apply(rule.preset, to: descriptor.id)
        handle(outcome, rule: rule, descriptor: descriptor,
               matchedViaFallback: resolved.viaFallback, capability: capability)
    }

    private func handle(_ outcome: ApplyOutcome,
                        rule: DeviceRule,
                        descriptor: DeviceDescriptor,
                        matchedViaFallback: Bool,
                        capability: DeviceCapability) {
        let afterASBD = service.currentPhysicalFormat(ofDevice: descriptor.id)
        let afterFormat = afterASBD.map { AudioFormatPreset(asbd: $0) }

        switch outcome {
        case .applied:
            policy.markApplied(rule.id)
            Log.info("\(rule.deviceName) 已锁定为 \(rule.preset.compactString)")
            report(rule, state: .locked, descriptor: descriptor,
                   matchedViaFallback: matchedViaFallback, currentFormat: afterFormat,
                   capability: capability, lastAppliedAt: Date(), lastError: nil)

        case .capabilityNotReady(let maxCh):
            // 竞态：能力在两次读取之间消失了。当作"等待"处理。
            policy.resetFailures(rule.id)
            report(rule, state: .waitingForCapability(availableMaxChannels: maxCh),
                   descriptor: descriptor, matchedViaFallback: matchedViaFallback,
                   currentFormat: afterFormat, capability: capability)

        default:
            let kind = outcome.failureKind ?? .unknown("未知")
            policy.markFailure(rule.id)
            Log.error("\(rule.deviceName)：\(outcome.logDescription)")
            report(rule, state: .failed(kind), descriptor: descriptor,
                   matchedViaFallback: matchedViaFallback, currentFormat: afterFormat,
                   capability: capability, lastError: outcome.logDescription)
        }
    }

    // MARK: - 设备解析

    private struct ResolvedDevice {
        let descriptor: DeviceDescriptor
        let viaFallback: Bool
    }

    private func resolveDevice(for rule: DeviceRule) -> ResolvedDevice? {
        // 优先 UID（实测稳定）
        if let descriptor = service.deviceDescriptor(forUID: rule.deviceUID) {
            return ResolvedDevice(descriptor: descriptor, viaFallback: false)
        }
        // 兜底：名称 + 传输类型（HDMI 的 UID 疑似由 EDID/端口派生，换端口会变）
        for descriptor in service.allOutputDevices() where rule.matches(descriptor) {
            Log.warn("规则 \(rule.deviceName)：UID 未匹配，改用名称+传输类型兜底匹配。"
                     + "建议在设置里重新绑定该设备。")
            return ResolvedDevice(descriptor: descriptor, viaFallback: true)
        }
        return nil
    }

    // MARK: - 快照

    private func report(_ rule: DeviceRule,
                        state: LockState,
                        descriptor: DeviceDescriptor? = nil,
                        matchedViaFallback: Bool = false,
                        currentFormat: AudioFormatPreset? = nil,
                        capability: DeviceCapability? = nil,
                        lastAppliedAt: Date? = nil,
                        lastError: String? = nil) {
        let capability = capability ?? descriptor.map { service.capability(of: $0.id) } ?? .empty
        let existing = snapshots[rule.id]

        // ★ 识别「非锁定 → 锁定」的跃迁，并据此通知声道处理重新评估。
        //   为什么盯这一步：唤醒后设备先带着 **2 声道**回来（实测），
        //   而声道处理的声道数门控要求 ≥6 —— 那一轮它只能进入等待/回退。
        //   等本引擎把格式锁回 8ch 后**必须再喂一次信号**，否则它要等完
        //   1-2-4-8 秒的回退序列；序列耗尽就停在 gaveUp，用户看到的是
        //   "唤醒了，但交换没回来"（正是本次要修的 bug）。
        let wasLocked = lastLockedRuleIDs.contains(rule.id)
        if state == .locked {
            lastLockedRuleIDs.insert(rule.id)
        } else {
            lastLockedRuleIDs.remove(rule.id)
        }

        snapshots[rule.id] = RuleSnapshot(
            ruleID: rule.id,
            deviceName: descriptor?.name ?? rule.deviceName,
            transportName: descriptor?.transportName ?? Self.transportName(rule.transportType),
            devicePresent: descriptor != nil,
            matchedViaFallback: matchedViaFallback,
            state: state,
            conflictPolicy: rule.conflictPolicy,
            isEnabled: rule.isEnabled,
            preset: rule.preset,
            currentFormat: currentFormat ?? existing?.currentFormat,
            capabilitySummary: capability.summary,
            capabilityMaxChannels: capability.maxChannelCount,
            capabilityCombinationCount: capability.combinationCount,
            lastAppliedAt: lastAppliedAt ?? existing?.lastAppliedAt,
            lastError: lastError ?? (state.isFailure ? existing?.lastError : nil),
            consecutiveFailures: policy.failureCount(rule.id))

        // 刚锁定（上一轮还不是）→ 通知声道处理：设备现在真的可用了
        if state == .locked, !wasLocked {
            notifyChannelProcessingNeeded(reason: "规则已锁定 \(rule.deviceName)")
        }
    }

    /// 通知声道处理（交换 / 混音）重新评估一次。
    ///
    /// ⚠️ **睡眠中一律不发**：睡眠期间设备会消失，此时让它去装配只会
    /// 撞上"设备不存在"→ 耗尽回退序列 → 弹一条**误导性**的"未能启动"告警。
    /// 唤醒后自然会收到设备事件，那时再启动才是有意义的。
    ///
    /// 真机实测（本次修复的验证日志）正是这样工作的：
    /// ```
    /// 20:43:16  设备消失（睡眠中）→ "声道处理通知已跳过（系统睡眠中）"
    /// 20:43:25  系统已唤醒          → 通知声道处理重新评估：系统唤醒
    /// 20:43:38  规则锁定 8ch        → 通知 → 交换通路自动重新装配
    /// ```
    private func notifyChannelProcessingNeeded(reason: String,
                                               devicesDisappeared: Bool = false) {
        guard !sleepWake.isSleeping else {
            Log.debug("声道处理通知已跳过（系统睡眠中）：\(reason)")
            return
        }
        guard let onChannelProcessingNeeded else { return }
        Log.debug("通知声道处理重新评估：\(reason)"
                  + (devicesDisappeared ? "（设备已销毁，强制重建通路）" : ""))
        onChannelProcessingNeeded(devicesDisappeared)
    }

    /// 不改变状态，只刷新设备/格式信息。
    ///
    /// ⚠️ 踩过的 bug：这里原来写的是 `previous?.state ?? (...)`，
    /// 于是**停用规则会沿用上一次的状态** —— 一条本来 `.locked` 的规则被停用后
    /// 快照仍是 `.locked`，菜单栏图标也就一直显示"已锁定"，
    /// 必须退出重启才正确。停用是用户的明确动作，必须**立即**反映。
    private func refreshSnapshot(for rule: DeviceRule) {
        guard let resolved = resolveDevice(for: rule) else {
            // 规则被停用时，优先如实显示"已暂停"，而不是"未连接"
            let absentState: LockState = rule.isEnabled ? .deviceAbsent : .suspended(.userPaused)
            snapshots[rule.id] = RuleSnapshot(
                ruleID: rule.id, deviceName: rule.deviceName,
                transportName: Self.transportName(rule.transportType),
                devicePresent: false, matchedViaFallback: false,
                state: absentState,
                conflictPolicy: rule.conflictPolicy, isEnabled: rule.isEnabled,
                preset: rule.preset, currentFormat: nil,
                capabilitySummary: "—", capabilityMaxChannels: 0, capabilityCombinationCount: 0,
                lastAppliedAt: snapshots[rule.id]?.lastAppliedAt,
                lastError: snapshots[rule.id]?.lastError,
                consecutiveFailures: policy.failureCount(rule.id))
            return
        }
        let capability = service.capability(of: resolved.descriptor.id)
        let current = service.currentPhysicalFormat(ofDevice: resolved.descriptor.id)
            .map { AudioFormatPreset(asbd: $0) }
        let previous = snapshots[rule.id]
        snapshots[rule.id] = RuleSnapshot(
            ruleID: rule.id,
            deviceName: resolved.descriptor.name,
            transportName: resolved.descriptor.transportName,
            devicePresent: true,
            matchedViaFallback: resolved.viaFallback,
            // ★ 停用 → 明确置为"已暂停"，不再沿用 previous
            state: rule.isEnabled ? (previous?.state ?? .deviceAbsent)
                                  : .suspended(.userPaused),
            conflictPolicy: rule.conflictPolicy,
            isEnabled: rule.isEnabled,
            preset: rule.preset,
            currentFormat: current,
            capabilitySummary: capability.summary,
            capabilityMaxChannels: capability.maxChannelCount,
            capabilityCombinationCount: capability.combinationCount,
            lastAppliedAt: previous?.lastAppliedAt,
            lastError: previous?.lastError,
            consecutiveFailures: policy.failureCount(rule.id))
    }

    private func publish() {
        let ordered = configProvider().rules.compactMap { snapshots[$0.id] }
        onSnapshots?(ordered)
    }

    private static func transportName(_ type: UInt32) -> String {
        switch type {
        case kAudioDeviceTransportTypeHDMI:        return "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
        case kAudioDeviceTransportTypeUSB:         return "USB"
        case kAudioDeviceTransportTypeBuiltIn:     return "内置"
        case kAudioDeviceTransportTypeVirtual:     return "虚拟"
        default:                                   return "其它"
        }
    }

    // MARK: - 唤醒后兜底轮询

    /// 依据：能力到位**总是**伴随设备重建（实测能力监听器从不触发），
    /// 所以主路径是事件驱动。这里只是极低成本的兜底，
    /// 防止某次能力到位没有伴随 `devices-list` 事件。
    private func beginPostWakePolling() {
        guard let pollExecutor else {
            Log.debug("兜底轮询未启用（未注入 pollExecutor）")
            return
        }
        pollGeneration &+= 1
        let generation = pollGeneration
        let config = configProvider()
        let deadline = Date().addingTimeInterval(Double(config.postWakePollDurationMs) / 1000)
        Log.info("唤醒后兜底轮询：每 \(config.postWakePollIntervalMs)ms 一次，"
                 + "持续 \(config.postWakePollDurationMs / 1000) 秒")
        schedulePoll(generation: generation, deadline: deadline,
                     intervalMs: config.postWakePollIntervalMs, executor: pollExecutor)
    }

    private func schedulePoll(generation: UInt64,
                              deadline: Date,
                              intervalMs: Int,
                              executor: @escaping DelayedExecutor) {
        executor(intervalMs) { [weak self] in
            guard let self, self.pollGeneration == generation else { return }
            guard Date() < deadline else {
                Log.debug("唤醒后兜底轮询结束")
                return
            }
            // 只在"等待能力就绪"时才真正评估，避免无谓工作
            if self.hasRuleWaitingForCapability() {
                self.evaluateAll(trigger: .poll)
            }
            self.schedulePoll(generation: generation, deadline: deadline,
                              intervalMs: intervalMs, executor: executor)
        }
    }

    private func hasRuleWaitingForCapability() -> Bool {
        snapshots.values.contains {
            if case .waitingForCapability = $0.state { return true }
            return false
        }
    }
}

private extension LockState {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}
