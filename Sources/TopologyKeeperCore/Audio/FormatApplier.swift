import CoreAudio
import Foundation

/// 把目标格式写入设备，并**强制回读校验**。
///
/// 这是整个项目的心脏，把实测学到的三条纪律全部编码进去：
///
/// 1. **能力门控**：目标组合不在能力清单里就返回 `.capabilityNotReady`，
///    **不尝试写入**。唤醒后设备会先只提供 `[2ch]`，此时写入必然失败。
/// 2. **照抄条目**：从清单取原始 `AudioStreamRangedDescription`，
///    **只覆盖 `mSampleRate`**，绝不自己重算 `mBytesPerFrame`
///    —— 本设备 20/24bit 是 32bit 容器，重算会静默落到错误格式（模式 B）。
/// 3. **回读校验**：`OSStatus == noErr` **不是成功依据**。
///    实测两种静默失败都返回 noErr（模式 A/B）。
public struct FormatApplier: Sendable {

    private let service: CoreAudioServiceProtocol

    public init(service: CoreAudioServiceProtocol) {
        self.service = service
    }

    /// 应用格式。
    /// - Note: 必须在 `audioQueue` 上调用。
    public func apply(_ preset: AudioFormatPreset, to device: AudioDeviceID) -> ApplyOutcome {
        let streams = service.outputStreams(of: device)
        guard !streams.isEmpty else {
            return .noOutputStreams
        }

        // ── 步骤 0：写入前快照 ────────────────────────────────────
        // 用于最后区分「模式 A：完全没变」与「模式 B：变了但不对」。
        let before = service.currentPhysicalFormat(of: streams[0])

        // ── 步骤 1：能力门控 + 照抄条目 ──────────────────────────
        //
        // ★ 要求**所有**输出流都支持目标组合，而不是"第一个支持的流"。
        //   多输出流设备（USB 音频接口常见）必须整体一致：
        //   只改其中一条流会留下半套格式，比不改更糟。
        var target: AudioStreamBasicDescription?
        for stream in streams {
            let entries = service.availableFormats(of: stream)
            guard let entry = entries.first(where: { candidate in
                candidate.mFormat.mChannelsPerFrame == preset.channelCount
                    && candidate.mFormat.mBitsPerChannel == preset.bitDepth
                    && AudioFormatPreset.ratesEqual(candidate.mFormat.mSampleRate,
                                                    preset.sampleRate)
            }) else {
                let capability = service.capability(of: device)
                Log.info("能力门控：目标 \(preset.compactString) 尚不可用"
                         + "（\(capability.summary)），等待设备就绪")
                return .capabilityNotReady(availableMaxChannels: capability.maxChannelCount)
            }
            if target == nil {
                // ★ 原样照抄，绝不重算字节数
                target = entry.mFormat
            }
        }
        guard let asbd = target else { return .noOutputStreams }

        // ── 步骤 2：写入所有输出流 ─────────────────────────────────
        // 多流设备必须全部设置，否则可能出现半套格式。
        var worstStatus: OSStatus = noErr
        for stream in streams {
            let status = service.setPhysicalFormat(asbd, on: stream)
            if status != noErr { worstStatus = status }
        }
        if worstStatus != noErr {
            Log.error("写入 physicalFormat 失败：\(CoreAudioHelpers.describe(worstStatus))")
            return .osStatus(worstStatus)
        }

        // ── 步骤 3：★ 回读校验 ───────────────────────────────────
        //   校验**所有**输出流：任何一条流没到位都不能算成功。
        var allStreamsMatched = true
        var after: AudioStreamBasicDescription?
        for stream in streams {
            guard let back = service.currentPhysicalFormat(of: stream) else {
                return .osStatus(kAudioHardwareBadObjectError)
            }
            if after == nil { after = back }
            if !preset.matchesCurrent(back) { allStreamsMatched = false }
        }
        guard let after else { return .osStatus(kAudioHardwareBadObjectError) }

        Log.info("写入 physicalFormat → noErr；回读 \(CoreAudioHelpers.describe(after))"
                 + (streams.count > 1 ? "（共 \(streams.count) 条输出流，全部匹配=\(allStreamsMatched)）" : ""))

        if allStreamsMatched && preset.matchesCurrent(after) {
            if !preset.containerMatches(after) {
                // 不算失败：设备可能合法地报告不同容器表示。但值得记下来，
                // 因为它也可能是「模式 B」的早期信号。
                Log.warn("容器/标志与写入值不一致：期望 bpf=\(preset.bytesPerFrame) "
                         + "flags=\(CoreAudioHelpers.formatFlagsString(preset.formatFlags))，"
                         + "实际 bpf=\(after.mBytesPerFrame) "
                         + "flags=\(CoreAudioHelpers.formatFlagsString(after.mFormatFlags))")
            }
            return .applied
        }

        // ── 步骤 4：声道/位深对了但采样率没跟上 ──────────────────
        if after.mChannelsPerFrame == preset.channelCount,
           after.mBitsPerChannel == preset.bitDepth,
           !AudioFormatPreset.ratesEqual(after.mSampleRate, preset.sampleRate) {

            Log.info("声道/位深已生效，采样率未跟随"
                     + "（\(AudioFormatPreset.rateString(after.mSampleRate))Hz）；"
                     + "补设标称采样率 \(AudioFormatPreset.rateString(preset.sampleRate))Hz")
            let status = service.setNominalSampleRate(preset.sampleRate, on: device)
            if status != noErr {
                Log.error("补设标称采样率失败：\(CoreAudioHelpers.describe(status))")
            }
            var retryAllMatched = true
            var retry: AudioStreamBasicDescription?
            for stream in streams {
                guard let back = service.currentPhysicalFormat(of: stream) else {
                    return .osStatus(kAudioHardwareBadObjectError)
                }
                if retry == nil { retry = back }
                if !preset.matchesCurrent(back) { retryAllMatched = false }
            }
            guard let retry else { return .osStatus(kAudioHardwareBadObjectError) }
            if retryAllMatched {
                return .applied
            }
            return .sampleRateNotApplied(wanted: preset.sampleRate, got: retry.mSampleRate)
        }

        // ── 步骤 5：区分模式 A（没变）与模式 B（变了但不对）─────────
        if let before, sameTriple(before, after) {
            // 完全没变 —— 典型是设备被其它工具独占（实测 SoundSource 会导致此现象）
            Log.error("写入被接受（noErr）但格式毫无变化 —— 模式 A，"
                      + "设备可能被其它应用独占")
            return .notEffective(before: before, after: after)
        }

        // 变了但不是目标 —— 典型是我们自己的 ASBD 构造有问题
        Log.error("写入被接受（noErr）但落到了另一个格式 —— 模式 B，"
                  + "检查 ASBD 构造（是否自己重算了 mBytesPerFrame？）")
        return .wrongFormat(wanted: asbd, got: after)
    }

    /// 三元组是否相同（用于判断"是否发生了任何变化"）
    private func sameTriple(_ a: AudioStreamBasicDescription,
                            _ b: AudioStreamBasicDescription) -> Bool {
        a.mChannelsPerFrame == b.mChannelsPerFrame
            && a.mBitsPerChannel == b.mBitsPerChannel
            && AudioFormatPreset.ratesEqual(a.mSampleRate, b.mSampleRate)
    }
}
