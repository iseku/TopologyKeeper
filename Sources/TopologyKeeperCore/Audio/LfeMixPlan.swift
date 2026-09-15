import CoreAudio
import Foundation

/// LFE 混音计划 —— **纯逻辑**，不碰任何硬件，可完整单测。
///
/// ## 为什么需要这个功能
///
/// 用户的外接 eARC 音箱（TCL S45H soundbar）接在显示器的 eARC 上，
/// **没有独立低音炮**。实测（`Probe/lfe_mix_probe --sweep`）：
/// 8 条声道里有一条**完全没有声音**，而**低音内容落在这一条上时会整个丢失**。
///
/// 与"声道交换"（`ChannelSwapPlan`）的区别（**这是本功能存在的理由**）：
///
/// | | 交换 | 混音 |
/// |---|---|---|
/// | 数学本质 | **置换**（对称） | **求和**（有向） |
/// | 低音与原有内容 | **零和**：给了低音就丢原有内容 | **两者都要** |
/// | 标注错了会怎样 | 结果不变，无害 | 混到没声音的通道 → **完全失效** |
///
/// ⇒ 所以混音目标**绝不能由"中置/低音"这类语义名推导**（本轮实测的教训），
///   而必须由**配置 + 实测**决定 —— 见 `resolve(...)`。
///
/// ## 实测依据
///
/// * 用户真机听感（`Probe/lfe_mix_probe --phase4`）：
///   把"没有声音那条声道"的内容按 −10dB 混入"有声音那条"，
///   在不丢原有内容的前提下**多出了低频**，方案成立。
/// * 削顶分析（`Probe/lfe_mix_math`）：LFE 是 +10dB 校准的热信号，
///   直接相加会削顶；−10dB 增益下理论峰值 0.55，余量充足。
public struct LfeMixPlan: Equatable, Sendable {

    // MARK: - 常量

    /// 混音要求的最小声道数（与交换一致的前置条件）
    public static let minimumChannelCount = 6

    /// **默认上游声道 = CH3-I**：从 BlackHole 的第 3 条缓冲区取低音。
    ///
    /// 依据（用户在生产布局下实测，与设备自声明的 `L R LFE C` 一致）：
    /// **第 3 条声道 = LFE，且整条没有声音**（音箱没有低音炮）。
    public static let defaultInputChannel = 3

    /// **默认下游声道 = CH4-O**：衰减它，并把低音内容叠加到它上面。
    ///
    /// 依据：macOS 默认中置就是第 4 声道；用户实测该声道**有声音**。
    public static let defaultOutputChannel = 4

    /// 允许选择的上游/下游声道范围（第 3 与第 4 条）。
    ///
    /// 只开放这一对：实测它们就是 C/LFE 那两条。开放其它声道只会让配置更容易出错。
    /// ⚠️ 注意上游与下游是**两个空间**，各自从这一对里取值，**允许编号相同**。
    public static let selectableChannels = 3...4

    /// **默认增益 = −10dB**。
    ///
    /// 依据：LFE 声道的回放增益比主声道**高 10dB**（Dolby/DTS 校准惯例），
    /// 按 −10dB 混入即与主声道**等响**；实测峰值约 0.55，远离削顶
    /// （`Probe/lfe_mix_math` 的安全区扫描）。
    public static let defaultGainDB: Double = -10

    /// 增益可调范围（dB）。上界取 0dB：那已是"低音与主声道同电平"的最激进做法。
    public static let gainRangeDB: ClosedRange<Double> = -24...0

    /// dB → 线性增益
    public static func gain(fromDB db: Double) -> Float {
        Float(pow(10.0, db / 20.0))
    }

    /// 线性增益 → dB（仅用于展示）
    public static func db(fromGain gain: Float) -> Double {
        gain <= 0 ? -.infinity : 20.0 * log10(Double(gain))
    }

