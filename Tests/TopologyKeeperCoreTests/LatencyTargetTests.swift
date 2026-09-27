// ⚠️ 用 `import AppKit` 而不是 `import Foundation`：本机只有 CommandLineTools，
// 其 `_Testing_Foundation.framework` 只有二进制、没有 swiftmodule，
// `import Foundation` 与 `import Testing` 并存必然报错（详见 LogLevelTests 顶部说明）。
// AppKit 传递性带来 Foundation 的 `JSONDecoder` / `Data`。
import AppKit
import Testing

@testable import TopologyKeeperCore

/// **延迟目标**（用户要求新增的可调项）的解析与钳制测试。
///
/// ## 为什么这些断言重要
///
/// 用户要求：延迟尽量压低，并给一个滑块让使用者按场景调整、上下限提前定好（10…50ms）。
///
/// 但**实际可达下限受音频设备 IO 缓冲限制**：水位至少要装得下 2 个输出回调，
/// 否则每次回调都贴着欠载边缘。本机 512 帧回调 ⇒ 实际最低约 32ms。
/// 因此这里有三条必须锁住的不变量：
/// 1. 请求低于物理下限时**钳到下限**（绝不生成过小的水位 → 不引入周期性卡顿）；
/// 2. 请求在下限之上时**如实兑现**（稳态延迟 ≈ 请求值）；
/// 3. 引擎必须能报出"实际最低值"，UI 才能显示"设不到那么低" ——
///    否则就是本项目最忌讳的"显示的与跑的不是一回事"。
struct LatencyTargetTests {

    private func resolve(_ requestedMs: Double,
                         callbackFrames: Int = 512,
                         rate: Double = 48000)
        -> (target: Int, deadband: Int, minAchievableMs: Double) {
        ChannelSwapAudioDriver.resolveLatencyTarget(sampleRate: rate,
                                                    requestedMs: requestedMs,
                                                    callbackFrames: callbackFrames)
    }

    @Test("本机参数（48kHz / 512 帧回调）：安全水位 = 2×512 = 1024 帧 ⇒ 实际最低 ≈ 21.3ms")
    func minAchievableOnThisMachine() {
        let r = resolve(10)
        #expect(r.target == 1024, "低于安全水位的请求被钳到 1024")
        #expect(r.deadband == 512)
        // ★ 可达的**平均**延迟基准是目标水位（21.3ms），不是"目标 + 死区"（32ms）：
        //   死区只决定上沿多久丢一次，水位并不会停在那里 —— 真机实测 21ms 证实。
        #expect(abs(r.minAchievableMs - 21.3) < 0.5, "实际 \(r.minAchievableMs)ms")
    }

    @Test("把设备缓冲改成 256 帧 ⇒ 实际最低降到 ≈ 10.7ms（这正是用户想要的 11ms）")
    func twoFiftySixFrameBufferHitsElevenMs() {
        let r = resolve(10, callbackFrames: 256)
        #expect(r.target == 512, "安全水位 = 2×256")
        #expect(abs(r.minAchievableMs - 10.67) < 0.5, "实际 \(r.minAchievableMs)ms")
    }

