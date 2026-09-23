// ⚠️ 用 `import AppKit` 而不是 `import Foundation`（原因见 LogLevelTests 顶部说明：
// CommandLineTools 的 `_Testing_Foundation` 只有二进制没有 swiftmodule）。
import AppKit
import Testing

@testable import TopologyKeeperCore

/// **音频缓冲**（`kAudioDevicePropertyBufferFrameSize`）的决策与配置测试。
///
/// ## 为什么单独测这一组
///
/// 缓冲帧数是**延迟的绝对下限杠杆**：稳态延迟下限 = `2 × 缓冲 ÷ 采样率`
/// （水位至少要装下两个输出回调）。48kHz/512 帧 ⇒ 21.3ms；**256 帧 ⇒ 10.7ms**。
/// 但它是**全局设备属性**（BlackHole 还是系统默认输出）⇒ 决策必须精确：
/// 该写的写、**不该写的绝不写**、不支持时必须能说出原因（不能静默忽略）。
///
/// 真实设备的支持范围千奇百怪，光靠真机试不过来 ⇒ 决策抽成纯函数在这里锁死。
struct BufferFramesTests {

    @Test("跟随系统（nil）→ 不写设备属性")
    func followSystemWritesNothing() {
        #expect(ChannelSwapSettings.resolveBufferFrames(
            preferred: nil, current: 512, supported: 32...4096) == nil)
    }

    @Test("设备已是目标值 → 不打扰设备")
    func alreadyAtTargetWritesNothing() {
        #expect(ChannelSwapSettings.resolveBufferFrames(
            preferred: 256, current: 256, supported: 32...4096) == nil)
    }

    @Test("设备支持范围不含目标值 → 不写（调用方会把原因说出来）")
    func unsupportedRangeWritesNothing() {
        #expect(ChannelSwapSettings.resolveBufferFrames(
            preferred: 256, current: 512, supported: 512...4096) == nil)
    }

    @Test("正常情形：写目标值；读不到支持范围时不阻拦（失败由 OSStatus 报出）")
    func writesTarget() {
        #expect(ChannelSwapSettings.resolveBufferFrames(
            preferred: 256, current: 512, supported: 32...4096) == 256)
        #expect(ChannelSwapSettings.resolveBufferFrames(
            preferred: 256, current: 512, supported: nil) == 256)
        // 读不到当前值（设备属性暂时不可读）也应尝试写入
        #expect(ChannelSwapSettings.resolveBufferFrames(
            preferred: 256, current: nil, supported: 32...4096) == 256)
    }

    @Test("非法目标值（0 / 负数）绝不写入")
    func rejectsNonPositive() {
        #expect(ChannelSwapSettings.resolveBufferFrames(
            preferred: 0, current: 512, supported: nil) == nil)
        #expect(ChannelSwapSettings.resolveBufferFrames(
            preferred: -256, current: 512, supported: nil) == nil)
    }

    // MARK: - 配置层

    @Test("老配置缺少缓冲键 → 跟随系统（不改变既有行为）")
    func decodeMigratesWithoutKey() throws {
        let json = #"{"isEnabled":true,"mixEnabled":false}"#
        let s = try JSONDecoder().decode(ChannelSwapSettings.self, from: Data(json.utf8))
        #expect(s.preferredBufferFrames == nil)
    }

    @Test("键存在但为 null → 跟随系统（用户显式选的那个选项）")
    func nullMeansFollowSystem() throws {
        let json = #"{"preferredBufferFrames":null}"#
        let s = try JSONDecoder().decode(ChannelSwapSettings.self, from: Data(json.utf8))
        #expect(s.preferredBufferFrames == nil)
    }

    @Test("往返编解码保留缓冲档位")
    func roundTripKeepsChoice() throws {
        var s = ChannelSwapSettings()
        s.preferredBufferFrames = 256
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(ChannelSwapSettings.self, from: data)
        #expect(back.preferredBufferFrames == 256)
    }

    @Test("描述文案：跟随系统 / 指定帧数")
    func descriptionText() {
        var s = ChannelSwapSettings()
        #expect(s.bufferFramesDescription == "跟随系统")
        s.preferredBufferFrames = 256
        #expect(s.bufferFramesDescription.contains("256"))
    }

    @Test("可选档位含 256（用户要的 11ms 就靠它）")
    func optionsIncludeTwoFiftySix() {
        #expect(ChannelSwapSettings.bufferFrameOptions.contains(256))
        #expect(ChannelSwapSettings.bufferFrameOptions.allSatisfy { $0 > 0 })
    }
}