    // MARK: - 字段
    //
    // ⚠️ 两个字段都是**缓冲区索引（1-based）**，语义与 `ChannelSwapPlan` 一致：
    //    第 3 声道 = 中置内容所在的缓冲区，第 4 声道 = 低音内容所在的缓冲区。
    //    **不是**"设备的物理声道号" —— 二者在本机设备上并不相同
    //    （实测设备自报顺序是 L R LFE C）。
    //    我第一版把这两者混为一谈，写出了"目标 = 低音声道"这种自相矛盾的组合，
    //    被 M3c 等测试拦下。

    /// 声道总数（= 目标设备输出声道数）
    public let channelCount: Int

    /// **上游**：低音内容所在的缓冲区（BlackHole 的 plane，对外 1-based）。默认第 4 声道。
    ///
    /// 这是混音的**源**，**不跟随交换**：交换改变的是"内容落在哪条缓冲区"，
    /// 而这个索引的含义（"低音在哪"）由 resolve 的目标侧统一处理。
    public let inputChannel: Int

    /// **下游**：要衰减并叠加低音的输出声道（对外 1-based）。默认 **第 4 声道**。
    ///
    /// ## 为什么默认第 4 声道（用户实测 + macOS 惯例）
    ///
    /// 用户用 `Probe/lfe_mix_probe --layout-map` 在**生产布局**下实测回报：
    /// * 第 2 条声道 = 右声道（有声）
    /// * **第 3 条声道 = LFE（没有低音炮 → 整条无声）**
    /// * **第 4 条声道 = 中置（有声）**
    ///
    /// 与设备自己声明的顺序 `L R LFE C` **完全一致**。
    /// 而 macOS 的默认中置声道就是第 4 声道，所以"混入第 4 声道"是稳定的默认值。
    ///
    /// ## 为什么不再"跟随交换"（先前设计的修正）
    ///
    /// 先前实现过"目标跟随交换"，但那是**错的**：
    /// 跟随交换意味着"把低音加到承载低音自己的那条声道上"，
    /// 那正是把 LFE 送去本来就没有低音炮的通道 —— 等于什么都没做。
    ///
    /// 用户指出这两个功能对应**互斥的两个场景**：
    /// * 音响**支持** LFE（有低音炮），只是软件把 C/LFE 输出反了 → 用**交换**；
    /// * 音响**不支持** LFE（无低音炮）→ 用**混音**把低音搬到能出声的中置。
    ///
    /// ⇒ 既然互斥，混音就没有理由去跟随交换。目标是一个**独立的用户选择**，
    ///   默认第 4 声道，允许在第 3/第 4 声道之间切换。
    public let outputChannel: Int

    /// 线性增益（> 0）
    public let gain: Float

    public init(channelCount: Int,
                inputChannel: Int = LfeMixPlan.defaultInputChannel,
                outputChannel: Int = LfeMixPlan.defaultOutputChannel,
                gain: Float = LfeMixPlan.gain(fromDB: LfeMixPlan.defaultGainDB)) {
        self.channelCount = channelCount
        self.inputChannel = inputChannel
        self.outputChannel = outputChannel
        self.gain = gain
    }

    // MARK: - 目标解析（★ 本类型的核心）

    /// 校验并给出最终可直接使用的混音参数。
    ///
    /// ## ⚠️ 这里**刻意不接受** `swapPlan` 参数（一个已修 bug 的结构性防复发）
    ///
    /// "位置解析"（低音在哪、目标在哪）**只在 `ChannelSwapSettings.mixPlan` 一处发生**。
    /// 早先的版本在这里也接收交换计划、再解析一次位置，结果
    /// **交换被应用了两次**（`mixPlan` 里一次 + 这里一次），正好抵消，
    /// 表现为"开了混音却没有效果，且不报错" —— 又是静默失效。
    ///
    /// ⇒ 因此本方法只做**门控 + 打包**，参数里根本没有交换计划，
    ///   从结构上让"重复应用交换"这件事无法再发生。
    ///   这也是 M2b2/M3 等测试能把"目标=源即拒绝"钉住的原因。
    public func resolved() -> Resolved? {
        // 门控
        guard channelCount >= Self.minimumChannelCount else { return nil }
        guard gain > 0 else { return nil }
        guard inputChannel >= 1, inputChannel <= channelCount else { return nil }
        guard outputChannel >= 1, outputChannel <= channelCount else { return nil }
        // ⚠️ 这里**刻意不做** "input != output" 的校验：
        //    两者属于不同空间（上游 plane vs 下游输出声道），编号相同完全合法。
        //    （我先前误加过这条校验，见 Resolved 的注释。）
        return Resolved(inputChannel: inputChannel, outputChannel: outputChannel, gain: gain)
    }

