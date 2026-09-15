import CoreAudio
import Foundation

/// 设备事件监听。
///
/// 两条实测得出的硬性要求：
///
/// **1. 触发源只需要 `kAudioHardwarePropertyDevices`**
/// 实测：能力从 `[]` 变成 `[2..8]`（组合 0 → 155）时，
/// `kAudioStreamPropertyAvailablePhysicalFormats` 监听器**一次都没触发** ——
/// 因为设备是**带着全部能力被创建出来的**，不存在"活动对象能力变化"这种事件。
/// 而 `devices-list` 单次唤醒触发 **8 次**，完整覆盖每次出现/消失。
/// 所以这里**不注册**能力监听器（注册了也是浪费）。
///
/// **2. 设备重建后必须重新注册**
/// 实测 `AudioDeviceID` 每次重建都变：`142 → 177 → 207 → 222`；
/// 旧监听器随旧对象销毁，不重新注册就会**静默失效**。
/// ⚠️ 我自己的诊断程序曾漏掉这一步，导致跑出"监听器不触发"的**错误结论**。
/// 因此这条逻辑有专门的单元测试锁死。
public final class DeviceWatcher: DeviceWatching, @unchecked Sendable {

    private let service: CoreAudioServiceProtocol
    private let queue: DispatchQueue
    private let watchedUIDs: @Sendable () -> [String]
    private let debounceMs: Int
    private let executor: DelayedExecutor

    public var onEvent: (@Sendable (WatchEvent) -> Void)?

    private var systemTokens: [ListenerToken] = []
    private var armed: [String: ArmedDevice] = [:]
    private var debounceGeneration: UInt64 = 0
    private var started = false

    /// 累计 (re)arm 次数 —— 测试与诊断用
    public private(set) var rearmCount = 0

    private struct ArmedDevice {
        var deviceID: AudioDeviceID
        var streamIDs: [AudioStreamID]
        var tokens: [ListenerToken]
    }

    public init(service: CoreAudioServiceProtocol,
                queue: DispatchQueue,
                debounceMs: Int,
                executor: DelayedExecutor? = nil,
                watchedUIDs: @escaping @Sendable () -> [String]) {
        self.service = service
        self.queue = queue
        self.debounceMs = debounceMs
        self.executor = executor ?? makeQueueExecutor(queue)
        self.watchedUIDs = watchedUIDs
    }

    // MARK: - 生命周期

    public func start() {
        guard !started else { return }
        started = true
        armSystemListeners()
        rearm()
        Log.info("DeviceWatcher 已启动（\(armed.count) 个受监控设备）")
    }

    public func stop() {
        guard started else { return }
        started = false
        for token in systemTokens { service.removeListener(token) }
        systemTokens.removeAll()
        for (_, device) in armed {
            for token in device.tokens { service.removeListener(token) }
        }
        armed.removeAll()
        Log.info("DeviceWatcher 已停止")
    }

    public var armedDescription: String {
        armed.map { "\($0.key)→\($0.value.deviceID)\($0.value.streamIDs)" }
            .sorted()
            .joined(separator: ", ")
    }

    /// 当前已 armed 的设备数（测试用）
    public var armedDeviceCount: Int { armed.count }

    /// 指定 UID 当前 armed 的 AudioDeviceID（测试用）
    public func armedDeviceID(forUID uid: String) -> AudioDeviceID? {
        armed[uid]?.deviceID
    }

    // MARK: - 系统级监听（只注册一次）

    private func armSystemListeners() {
        // ★ 主触发源
        systemTokens.append(service.addListener(
            AudioObjectID(kAudioObjectSystemObject),
            CoreAudioHelpers.address(kAudioHardwarePropertyDevices),
            queue: queue) { [weak self] in self?.scheduleDevicesChanged() })

        // 音频服务重启（coreaudiod 崩溃或被重启）—— 需要重建全部监听器
        systemTokens.append(service.addListener(
            AudioObjectID(kAudioObjectSystemObject),
            CoreAudioHelpers.address(kAudioHardwarePropertyServiceRestarted),
            queue: queue) { [weak self] in
                guard let self else { return }
                Log.warn("音频服务已重启 —— 重建全部监听器")
                self.dropAllDeviceListeners()
                self.onEvent?(.systemRestarted)
                self.scheduleDevicesChanged()
            })

        // 下面两个仅用于**观测**，永不写入
        systemTokens.append(service.addListener(
            AudioObjectID(kAudioObjectSystemObject),
            CoreAudioHelpers.address(kAudioHardwarePropertyDefaultOutputDevice),
            queue: queue) { Log.debug("默认输出设备发生变化（仅观测，不干预）") })

        systemTokens.append(service.addListener(
            AudioObjectID(kAudioObjectSystemObject),
            CoreAudioHelpers.address(kAudioHardwarePropertyDefaultSystemOutputDevice),
            queue: queue) { Log.debug("默认系统输出设备发生变化（仅观测，不干预）") })
    }

    private func dropAllDeviceListeners() {
        for (_, device) in armed {
            for token in device.tokens { service.removeListener(token) }
        }
        armed.removeAll()
    }

    // MARK: - 防抖

