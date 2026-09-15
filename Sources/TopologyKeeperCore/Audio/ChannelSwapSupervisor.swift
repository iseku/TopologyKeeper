import CoreAudio
import Foundation

/// 「这一次重新评估是谁触发的」—— 只用于诊断可读性，不参与任何决策。
///
/// 必要性：`evaluateLocked` 有 4 个调用口（设置变更 / 设备变化 / 设备销毁 /
/// 回退到期），而**幂等短路**会把其中一部分变成同一句"跳过重新装配"。
/// 真机日志里那 5 条连发因此无从区分来源，排查时只能靠猜。
/// 把这个值带进日志，来源就是**直接读出来的**，不必再推理。
enum EvaluationOrigin: Hashable, CustomStringConvertible {
    /// 设置被推给引擎（`apply`）
    case settingsApplied
    /// 设备列表变化（插入 / 拔出 / 重建 / 唤醒）
    case devicesChanged
    /// 设备**被销毁**（强制重建，不做抑制）
    case devicesDisappeared
    /// 上一轮"等待"的退避计时到点
    case retryTimer

    var description: String {
        switch self {
        case .settingsApplied:    return "设置变更"
        case .devicesChanged:     return "设备变化"
        case .devicesDisappeared: return "设备销毁"
        case .retryTimer:         return "退避重试"
        }
    }

    /// 稳定的英文键 —— 诊断串里用它，避免中英混排
    var key: String {
        switch self {
        case .settingsApplied:    return "settings"
        case .devicesChanged:     return "devices"
        case .devicesDisappeared: return "disappeared"
        case .retryTimer:         return "retry"
        }
    }
}

/// 声道交换的**决策与重试状态机**（纯逻辑，可完整单测）。
///
/// 它与 `ChannelSwapEngine`（真正的 AUHAL 装配）分开的理由：
/// * 用户确认的三条策略（<6ch 报告等待、按 1-2-4-8 秒指数回退、穷尽后告警）
///   全是**时间 + 状态**驱动的逻辑，与音频硬件无关；
/// * 放在这里就能用 `immediateExecutor` / 假时钟完整测出"何时重试、何时放弃"，
///   而真实音频装配无法在单测里跑。
///
/// ## 状态流转
///
/// ```
/// disabled ──apply(enabled:false)──▶ disabled
///    │
///    └─apply(enabled:true)─▶ 解析设备
///                              ├─ 不满足 ─▶ waiting(attempt:n, next:backoff[n])
///                              │                │ 回退计时到点
///                              │                ├─ 仍不满足且序列未穷尽 ─▶ waiting(n+1)
///                              │                └─ 序列穷尽 ─▶ gaveUp ─(告警)
///                              └─ 满足 ─▶ 启动音频通路 ─▶ running
///                                                          │ 设备变化/出错
///                                                          └─▶ 重新解析（回到上面）
/// ```
public final class ChannelSwapSupervisor: @unchecked Sendable {

    /// 依赖：设备解析
    private let resolver: ChannelSwapDeviceResolving
    /// 依赖：音频通路（真实实现是 AUHAL；测试用 Mock）
    private let audio: ChannelSwapAudioDriving
    /// 依赖：延迟执行（测试传 immediateExecutor 或假时钟）
    private let executor: DelayedExecutor
    /// 依赖：告警（穷尽回退后调用）
    private let notifier: (@Sendable (String) -> Void)?

    /// 状态变化通知（值类型，跨线程安全）
    public var onStateChange: (@Sendable (ChannelSwapState) -> Void)?