    /// 解析结果（值类型，便于跨线程传递与单测）。
    ///
    /// ## ★★ 两个索引属于**两个不同的空间**（用户指出的关键区分）
    ///
    /// ```
    ///   上游（BlackHole 的缓冲区 plane）  CH3-I / CH4-I   ← 从哪条**读**
    ///   下游（真实音频设备的输出声道）    CH3-O / CH4-O   ← 往哪条**写**
    /// ```
    ///
    /// 命名约定由用户提出，用来防止把两者混为一谈。它们**可以取相同的编号**：
    /// "读 CH3-I、写 CH3-O" 是完全正常且必要的组合
    /// （例如低音在 CH3-I，而 CH3-O 正是那只有声音的喇叭）。
    ///
    /// ⚠️ 我先前在这里犯过一个概念错误：把来源与目标当成同一空间，
    /// 于是**禁止了两个声道号相同**，并据此认为"同声道会自己叠加"。
    /// 那是错的 —— 编号相同不代表同一个对象。这个错误还进一步导致了
    /// 真正的 bug：驱动用**上游索引**去决定衰减**哪条下游声道**。
    public struct Resolved: Equatable, Sendable {

        /// **上游**：从这条 plane 读低音（对外 1-based 缓冲区号）
        public let inputChannel: Int

        /// **下游**：衰减这条输出声道，并把低音内容叠加到它上面（对外 1-based）
        public let outputChannel: Int

        /// 线性增益
        public let gain: Float

        /// 上游索引（0-based）—— 渲染回调里读 plane 用
        public var inputAPIIndex: Int { ChannelSwapPlan.apiIndex(forChannel: inputChannel) }
        /// 下游索引（0-based）—— 渲染回调里写输出声道用
        public var outputAPIIndex: Int { ChannelSwapPlan.apiIndex(forChannel: outputChannel) }

        // 兼容旧命名（源码内仍有引用，语义与上面完全等价）
        public var sourceChannel: Int { inputChannel }
        public var targetChannel: Int { outputChannel }
        public var sourceAPIIndex: Int { inputAPIIndex }
        public var targetAPIIndex: Int { outputAPIIndex }

        /// 例 "CH3-I → CH4-O ×0.316"（**装配摘要**，用于日志）
        public var description: String {
            String(format: "CH%d-I → CH%d-O ×%.3f", inputChannel, outputChannel, gain)
        }

        /// 传递函数首行，例 **`CH4-O = CH4-I + CH3-I × 0.316`**。
        ///
        /// 配置页与首页状态栏的「映射」一行**共用这一份生成逻辑**。
        /// 先前状态栏显示的是 `CH3-I → CH4-O ×0.316`（装配摘要），
        /// 而配置页显示的是传递函数 —— 同一件事两种写法，用户一眼就看出不一致。
        ///
        /// 直通那条 = 配对中与输入声道不同的那一条（配对见 `selectableChannels`）。
        public var transferFunction: String {
            LfeMixPlan.transferFunctionLine(inputChannel: inputChannel,
                                            outputChannel: outputChannel,
                                            gain: gain)
        }
    }

