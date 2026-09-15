import CoreAudio
import Foundation

/// 当前生效的**声道处理功能**。
///
/// 「声道交换」与「LFE 混音」互斥（用户确认的产品定义），所以任一时刻至多只有一个生效。
///
/// ## 为什么需要这个类型
///
/// 两者**共用同一条音频通路与同一个引擎**（`ChannelSwapSupervisor`，内部名保留
/// `ChannelSwap*` 不改）。于是引擎内部一律沿用"交换"的措辞就会误导用户 ——
/// 实测：开了混音之后，首页与设置页的状态栏仍显示"交换中"，
/// 「映射」一行显示"恒等映射（不交换）"，看起来像没生效。
///
/// ⇒ **凡是要展示给用户的**状态文案与映射描述，都必须先经过本类型。
///   引擎内部标识符（`swapState` / `ChannelSwapDiagnostics` 等）保持不动：
///   它们同时服务交换与混音，改名收益为零而回归面很大。
public enum ChannelProcessingFunction: String, Sendable, Equatable, CaseIterable {

    /// 声道交换：置换第 3/4 声道（数学本质是**置换**，零和）
    case swap

    /// LFE 混音：把选定的上游声道衰减后混入目标输出声道（数学本质是**求和**，非零和）
    case mix

    /// 功能全称（标题栏用）
    public var displayName: String {
        switch self {
        case .swap: return "声道交换"
        case .mix:  return "LFE 混音"
        }
    }

    /// 通路运行中的状态文案
    public var runningText: String {
        switch self {
        case .swap: return "交换中"
        case .mix:  return "混音中"
        }
    }
}

/// 声道交换引擎的状态。
///
/// 设计原则（对应《探针结论-声道交换.md》§6.1 / 用户确认的三条策略）：
/// * **<6 声道不是失败**，而是"等待" —— 目标设备可能只是暂时掉回 2ch
///   （这正是 TopologyKeeper 格式锁定要治的病），应当退避重试而不是报错。
/// * 回退序列穷尽后仍不满足 → `.gaveUp`，由上层弹告警（用户确认 1-2-4-8 秒）。
public enum ChannelSwapState: Equatable, Sendable {

    /// 总开关关闭（不占用任何音频设备）
    case disabled
    /// 正在启动/装配
    case starting
    /// 正常运行中
    case running
    /// 等待可交换条件（如目标设备声道数不足、设备未出现）
    case waiting(reason: WaitReason, attempt: Int, nextRetryInMs: Int)
    /// 已重试 `attempts` 次仍不满足，已放弃并告警
    case gaveUp(reason: WaitReason, attempts: Int)
    /// 运行中出错
    case failed(message: String)

    /// 为什么在等待
    public enum WaitReason: Equatable, Sendable {
        /// 找不到输入设备（BlackHole）
        case inputDeviceMissing
        /// 找不到符合条件（>=6ch 且非 BlackHole）的输出设备
        case outputDeviceMissing
        /// 找到输出设备了，但它当前声道数不够
        case outputChannelsTooFew(current: Int, required: Int)
        /// 设备列表为空（音频服务异常）
        case noDevices

        public var displayText: String {
            switch self {
            case .inputDeviceMissing:
                return "未找到 BlackHole 输入设备"
            case .outputDeviceMissing:
                return "未找到 ≥\(ChannelSwapPlan.minimumChannelCount) 声道的输出设备"
            case .outputChannelsTooFew(let current, let required):
                return "目标设备当前 \(current) 声道，需要 ≥\(required) 声道"
            case .noDevices:
                return "未检测到音频设备"
            }
        }
    }

    public var isRunning: Bool { self == .running }

    /// 是否需要上层提示用户（菜单栏着色 / 通知）
    public var needsAttention: Bool {
        switch self {
        case .gaveUp, .failed: return true
        default: return false
        }
    }