    // ── 可变状态：**只在 `queue` 上读写**；对外通过下面的同步读接口暴露 ──
    private var _state: ChannelSwapState = .disabled
    private var _appliedChannelMap: [Int32]?
    private var _sampleRateAligned: String?
    private var _currentInput: ChannelSwapDeviceInfo?
    private var _currentOutput: ChannelSwapDeviceInfo?
    /// LFE 混音当前状态描述（nil = 未开启）。诊断与 UI 用。
    private var _mixDescription: String?
    /// ★ 当前通路**已绑定**的输入/输出设备（成功启动时记录，stop 时清空）。
    ///
    /// 用途：设备事件往往**成簇到来**（实测唤醒时 `devices-list` 单次触发 8 次、
    /// 设备重建 2~3 次），而 `AudioDeviceID` 与通道数的解析结果只有"变"和"没变"
    /// 两种。设备解析结果完全一致时重新装配是**纯损失** —— 会听到音频中断，
    /// 且没有任何语义收益。真机实测过：修复唤醒失效问题时，
    /// 同一瞬间连着重启了 4 次（间隔约 130ms）。
    private var _runningInput: ChannelSwapDeviceInfo?
    private var _runningOutput: ChannelSwapDeviceInfo?
    /// 当前通路是按**哪一份设置**装配的。
    ///
    /// 必要性：设备没变、但设置变了（用户调了混音增益 / 换了源声道）时**必须**重装，
    /// 否则会出现"改了配置没反应" —— 那是本项目已经踩过一次的坑
    /// （见 `AppState.reapplyChannelSwap` 的说明）。
    /// 有了它，短路判据才能安全地只管"设备"，不必去猜设置。
    private var _runningSettings: ChannelSwapSettings?
    /// 因"设备与设置都没变"跳过重新装配的累计次数，**按触发来源分开统计**。
    ///
    /// 为什么要分来源：这条日志本身只说明"评估被幂等短路拦下了"，
    /// 而**谁在反复喂评估**才是排查时要回答的问题 —— 真机日志里
    /// 唤醒后一口气出现 5 条，光看总数无法区分它们是设备事件簇、
    /// 规则锁定通知，还是用户手动重试。分开计数后一眼可辨。
    private var _skippedByOrigin: [EvaluationOrigin: Int] = [:]

    /// 唯一的队列身份标识，用于判断"我是否已经在该队列上"。
    ///
    /// ⚠️ 为什么需要它：这些对外读取接口内部用 `queue.sync` 取一致快照，
    /// 而内部逻辑本身就跑在同一条队列上。如果内部代码不小心读了**公开**属性
    /// （而不是私有存储），就会 `queue.sync` 到自己 → **自死锁**。
    /// 这个 bug 我实际踩过一次（采样率对齐分支里的 `sampleRateAligned`）。
    /// 有了本判断，即使将来再写错也不会死锁。
    private static let queueKey = DispatchSpecificKey<UInt8>()