    /// 传递函数首行的生成器（纯函数，供配置页 / 状态栏 / 测试共用）。
    ///
    /// 例：`transferFunctionLine(inputChannel: 3, outputChannel: 4, gain: 0.3162)`
    /// → `"CH4-O = CH4-I + CH3-I × 0.316"`
    ///
    /// ⚠️ 只生成**主输出声道**那一条方程。配对中另一条输出声道被切断（= 0），
    ///    由调用方按需另行说明。
    public static func transferFunctionLine(inputChannel: Int,
                                           outputChannel: Int,
                                           gain: Float) -> String {
        let pair = selectableChannels
        let direct = inputChannel == pair.lowerBound ? pair.upperBound : pair.lowerBound
        return "CH\(outputChannel)-O = CH\(direct)-I + CH\(inputChannel)-I × "
            + String(format: "%.3f", gain)
    }

    // MARK: - 可行性说明（UI 直接展示）

    /// 不可用时的原因；可用时返回 nil
    public var unavailableReason: String? {
        guard channelCount >= Self.minimumChannelCount else {
            return "目标设备 \(channelCount) 声道，少于 \(Self.minimumChannelCount) 声道 —— "
                + "不存在 CH\(inputChannel)-I 对应的输出声道，无法混音"
        }
        guard inputChannel >= 1, inputChannel <= channelCount else {
            return "输入声道 CH\(inputChannel)-I 越界（设备共 \(channelCount) 声道）"
        }
        guard outputChannel >= 1, outputChannel <= channelCount else {
            return "输出声道 CH\(outputChannel)-O 越界（设备共 \(channelCount) 声道）"
        }
        guard gain > 0 else { return "增益必须大于 0" }
        return nil
    }

    /// 人话描述，例 "第4声道 → 第3声道，-10dB（跟随交换）"
    public func description() -> String {
        guard let r = resolved() else {
            return "不可用：" + (unavailableReason ?? "参数不合法")
        }
        let db = Self.db(fromGain: r.gain)
        let dbText = db.isFinite ? String(format: "%.0fdB", db) : "-∞"
        return "CH\(r.inputChannel)-I → CH\(r.outputChannel)-O，\(dbText)"
    }
}

// MARK: - 实时回调用的传递函数（纯静态、零分配、可单测）

extension LfeMixPlan {

    /// 把一路输出样本算出来（**纯函数**，供单测钉住混音方向）。
    ///
    /// 实时回调里用的是等价的内联版本；两处必须逐样本一致（有测试比对）。
    ///
    /// ## ★ 两个索引属于**两个空间**（用户的关键纠正）
    ///
    /// * `inputChannel` / 上游：读哪条 plane（BlackHole 缓冲区）
    /// * `outputChannel` / 下游：写哪条输出声道（真实设备）
    ///
    /// 两者编号相同时**完全合法** —— "读 CH3-I、写 CH3-O" 是很常见的配置。
    /// 我先前把两者当成同一空间、还禁止了编号相同，那是错的。
    ///
    /// 传递函数（`c` = 输出声道序号，0-based）。**用户明确定义的混音语义**：
    ///
    /// ```
    ///   rateIdx（CH-I，被选中那条）= 施加 gain 衰减
    ///   directIdx（另一条上游）    = 直通，不衰减
    ///   CH-O 自己那条内容也在 directIdx 里（配对的两条互为"另一条"）
    /// ```
    ///
    /// | 配置 | CH4-O 的结果 |
    /// |---|---|
    /// | CH-I=3 | `CH4-I + CH3-I × gain` |
    /// | CH-I=4 | `CH3-I + CH4-I × gain` |
    ///
    /// `cutIdx`（配对中不是 CH-O 的那条下游声道）不连 ⇒ 静音；
    /// 其余声道（L/R、环绕）**照常直通**。
    @inline(__always)
    public static func outputSample(outputChannelIndex c: Int,
                                    contentSample: Float,
                                    rateSample: Float,
                                    directSample: Float,
                                    targetIndex: Int,
                                    cutIndex: Int,
                                    gain: Float) -> Float {
        if c == targetIndex {
            return rateSample * gain + directSample
        }
        if c == cutIndex {
            return 0
        }
        return contentSample
    }
}
