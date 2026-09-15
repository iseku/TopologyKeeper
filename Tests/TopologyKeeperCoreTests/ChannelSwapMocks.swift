import CoreAudio
import Foundation
import TopologyKeeperCore

// 声道交换引擎的测试替身（对应 TestFixtures / EngineMocks 的地位）。
//
// 设计要点：状态机与回退逻辑是**纯时间+状态**驱动，因此这里用
// 可编程的设备解析 + 可编程的音频驱动 + 可编程的延迟执行，
// 就能完整测出"何时重试、何时放弃、何时告警"，无需任何音频硬件。

// MARK: - 可编程的设备解析

final class MockSwapResolver: ChannelSwapDeviceResolving, @unchecked Sendable {

    /// 当前"系统里"有哪些设备
    var devices: [ChannelSwapDeviceInfo] = []
    /// 系统默认输出设备的 UID
    var defaultOutputUID: String?
    /// 设为非 nil 则 `setNominalSampleRate` 返回该错误码
    var sampleRateSetStatus: OSStatus = noErr
    /// 记录调用（断言"只写输入设备"用）
    private(set) var setSampleRateCalls: [(rate: Double, deviceUID: String)] = []
    /// 让解析结果可编程失败
    var resolveByUID: [String: ChannelSwapDeviceInfo] = [:]

    init() {}

    func device(uid: String?, namePrefix: String) -> ChannelSwapDeviceInfo? {
        if let uid, !uid.isEmpty {
            if let d = resolveByUID[uid] { return d }
            return devices.first { $0.uid == uid }
        }
        guard !namePrefix.isEmpty else { return nil }
        return devices.first { $0.name.hasPrefix(namePrefix) }
    }

    func preferredOutputDevice(excludingNamePrefix: String) -> ChannelSwapDeviceInfo? {
        // 与协议注释一致：**不**在这里过滤声道数，让 supervisor 区分
        // "找不到设备" 与 "设备声道数不足（等待重试）"
        devices
            .filter { !$0.name.hasPrefix(excludingNamePrefix) }
            .max { $0.outputChannels < $1.outputChannels }
    }

    func defaultOutputDevice() -> ChannelSwapDeviceInfo? {
        guard let uid = defaultOutputUID else { return nil }
        return devices.first { $0.uid == uid }
    }

    func setNominalSampleRate(_ rate: Double, on device: ChannelSwapDeviceInfo) -> OSStatus {
        setSampleRateCalls.append((rate, device.uid))
        return sampleRateSetStatus
    }

    /// 设备**自己声明的**声道布局。nil = 模拟"读不到"（走约定回落）。
    ///
    /// 本机实测值：低音=第 3 声道、中置=第 4 声道（L R LFE C …）——
    /// 与 `ChannelSwapPlan` 的默认约定相反，所以这里必须可编程，
    /// 否则测不出"混音目标是否真的按设备声明走"。
    var declaredIndices: CoreAudioHelpers.ChannelIndices?

    func declaredChannelIndices(of device: ChannelSwapDeviceInfo) -> CoreAudioHelpers.ChannelIndices? {
        declaredIndices
    }
}

// MARK: - 设备构造助手

func makeSwapDevice(name: String,
                    uid: String? = nil,
                    id: AudioDeviceID = 1,
                    outputChannels: Int = 8,
                    inputChannels: Int = 0,
                    rate: Double = 96000) -> ChannelSwapDeviceInfo {
    ChannelSwapDeviceInfo(id: id,
                          uid: uid ?? "\(name)-uid",
                          name: name,
                          outputChannels: outputChannels,
                          inputChannels: inputChannels,
                          nominalSampleRate: rate,
                          isBlackHole: name.hasPrefix("BlackHole"))
}

/// 本机的标准拓扑：BlackHole 16ch + 27C3A Pro 8ch（默认输出）
func standardSwapTopology(blackHoleRate: Double = 96000,
                          outputChannels: Int = 8,
                          outputRate: Double = 96000) -> MockSwapResolver {
    let r = MockSwapResolver()
    let bh = makeSwapDevice(name: "BlackHole 16ch", uid: "BlackHole16ch_UID", id: 110,
                            outputChannels: 16, inputChannels: 16, rate: blackHoleRate)
    let tv = makeSwapDevice(name: "27C3A Pro", uid: "00000000-0000-0000-0000",
                            id: 142, outputChannels: outputChannels, rate: outputRate)
    r.devices = [tv, bh]
    r.defaultOutputUID = tv.uid
    r.resolveByUID = [bh.uid: bh, tv.uid: tv]
    return r
}

// MARK: - 可编程的音频驱动

final class MockSwapAudio: ChannelSwapAudioDriving, @unchecked Sendable {

    /// 设为非 nil 则 `start` 抛该错误
    var startError: Error?
    /// 记录每次 start 的参数（断言映射/设备/单元选择用）
    private(set) var startCalls: [(plan: ChannelSwapPlan,
                                   input: String,
                                   output: String,
                                   outputIsDefault: Bool,
                                   channelMap: [Int32])] = []
    /// 记录每次 start 收到的 LFE 混音计划（断言"混音有没有真的传到驱动"）
    private(set) var startMixCalls: [LfeMixPlan.Resolved?] = []
    private(set) var stopCount = 0
    private(set) var startCount = 0
    var statsValue = ChannelSwapAudioStats()

    func start(plan: ChannelSwapPlan,
               input: ChannelSwapDeviceInfo,
               output: ChannelSwapDeviceInfo,
               outputIsSystemDefault: Bool,
               mix: LfeMixPlan.Resolved?) throws -> [Int32] {
        startCount += 1
        if let startError { throw startError }
        guard let map = plan.swapMap else {
            throw NSError(domain: "MockSwapAudio", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "计划不可用"])
        }
        startCalls.append((plan, input.uid, output.uid, outputIsSystemDefault, map))
        startMixCalls.append(mix)
        return map
    }

    func stop() { stopCount += 1 }

    func stats() -> ChannelSwapAudioStats { statsValue }
}

// MARK: - 可编程的延迟执行（假时钟）
//
// 与 RuleEngineTests 里的做法一致：记录"被安排的任务"，由测试手动推进，
// 从而精确断言回退序列是 1-2-4-8 秒。

final class FakeScheduler: @unchecked Sendable {
    struct Pending { let delayMs: Int; let work: @Sendable () -> Void }

    private(set) var pending: [Pending] = []
    /// 累计被请求的延迟（断言用）
    private(set) var requestedDelays: [Int] = []

    /// 作为 DelayedExecutor 使用
    func executor() -> DelayedExecutor {
        { [weak self] delayMs, work in
            guard let self else { return }
            // 同步记录，避免测试与执行线程竞争
            self.mutex.lock()
            self.pending.append(Pending(delayMs: delayMs, work: work))
            self.requestedDelays.append(delayMs)
            self.mutex.unlock()
        }
    }

    private let mutex = NSLock()

    /// 执行并清空当前所有挂起任务（模拟"时间到了"）
    func fireAll() {
        mutex.lock()
        let work = pending.map(\.work)
        pending.removeAll()
        mutex.unlock()
        for w in work { w() }
    }

    /// 只执行最早的 n 个
    func fire(count: Int) {
        mutex.lock()
        let take = Array(pending.prefix(count))
        pending.removeFirst(min(count, pending.count))
        mutex.unlock()
        for p in take { p.work() }
    }

    var pendingCount: Int {
        mutex.lock(); defer { mutex.unlock() }
        return pending.count
    }
}
