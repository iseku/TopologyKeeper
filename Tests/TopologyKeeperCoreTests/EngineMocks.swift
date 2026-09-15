import CoreAudio
import Foundation
@testable import TopologyKeeperCore

// MARK: - 引擎依赖的测试替身

/// 可编程触发的 DeviceWatcher 替身
final class MockDeviceWatcher: DeviceWatching, @unchecked Sendable {
    var onEvent: (@Sendable (WatchEvent) -> Void)?

    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var rearmCount = 0
    private(set) var lastArmedDescription = "(未启动)"

    func start() { startCount += 1 }
    func stop() { stopCount += 1 }
    func rearm() { rearmCount += 1 }

    var armedDescription: String { lastArmedDescription }

    /// 测试主动投递事件
    func emit(_ event: WatchEvent) {
        onEvent?(event)
    }
}

/// 可编程的睡眠/唤醒替身
final class MockSleepWakeObserver: SleepWakeObserving, @unchecked Sendable {
    var onSleep: (@Sendable () -> Void)?
    var onWake: (@Sendable () -> Void)?

    private let flag = MockFlag()
    var isSleeping: Bool { flag.value }

    private(set) var startCount = 0

    func start() { startCount += 1 }
    func stop() {}

    /// 测试驱动：进入睡眠
    func simulateSleep() {
        flag.value = true
        onSleep?()
    }

    /// 测试驱动：唤醒
    func simulateWake() {
        flag.value = false
        onWake?()
    }
}

private final class MockFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}

// MARK: - 可变配置持有者（跨闭包共享）

final class ConfigHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: AppConfig

    init(_ config: AppConfig) { self.storage = config }

    var value: AppConfig {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }

    func mutate(_ body: (inout AppConfig) -> Void) {
        lock.lock(); body(&storage); lock.unlock()
    }
}

// MARK: - 线程安全可变值盒子

final class ValueBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T

    init(_ value: T) { storage = value }

    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}

// MARK: - 线程安全收集器

/// 用于从 `@Sendable` 闭包里收集事件/调用记录。
final class Collector<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [T] = []

    func append(_ value: T) {
        lock.lock(); storage.append(value); lock.unlock()
    }

    var values: [T] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    var count: Int { values.count }
    func contains(where predicate: (T) -> Bool) -> Bool { values.contains(where: predicate) }
}

// MARK: - 可控时钟

/// 可手动推进的时钟 —— 让"抑制窗口 / 退避"这类时间相关逻辑
/// 能在测试里被精确验证，而不必真的 sleep。
final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.current = start
    }

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func advance(ms: Int) {
        lock.lock()
        current = current.addingTimeInterval(Double(ms) / 1000)
        lock.unlock()
    }
}

// MARK: - 组装好的引擎测试场景

/// 把引擎的全部依赖按测试需要组装好，避免每个用例重复样板。
final class EngineHarness: @unchecked Sendable {

    let queue = DispatchQueue(label: "test.audio.queue")
    let service = MockCoreAudioService()
    let watcher = MockDeviceWatcher()
    let sleepWake = MockSleepWakeObserver()
    let config: ConfigHolder
    let clock: FakeClock
    let policy: ApplyPolicy
    let engine: RuleEngine

    private(set) var snapshots: [RuleSnapshot] = []

    init(config initial: AppConfig = AppConfig(),
         clock: FakeClock = FakeClock(),
         enablePolling: Bool = false) {
        self.config = ConfigHolder(initial)
        self.clock = clock

        let configHolder = self.config
        self.policy = ApplyPolicy(config: { configHolder.value },
                                  now: { [clock] in clock.now })

        let configForEngine = self.config
        self.engine = RuleEngine(
            service: service,
            watcher: watcher,
            sleepWake: sleepWake,
            policy: policy,
            config: { configForEngine.value },
            queue: queue,
            pollExecutor: enablePolling ? makeQueueExecutor(queue) : nil)

        engine.onSnapshots = { [weak self] snapshots in
            self?.snapshots = snapshots
        }
    }

    func start() {
        queue.sync { engine.start() }
    }

    /// 在引擎队列上同步执行一段操作
    func onQueue<T>(_ body: () -> T) -> T {
        queue.sync { body() }
    }

    /// 触发一个事件并等待引擎处理完
    func emit(_ event: WatchEvent) {
        queue.sync { watcher.emit(event) }
    }

    /// 同步读取快照
    func snapshot(for rule: DeviceRule) -> RuleSnapshot? {
        onQueue { snapshots.first { $0.ruleID == rule.id } }
    }

    /// 便捷：当前唯一规则的快照
    var firstSnapshot: RuleSnapshot? {
        onQueue { snapshots.first }
    }

    var writeAttempts: Int { onQueue { engine.writeAttemptCount } }

    // MARK: 场景搭建

    /// 配一台设备 + 一条规则（预设 8ch/24bit/96000）
    @discardableResult
    func setupStandardDevice(currentFormat: AudioStreamBasicDescription? = nil,
                             capability: DeviceCapability? = nil,
                             uid: String = "TEST-UID",
                             deviceID: AudioDeviceID = 100,
                             streamID: AudioStreamID = 200,
                             policy conflictPolicy: ConflictPolicy = .enforceAlways) -> DeviceRule {
        let capability = capability ?? makeHDMICapability()
        let current = currentFormat
            ?? makeASBD(channels: 2, bits: 24, rate: 192000, bytesPerChannel: 4)

        service.configure(uid: uid, deviceID: deviceID, streamID: streamID,
                          capability: capability, current: current)

        let entry = capability.entry(channels: 8, bitDepth: 24, sampleRate: 96000)!
        let preset = AudioFormatPreset(verbatim: entry, sampleRate: 96000)
        let rule = DeviceRule(deviceUID: uid,
                              deviceName: "Test Device",
                              transportType: kAudioDeviceTransportTypeHDMI,
                              preset: preset,
                              conflictPolicy: conflictPolicy)
        config.mutate { $0.rules = [rule] }
        return rule
    }

    /// 把设备能力降级为"只有 2ch"（模拟唤醒早期的实测状态）
    func degradeCapabilityTo2chOnly(deviceID: AudioDeviceID = 100,
                                   streamID: AudioStreamID = 200) {
        let entries: [AudioStreamRangedDescription] = [16, 20, 24].flatMap { bits -> [AudioStreamRangedDescription] in
            let bitsValue = UInt32(bits)
            let container: UInt32 = bitsValue == 16 ? 2 : 4
            return [32000, 44100, 48000, 88200, 96000, 176400, 192000].map { rate in
                makeRanged(makeASBD(channels: 2, bits: bitsValue,
                                    rate: Double(rate), bytesPerChannel: container))
            }
        }
        service.availableFormatsByStream[streamID] = entries
    }
}