    public var displayText: String {
        switch self {
        case .disabled:  return "未启用"
        case .starting:  return "正在启动…"
        case .running:   return "交换中"
        case .waiting(let reason, let attempt, let next):
            return "等待：\(reason.displayText)（第 \(attempt) 次重试，\(next / 1000) 秒后）"
        case .gaveUp(let reason, let attempts):
            return "已放弃：\(reason.displayText)（重试 \(attempts) 次）"
        case .failed(let message):
            return "出错：\(message)"
        }
    }
}

/// 声道交换引擎的抽象边界。
///
/// 与 `CoreAudioServiceProtocol` 同样的地位：**上层只依赖本协议**，
/// 因此状态机 / 回退逻辑可以用 Mock 完整单测，不需要任何音频硬件。
///
/// 线程约定：所有方法在**同一条串行队列**上调用（`AppEnvironment.swapQueue`）。
/// 注意这与真实的 HAL 回调线程是两回事 —— 后者由 `ChannelSwapEngine` 内部管理，
/// 且受实时线程纪律约束（不加锁、不分配、不写日志）。
public protocol ChannelSwapEngineable: AnyObject, Sendable {

    /// 当前状态（读）
    var state: ChannelSwapState { get }

    /// 应用设置：启动 / 停止 / 重配置。
    ///
    /// * `isEnabled == false` → 停止（释放设备）
    /// * `isEnabled == true`  → 按当前设备情况启动；条件不满足则进入等待+退避
    ///
    /// 幂等：重复调用相同设置不应造成抖动（内部比较设置是否真的变了）。
    func apply(_ settings: ChannelSwapSettings,
               configProvider: @escaping @Sendable () -> AppConfig)

    /// 停止并释放（App 退出 / 用户关闭总开关）
    func stop()

    /// 状态变化回调（在调用方的队列上触发）
    var onStateChange: (@Sendable (ChannelSwapState) -> Void)? { get set }

    /// 供诊断展示的运行统计（`tkctl swap status`）
    func diagnostics() -> ChannelSwapDiagnostics

    /// 设备列表发生变化（插入/重建/唤醒）时的通知 —— 允许幂等短路
    func devicesChanged()

    /// ★ 设备**被销毁**（消失/重建前）时调用 —— 强制重新装配音频通路。
    ///
    /// 与"设备列表变化"分开的语义：旧设备消失意味着 AUHAL 单元绑定的
    /// `AudioDeviceID` 已失效，**必须**重建；而 `AudioDeviceID` 会被系统复用，
    /// 所以不能靠"解析结果是否相同"来判断。
    ///
    /// ⚠️ 刻意**不给协议扩展默认实现**：默认实现只能退化成"什么都不做"
    /// （协议里没有可回落的方法），那正好是"静默失效"的写法。
    /// 唯一实现是 `ChannelSwapEngine`，让编译器强制每个实现都表态。
    func devicesDisappeared()
}

/// 诊断快照（值类型，便于跨线程传递与展示）
public struct ChannelSwapDiagnostics: Equatable, Sendable {
    public var state: ChannelSwapState
    public var inputDeviceName: String?
    public var inputChannelCount: Int
    public var outputDeviceName: String?
    public var outputChannelCount: Int
    /// 实际写入的 ChannelMap（**API 0-based**）；来自回读，nil 表示未设置
    public var appliedChannelMap: [Int32]?
    /// 采样率对齐结果（nil 表示无需对齐或未执行）
    public var sampleRateAligned: String?
    /// 实时统计
    public var inputCallbackCount: Int
    public var outputCallbackCount: Int
    public var framesIn: Int64
    public var framesOut: Int64
    public var underruns: Int64
    public var renderFailures: Int64

    /// 当前生效的声道处理功能（交换 / 混音）。两者互斥，故只有一个。
    ///
    /// 由引擎按 `settings.mixEnabled` 写入 —— **不要**让 UI 自己推导，
    /// 否则 UI 与引擎对"现在在跑什么"会有两套判断，必然漂移。
    public var activeFunction: ChannelProcessingFunction

    /// 混音的实际传递函数描述（如 `CH3-I → CH4-O ×0.316`）；nil = 未装配混音。
    ///
    /// 装配失败时为 `"已开启但不可用"`，**不会**是 nil —— 静默失效防护。
    public var mixDescription: String?