    @Test("请求在下限之上时如实兑现：目标水位**直接**对应请求的延迟")
    func requestAboveFloorIsHonored() {
        // ⚠️ 这里曾经是"稳态 ≈ 目标 + 死区"、而目标是"请求 − 死区"，
        //   两次偏移互相抵消不了，真机上表现为"设 30ms 实际 13~21ms"。
        //   现在目标水位就是请求值本身（死区只决定上沿多久丢一次）。
        for requested in [32.0, 40.0, 50.0] {
            let r = resolve(requested)
            let targetMs = Double(r.target) / 48000 * 1000
            #expect(abs(targetMs - requested) < 1.0,
                    "请求 \(requested)ms 的目标水位应等于该值，实际 \(targetMs)ms")
        }
    }

    @Test("256 帧缓冲 + 把滑块拖到最低 ⇒ 目标水位落到 512 帧（这才是 11ms 的兑现方式）")
    func lowTargetPlusSmallBufferHitsFloor() {
        let r = resolve(10, callbackFrames: 256)
        #expect(r.target == 512, "目标水位 = max(请求 480 帧, 安全水位 2×256=512)")
        #expect(abs(Double(r.target) / 48000 * 1000 - 10.67) < 0.5)
    }

    @Test("滑块范围内的上下限被钳制（不会出现 1ms 或 999ms 这种请求）")
    func requestOutOfRangeIsClamped() {
        #expect(resolve(1).target == resolve(ChannelSwapSettings.latencyRangeMs.lowerBound).target)
        #expect(resolve(999).target == resolve(ChannelSwapSettings.latencyRangeMs.upperBound).target)
    }

    @Test("设备回调更小（256 帧）时可以压到更低：最低 ≈ 18.7ms")
    func smallerCallbackAllowsLowerLatency() {
        let r = resolve(10, callbackFrames: 256)
        // 死区 = max(256, 8ms=384) = 384；安全水位 = 512
        #expect(r.deadband == 384)
        #expect(r.target == 512)
        #expect(r.minAchievableMs < 20, "实际 \(r.minAchievableMs)ms")
    }

    @Test("死区永远不小于一个回调（否则丢弃会被抖动碎片化）")
    func deadbandNeverBelowOneCallback() {
        for callback in [64, 128, 256, 512, 1024] {
            let r = resolve(30, callbackFrames: callback)
            #expect(r.deadband >= callback, "回调 \(callback) 时死区 \(r.deadband)")
            #expect(r.target >= 2 * callback, "回调 \(callback) 时安全水位 \(r.target)")
        }
    }

    // MARK: - 配置层

    /// 老配置（没有该键）必须回落默认值 —— 否则升级后整份配置读取失败或行为突变。
    @Test("老配置缺少延迟目标键 → 默认 30ms（不改变既有行为）")
    func decodeMigratesWithoutKey() throws {
        let json = #"{"isEnabled":true,"mixEnabled":false}"#
        let s = try JSONDecoder().decode(ChannelSwapSettings.self, from: Data(json.utf8))
        #expect(s.targetLatencyMs == ChannelSwapSettings.defaultTargetLatencyMs)
        #expect(s.targetLatencyMs == 30.0)
    }

    @Test("往返编解码保留延迟目标")
    func roundTripKeepsTarget() throws {
        var s = ChannelSwapSettings()
        s.targetLatencyMs = 22
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(ChannelSwapSettings.self, from: data)
        #expect(back.targetLatencyMs == 22)
    }

    @Test("描述文案：请求值低于设备下限时必须明说")
    func descriptionShowsDeviceFloor() {
        var s = ChannelSwapSettings()
        s.targetLatencyMs = 10
        #expect(s.latencyDescription(minAchievableMs: 32).contains("设备最低"))
        // 请求值已在下限之上 → 不必啰嗦
        s.targetLatencyMs = 40
        #expect(!s.latencyDescription(minAchievableMs: 32).contains("设备最低"))
        // 还没有诊断数据（未装配）→ 只显示请求值
        #expect(s.latencyDescription(minAchievableMs: nil) == "40ms")
        #expect(s.latencyDescription(minAchievableMs: 0) == "40ms")
    }

    // MARK: 峰值毫秒的口径

    @Test("峰值毫秒必须与瞬时水位无关（真机：水位低时面板显示「峰值 0ms」）")
    func peakMillisecondsIsIndependentOfInstantFill() {
        // 真机现场（2026-09-26）：水位漂到 287 帧时面板显示"水位峰值 0ms"，
        // 而真实峰值是 6480 帧（135ms）—— 丢旧/对齐/微调三个计数一个都没清零，
        // 就是"峰值帧数仍在、只是被算成了 0"的证据。
        // 根因：文案借道**瞬时**水位做比例换算，而瞬时水位在一个回调内会掉到 0
        // （刚读完、输入还没写进来），那一刻 `fillFrames > 0` 不成立 ⇒ 兜成 0ms。
        // ⇒ 口径必须是「峰值帧数 ÷ 采样率」，与采集瞬间的水位无关。
        let text = ChannelSwapFillText.maintenance(
            sampleRate: 48000,
            peakFillFrames: 6480,
            droppedStaleFrames: 10860,
            startupAlignedFrames: 2560,
            starvedFrames: 0,
            resyncCount: 0,
            targetFillFrames: 512,
            lowerTrimmedFrames: 404,
            maxOutputGapMs: 123,
            maxInputGapMs: 0,
            maxInputFrames: 256)
        #expect(text.contains("水位峰值 135ms"), "实际文案：\(text)")
        // 异常项按约定追加（正常态不显示，免得把诊断行变成噪声）
        #expect(text.contains("下沿微调 404 帧"), "实际文案：\(text)")
        #expect(text.contains("输出间隔峰值 123ms"), "实际文案：\(text)")
        // 输入块恰好等于名义值（目标 ÷ 2 = 256）⇒ 不该报"输入最大块"
        #expect(!text.contains("输入最大块"), "实际文案：\(text)")
    }
}