    private func scheduleDevicesChanged() {
        debounceGeneration &+= 1
        let generation = debounceGeneration
        // 依据：实测 devices-list 会在 ~0.5s 内密集触发多次（单次唤醒共 8 次），
        // 必须合并，否则会重复评估。
        executor(debounceMs) { [weak self] in
            guard let self, self.debounceGeneration == generation else { return }
            self.handleDevicesChanged()
        }
    }

    private func handleDevicesChanged() {
        guard started else { return }

        let before = armed.mapValues { $0.deviceID }
        rearm()
        let after = armed.mapValues { $0.deviceID }

        // 出现：新解析到，或 AudioDeviceID 变了（实测唤醒中会变 2~3 次）
        for (uid, deviceID) in after where before[uid] != deviceID {
            if let previous = before[uid] {
                Log.info("设备重建：\(uid) AudioDeviceID \(previous) → \(deviceID)")
            } else {
                Log.info("设备出现：\(uid) id=\(deviceID)")
            }
            onEvent?(.deviceAppeared(uid: uid, deviceID: deviceID))
        }

        // 消失
        for uid in before.keys where after[uid] == nil {
            Log.info("设备消失：\(uid)")
            onEvent?(.deviceDisappeared(uid: uid))
        }

        onEvent?(.devicesChanged(trigger: .deviceEvent))
    }

    // MARK: - ★ 重新注册

    /// 检查所有受监控设备，按需 (re)arm。
    ///
    /// 判定条件：**未注册过**，或 `AudioDeviceID` 变了，或流集合变了。
    public func rearm() {
        let wanted = Set(watchedUIDs())

        // 不再需要的设备
        // ★ 先快照 key：循环体会 armed[uid] = nil，直接在 armed.keys 上遍历
        //   属于"迭代中修改字典"，行为未定义（与 CoreAudioService.removeAllListeners 同类问题）。
        for uid in Array(armed.keys) where !wanted.contains(uid) {
            if let device = armed[uid] {
                for token in device.tokens { service.removeListener(token) }
            }
            armed[uid] = nil
        }

        for uid in wanted {
            guard let descriptor = service.deviceDescriptor(forUID: uid) else {
                // 设备当前不在。若之前 armed 过，说明它消失了 —— 清掉登记。
                if armed[uid] != nil {
                    for token in armed[uid]!.tokens { service.removeListener(token) }
                    armed[uid] = nil
                }
                continue
            }

            let streamIDs = service.outputStreams(of: descriptor.id)
            if let existing = armed[uid],
               existing.deviceID == descriptor.id,
               existing.streamIDs == streamIDs {
                continue                      // 无变化，无需重注册
            }

            armDevice(uid: uid, deviceID: descriptor.id, streamIDs: streamIDs)
        }
    }

    private func armDevice(uid: String, deviceID: AudioDeviceID, streamIDs: [AudioStreamID]) {
        // 先摘掉旧监听器（设备已重建时它们是死的，但显式移除更干净）
        if let previous = armed[uid] {
            for token in previous.tokens { service.removeListener(token) }
        }

        rearmCount += 1
        var tokens: [ListenerToken] = []

        Log.info("RE-ARM device/stream listeners → uid=\(uid) deviceID=\(deviceID) "
                 + "streams=\(streamIDs)")

        // 就地变更监听：这些在"活动对象被就地改动"时确实会触发（实测）
        tokens.append(service.addListener(deviceID,
            CoreAudioHelpers.address(kAudioDevicePropertyNominalSampleRate),
            queue: queue) { [weak self] in
                self?.onEvent?(.nominalRateChanged(uid: uid, deviceID: deviceID))
            })

        tokens.append(service.addListener(deviceID,
            CoreAudioHelpers.address(kAudioDevicePropertyDeviceIsAlive),
            queue: queue) { [weak self] in
                self?.scheduleDevicesChanged()      // 存活状态变化常常伴随重建
            })

        // 流集合本身变化 → 需要重新枚举并 (re)arm
        tokens.append(service.addListener(deviceID,
            CoreAudioHelpers.address(kAudioDevicePropertyStreams,
                                     scope: kAudioObjectPropertyScopeOutput),
            queue: queue) { [weak self] in
                self?.scheduleDevicesChanged()
            })

        for streamID in streamIDs {
            tokens.append(service.addListener(streamID,
                CoreAudioHelpers.address(kAudioStreamPropertyPhysicalFormat),
                queue: queue) { [weak self] in
                    self?.onEvent?(.physicalFormatChanged(uid: uid, streamID: streamID))
                })
            tokens.append(service.addListener(streamID,
                CoreAudioHelpers.address(kAudioStreamPropertyVirtualFormat),
                queue: queue) { [weak self] in
                    self?.onEvent?(.physicalFormatChanged(uid: uid, streamID: streamID))
                })
        }

        armed[uid] = ArmedDevice(deviceID: deviceID, streamIDs: streamIDs, tokens: tokens)
    }

    // MARK: - 供引擎主动查询

    /// 当前解析到的设备 ID（不重新注册）
    public func resolveDeviceID(uid: String) -> AudioDeviceID? {
        armed[uid]?.deviceID ?? service.deviceDescriptor(forUID: uid)?.id
    }
}