    /// 幂等短路（"设备与设置都未变，跳过重新装配"）的**触发来源分布**，
    /// 例 `"devices=5"`；nil = 从未跳过。
    ///
    /// 为什么需要它：这条短路本身是正确行为（避免重装导致音频中断），
    /// 但"到底是谁在反复喂评估"必须可回答 —— 真机排查时那 5 条连发日志
    /// 只有条数、没有来源，只能靠推理。这里把来源直接摆出来。
    public var skipStatistics: String?

    public init(state: ChannelSwapState = .disabled,
                inputDeviceName: String? = nil,
                inputChannelCount: Int = 0,
                outputDeviceName: String? = nil,
                outputChannelCount: Int = 0,
                appliedChannelMap: [Int32]? = nil,
                sampleRateAligned: String? = nil,
                inputCallbackCount: Int = 0,
                outputCallbackCount: Int = 0,
                framesIn: Int64 = 0,
                framesOut: Int64 = 0,
                underruns: Int64 = 0,
                renderFailures: Int64 = 0,
                activeFunction: ChannelProcessingFunction = .swap,
                mixDescription: String? = nil,
                skipStatistics: String? = nil) {
        self.state = state
        self.inputDeviceName = inputDeviceName
        self.inputChannelCount = inputChannelCount
        self.outputDeviceName = outputDeviceName
        self.outputChannelCount = outputChannelCount
        self.appliedChannelMap = appliedChannelMap
        self.sampleRateAligned = sampleRateAligned
        self.inputCallbackCount = inputCallbackCount
        self.outputCallbackCount = outputCallbackCount
        self.framesIn = framesIn
        self.framesOut = framesOut
        self.underruns = underruns
        self.renderFailures = renderFailures
        self.activeFunction = activeFunction
        self.mixDescription = mixDescription
        self.skipStatistics = skipStatistics
    }

    /// 状态文案（**功能感知**）—— 首页 / 声道处理页 / 菜单栏提示共用。
    ///
    /// ⚠️ **不要**直接用 `state.displayText`：那个按"交换"写死，
    /// 开了混音时会显示成"交换中"，是已确认的适配缺口。
    /// 非运行态（等待/失败/未启用）与功能无关，仍走 `state.displayText`。
    public var statusText: String {
        if case .running = state { return activeFunction.runningText }
        return state.displayText
    }

    /// 「映射」一行的文案（**功能感知**）。
    ///
    /// * 交换 → ChannelMap 的 1-based 描述
    /// * 混音 → 实际生效的混音传递函数
    ///
    /// ⚠️ 混音时**绝不能**回落到 `channelMapDescription`：混音不写 ChannelMap，
    /// 那个值恒为"恒等映射（不交换）"，会让用户误判成混音没生效。
    public var mappingDescription: String {
        guard activeFunction == .mix else { return channelMapDescription }
        return mixDescription ?? "未装配"
    }

    /// ChannelMap 的 1-based 可读描述，**输入在前**，例
    /// `"CH4-I → CH3-O、CH3-I → CH4-O"`。
    ///
    /// 方向约定（用户确认）：**先输入、后输出**。
    /// 先前写成 `"第3声道 ← 源第4声道"` —— 输入在后，与"读哪条、写哪条"的
    /// 天然阅读顺序相反，也和混音传递函数（`CH4-O = CH4-I + …`）的记法不一致。
    public var channelMapDescription: String {
        guard let map = appliedChannelMap else { return "未设置" }
        let changed = map.enumerated().filter { Int32($0.offset) != $0.element }
        guard !changed.isEmpty else { return "恒等映射（不交换，" + "\(map.count) 声道）" }
        // 元素 = 源（输入）声道，下标 = 目标（输出）声道 ⇒ 写成 "输入 → 输出"
        return changed.map {
            "CH\(ChannelSwapPlan.channelNumber(forAPIIndex: Int($0.element)))-I → "
                + "CH\(ChannelSwapPlan.channelNumber(forAPIIndex: $0.offset))-O"
        }.joined(separator: "、")
    }
}