    /// 在队列上同步取快照；**若已在该队列上则直接执行**，避免自死锁
    @inline(__always)
    private func onQueue<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil { return body() }
        return queue.sync(execute: body)
    }

    /// 当前状态。跨线程安全。
    public var state: ChannelSwapState { onQueue { _state } }

    /// 最近一次成功写入并回读的 ChannelMap（API 0-based）。跨线程安全。
    public var appliedChannelMap: [Int32]? { onQueue { _appliedChannelMap } }

    /// 采样率对齐结果描述。跨线程安全。
    public var sampleRateAligned: String? { onQueue { _sampleRateAligned } }

    /// 当前解析到的输入设备。跨线程安全。
    public var currentInput: ChannelSwapDeviceInfo? { onQueue { _currentInput } }

    /// 当前解析到的输出设备。跨线程安全。
    public var currentOutput: ChannelSwapDeviceInfo? { onQueue { _currentOutput } }

    /// LFE 混音当前状态描述（nil = 未开启）。跨线程安全。
    public var mixDescription: String? { onQueue { _mixDescription } }

    private let queue: DispatchQueue
    private var settings = ChannelSwapSettings()
    private var attempt = 0
    /// 世代号：任何一次 apply/stop 都让它自增，使旧的延迟任务自行失效
    /// （这个模式在 `RuleEngine.beginPostWakePolling` 里已经用过，避免陈旧回调）
    private var generation: UInt64 = 0
    /// 是否已经为"当前这轮等待"发过告警，避免重复打扰
    private var didNotifyGiveUp = false

    public init(resolver: ChannelSwapDeviceResolving,
                audio: ChannelSwapAudioDriving,
                queue: DispatchQueue,
                executor: DelayedExecutor? = nil,
                notifier: (@Sendable (String) -> Void)? = nil) {
        self.resolver = resolver
        self.audio = audio
        self.queue = queue
        queue.setSpecific(key: Self.queueKey, value: 1)
        self.executor = executor ?? makeQueueExecutor(queue)
        self.notifier = notifier
    }

    // MARK: - 对外动作

    /// 应用设置（幂等：设置没变且状态稳定时不重复动作）
    public func apply(_ newSettings: ChannelSwapSettings) {
        queue.async { [weak self] in self?.applyLocked(newSettings) }
    }

    public func stop() {
        queue.async { [weak self] in self?.stopLocked() }
    }

    /// 设备列表发生变化（插入/拔出/重建/唤醒）时调用 —— 立即重新解析。
    ///
    /// 幂等：解析结果与当前运行的通路一致时**不重新装配**（只清掉回退等待）。
    /// 见 `_runningOutput` 的说明。
    public func devicesChanged() {
        queue.async { [weak self] in
            // ★ 用 needsAudioPath 而不是 isEnabled：只开混音时通路同样要跑
            guard let self, self.settings.needsAudioPath else { return }
            // 设备变化属于"新情况"，重置回退计数，给足重试机会
            self.attempt = 0
            self.didNotifyGiveUp = false
            self.evaluateLocked(origin: .devicesChanged)
        }
    }

    /// ★ 设备**被销毁**（消失/重建前）时调用 —— 强制重新装配，不做任何抑制。
    ///
    /// 与 `devicesChanged()` 分开的理由：旧设备消失意味着 AUHAL 单元绑定的
    /// `AudioDeviceID` 已经失效，**必须**重建通路；而 `AudioDeviceID` 是会被
    /// 系统复用的，所以"解析结果恰好相同"不能证明"还是原来那个设备"。
    /// 把这条语义显式表达出来，抑制逻辑就不会误吞真正必要的重建。
    public func devicesDisappeared() {
        queue.async { [weak self] in
            guard let self, self.settings.needsAudioPath else { return }
            // 运行中的绑定立即作废：下一次评估必定重新装配
            self._runningInput = nil
            self._runningOutput = nil
            self._runningSettings = nil
            // 旧设备的短路统计随绑定一起作废（它描述的是"那条通路"的幂等情况）
            self._skippedByOrigin.removeAll()
            self.attempt = 0
            self.didNotifyGiveUp = false
            self.evaluateLocked(origin: .devicesDisappeared)
        }
    }

    // MARK: - 核心

    private func applyLocked(_ newSettings: ChannelSwapSettings) {
        let settingsChanged = (newSettings != settings)
        settings = newSettings
        generation &+= 1                 // 让挂起的回退任务失效
        didNotifyGiveUp = false

        // ★ 只有**两个功能都关**时才停掉通路
        guard newSettings.needsAudioPath else {
            stopAudioLocked()
            attempt = 0
            setState(.disabled)
            return
        }

        // 已启用且设置未变、且正在运行 → 不折腾（幂等）
        if !settingsChanged, _state.isRunning { return }

        attempt = 0
        evaluateLocked(origin: .settingsApplied)
    }

    private func stopLocked() {
        generation &+= 1
        stopAudioLocked()
        attempt = 0
        didNotifyGiveUp = false
        setState(.disabled)
    }

    private func stopAudioLocked() {
        _mixDescription = nil
        audio.stop()
        _appliedChannelMap = nil
        _sampleRateAligned = nil
        // 绑定作废：下次评估必须重新装配
        _runningInput = nil
        _runningOutput = nil
        _runningSettings = nil
    }

    /// 解析设备 + 判定是否可交换 + 启动或安排回退
    ///
    /// - Parameter origin: 本次评估的触发来源 —— **只进日志与诊断**，不影响任何判据。
    private func evaluateLocked(origin: EvaluationOrigin) {
        // ★ 同理：只开混音也要评估并启动通路
        guard settings.needsAudioPath else { return }

        // ── 1. 输入设备（BlackHole）─────────────────────────────
        guard let input = resolver.device(uid: settings.inputDeviceUID,
                                         namePrefix: "BlackHole") else {
            scheduleRetryLocked(reason: .inputDeviceMissing)
            return
        }
        _currentInput = input

        // ── 2. 输出设备（≥6ch 且非 BlackHole）───────────────────
        let output: ChannelSwapDeviceInfo?
        if let uid = settings.outputDeviceUID {
            // 指定了 UID：用它，但仍要校验条件
            output = resolver.device(uid: uid, namePrefix: "")
        } else {
            output = resolver.preferredOutputDevice(excludingNamePrefix: "BlackHole")
        }
        guard let output else {
            scheduleRetryLocked(reason: .outputDeviceMissing)
            return
        }
        _currentOutput = output

        // ── 3. ★ 能力门控：声道数必须 ≥6（用户确认：不足则"等待"而非报错）──
        let required = ChannelSwapPlan.minimumChannelCount
        guard output.usableChannels >= required else {
            scheduleRetryLocked(reason: .outputChannelsTooFew(current: output.usableChannels,
                                                              required: required))
            return
        }

        // ── 3.5 ★ 抑制无谓的重新装配 ────────────────────────────
        //
        // 设备事件成簇到来时（唤醒实测：单次 `devices-list` 触发 8 次、
        // 设备重建 2~3 次），解析结果往往完全一致。此时重新装配是纯损失：
        // 音频会断一下，功能没有任何变化。
        // 判据取**完整设备信息**（uid + AudioDeviceID + 通道数 + 采样率），
        // 而不是只比 UID —— `AudioDeviceID` 变化正是"设备被重建"的标志。
        //
        // ⚠️ 设置变了**不能**跳过：用户调了混音增益/源声道时必须重装
        //    （"改了配置没反应"是本项目踩过的坑），所以一并比对 `_runningSettings`。
        // ⚠️ 设备**消失**过的情形不走这里：`devicesDisappeared()` 会把绑定清空，
        //    于是必然重新装配（`AudioDeviceID` 会被系统复用，不能只靠比对）。
        if _state.isRunning,
           let ri = _runningInput, let ro = _runningOutput,
           ri == input, ro == output,
           _runningSettings == settings {
            _skippedByOrigin[origin, default: 0] += 1
            let total = _skippedByOrigin.values.reduce(0, +)
            // ★ 只在某个来源**首次**被拦下时说话，之后同类跳过静默累加。
            //   理由：设备事件成簇到来（唤醒实测单次 `devices-list` 触发 8 次），
            //   逐次打印会把同一句话刷屏，而它携带的信息量是**零** ——
            //   "又一次什么都没变"重复 N 遍不等于 N 倍信息。
            //   真机日志实证：唤醒后连发 5 条，事后无法分辨是哪几个来源触发的。
            if _skippedByOrigin[origin] == 1 {
                Log.debug("声道处理：设备与设置都未变，跳过重新装配（幂等短路）"
                          + "（\(input.name) → \(output.name)"
                          + "，触发=\(origin)，累计 \(total) 次）")
            }
            return
        }

        // ── 4. 生成交换计划（含参数合法性校验）──────────────────
        //
        // ★ 只有**交换功能开着**才真的做交换。
        //   混音与交换共用这条通路，但两者互斥；若只开混音却仍按配置里的
        //   first/second 去交换，就会平白把 C/LFE 对调 —— 那既不是用户要的，
        //   也会让混音的目标声道含义错位（实测表现为"开了混音反而更不对"）。
        //   ⇒ 只开混音时，交换计划必须是**恒等**。
        let swapWanted = settings.isEnabled
        guard let plan = settings.plan(forOutputChannels: output.usableChannels,
                                       identityWhenDisabled: !swapWanted) else {
            // 声道号配置越界等 —— 这属于**配置错误**，不是"等待"，立即报失败
            stopAudioLocked()
            setState(.failed(message: "交换声道配置无效："
                             + "第\(settings.firstChannel)声道 ↔ 第\(settings.secondChannel)声道"
                             + "（设备只有 \(output.usableChannels) 声道）"))
            return
        }

        // ── 5. 采样率对齐（只写输入设备）───────────────────────
        _sampleRateAligned = nil
        if settings.alignInputSampleRate,
           abs(input.nominalSampleRate - output.nominalSampleRate) > 0.5 {
            let status = resolver.setNominalSampleRate(output.nominalSampleRate, on: input)
            if status == noErr {
                _sampleRateAligned = "BlackHole \(Int(input.nominalSampleRate))Hz → "
                    + "\(Int(output.nominalSampleRate))Hz"
                // ⚠️ 这里必须读**私有存储**：公开的 `sampleRateAligned`
                //    内部是 `queue.sync`，此刻我们正在该队列上执行 → 自死锁。
                Log.info("声道交换：已把输入设备采样率对齐到输出设备"
                         + "（\(_sampleRateAligned ?? "")）")
            } else {
                Log.warn("声道交换：输入设备采样率对齐失败（\(CoreAudioHelpers.describe(status))），"
                         + "继续按现状启动")
                _sampleRateAligned = "对齐失败（\(CoreAudioHelpers.describe(status))）"
            }
        }

        // ── 6. 启动音频通路 ────────────────────────────────────
        setState(.starting)

        // ★ LFE 混音：在启动前解析成"源/目标索引 + 线性增益"。
        //
        //   两个要点（都有实测依据）：
        //   ① **索引必须问设备**（`declaredChannelIndices`），不能查表 ——
        //      本机 27C3A Pro 声明的顺序是 L R LFE C，与 MPEG 约定相反；
        //      混错方向 = 混进没有声音的通道，且不报错（静默失效）。
        //   ② 目标默认**跟随交换**，否则"开交换"与"开混音"会互相抵消。
        let declared = resolver.declaredChannelIndices(of: output)
        // ⚠️ 恒等交换要当作"没有交换"：否则"内容会挪位"的推断会凭空生效，
        //    把目标算到与源重合的位置上（这正是第一版解析互相打架的原因）。
        let effectiveSwap: ChannelSwapPlan? = plan.isIdentity ? nil : plan
        var resolvedMix: LfeMixPlan.Resolved?
        if settings.mixEnabled {
            let mixPlan = settings.mixPlan(forOutputChannels: output.usableChannels,
                                           declared: declared,
                                           swapPlan: effectiveSwap)
            resolvedMix = mixPlan.resolved()
            if resolvedMix == nil {
                // 混音不可用**不阻断交换**（交换是独立功能，仍然要跑），
                // 但必须留下明确日志与状态文本 —— 不能静默失效。
                Log.warn("LFE 混音已开启但计划不可用，本机将不做混音："
                         + (mixPlan.unavailableReason ?? "参数不合法")
                         + "；设备声明：" + (declared.map(CoreAudioHelpers.describe) ?? "读不到"))
            }
        }
        // 描述串：混音不可用时必须**明说**，不能显示成正常（静默失效防护）。
        // "不可用"的两种来源：交换与混音互斥；或计划本身不合法（越界/自混）。
        //
        // ★ 用 `transferFunction`（传递函数首行）而**不是** `description`（装配摘要）——
        //   配置页显示的是传递函数，状态栏此前显示装配摘要，
        //   同一件事两种写法，用户一眼就看出不一致。现在两处共用同一份生成逻辑。
        _mixDescription = settings.mixEnabled
            ? (resolvedMix.map { $0.transferFunction } ?? "已开启但不可用")
            : nil

        // 系统默认输出是否就是目标设备 —— 决定用 DefaultOutput 还是 HALOutput
        // （依据：DefaultOutput 跟随系统默认输出；实测该路径已听感确认可用）
        let isDefault = (resolver.defaultOutputDevice()?.uid == output.uid)
        do {
            let map = try audio.start(plan: plan,
                                      input: input,
                                      output: output,
                                      outputIsSystemDefault: isDefault,
                                      mix: resolvedMix)
            _appliedChannelMap = map
            _runningInput = input
            _runningOutput = output
            _runningSettings = settings
            attempt = 0
            didNotifyGiveUp = false
            // ★ 日志按**当前生效的功能**取名并描述映射。
            //   只开混音时交换是恒等的，先前会打出
            //   "声道交换已启动…左(第1声道) ↔ 左(第1声道)" ——
            //   既不成立（与自己交换），也会把排查引到交换方向去。
            let functionName = settings.mixEnabled ? "LFE 混音" : "声道交换"
            let mapping = settings.mixEnabled
                ? (resolvedMix.map { $0.description } ?? "混音参数不可用")
                : plan.swapDescription
            Log.info("\(functionName)通路已启动：\(input.name) → \(output.name)"
                     + "（\(output.usableChannels) 声道，\(mapping)，"
                     + "输出单元=\(isDefault ? "DefaultOutput" : "HALOutput 绑设备")）")
            if let mix = resolvedMix {
                Log.info("LFE 混音已启用：\(mix.description)"
                         + "；设备声明声道顺序：\(declared.map(CoreAudioHelpers.describe) ?? "读不到")")
            }
            setState(.running)
        } catch {
            stopAudioLocked()
            // 启动失败也走重试（设备可能正在重建），但不无限：沿用同一套回退
            Log.error("声道交换启动失败：\(error)")
            scheduleRetryLocked(reason: .outputDeviceMissing,
                                failureMessage: "\(error)")
        }
    }

    /// 安排一次退避重试；序列穷尽则放弃并告警
    private func scheduleRetryLocked(reason: ChannelSwapState.WaitReason,
                                    failureMessage: String? = nil) {
        stopAudioLocked()

        let backoffs = settings.retryBackoffMs
        guard attempt < backoffs.count else {
            // ★ 穷尽 → 放弃 + 告警（用户确认）
            let attempts = attempt
            setState(.gaveUp(reason: reason, attempts: attempts))
            if settings.notifyOnGiveUp, !didNotifyGiveUp {
                didNotifyGiveUp = true
                notifier?("声道交换已停止：\(reason.displayText)。"
                          + "已重试 \(attempts) 次（\(settings.backoffDescription)），仍不满足条件。")
            }
            Log.error("声道交换放弃：\(reason.displayText)（已重试 \(attempts) 次）"
                      + (failureMessage.map { "；最后错误：\($0)" } ?? ""))
            return
        }

        let delay = backoffs[attempt]
        attempt += 1
        Log.info("声道交换等待：\(reason.displayText) → \(delay / 1000) 秒后重试"
                 + "（第 \(attempt)/\(backoffs.count) 次）")
        setState(.waiting(reason: reason, attempt: attempt, nextRetryInMs: delay))

        let expectedGeneration = generation
        executor(delay) { [weak self] in
            guard let self, self.generation == expectedGeneration else { return }
            self.evaluateLocked(origin: .retryTimer)
        }
    }

    private func setState(_ new: ChannelSwapState) {
        guard new != _state else { return }
        _state = new
        onStateChange?(new)
    }

    // MARK: - 诊断

    public func diagnostics() -> ChannelSwapDiagnostics {
        // 在 queue 上一次性取快照：逐字段 sync 会读到彼此不一致的状态
        onQueue {
            let stats = audio.stats()
            return ChannelSwapDiagnostics(
                state: _state,
                inputDeviceName: _currentInput?.name,
                inputChannelCount: _currentInput?.inputChannels ?? 0,
                outputDeviceName: _currentOutput?.name,
                outputChannelCount: _currentOutput?.usableChannels ?? 0,
                appliedChannelMap: _appliedChannelMap,
                sampleRateAligned: _sampleRateAligned,
                inputCallbackCount: stats.inputCallbackCount,
                outputCallbackCount: stats.outputCallbackCount,
                framesIn: stats.framesIn,
                framesOut: stats.framesOut,
                underruns: stats.underruns,
                renderFailures: stats.renderFailures,
                // ★ 功能感知：把"现在在跑哪个功能"与"混音实际接线"一并交给 UI。
                //   不这样做的话，UI 只能用交换的措辞显示混音状态
                //   （已确认的适配缺口：显示"交换中" + "恒等映射"）。
                activeFunction: settings.mixEnabled ? .mix : .swap,
                mixDescription: _mixDescription,
                // ★ 幂等短路的来源分布（诊断用）：回答"是谁在反复喂评估"。
                //   真机排查实证：唤醒后连发 5 条"跳过重新装配"，
                //   只看条数无法判断触发源，于是只能靠推理；这里直接给出答案。
                skipStatistics: Self.describeSkips(_skippedByOrigin))
        }
    }

    /// 当前的回退尝试次数。跨线程安全。
    public var retryAttempt: Int { onQueue { attempt } }

    /// 把跳过统计渲染成一行稳定的诊断串，例：`devices=5`。
    ///
    /// 用固定顺序输出（而不是字典的随机顺序），否则同一份状态每次读出的字符串
    /// 都可能不同 —— 那会让 UI 误判成"有新变化"而反复刷新。
    private static func describeSkips(_ counts: [EvaluationOrigin: Int]) -> String? {
        guard !counts.isEmpty else { return nil }
        let order: [EvaluationOrigin] = [.devicesChanged, .settingsApplied,
                                        .devicesDisappeared, .retryTimer]
        let parts = order.compactMap { origin -> String? in
            guard let n = counts[origin], n > 0 else { return nil }
            return "\(origin.key)=\(n)"
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}
