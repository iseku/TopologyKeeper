import Foundation

/// 配置持久化。
///
/// 沿用原设计的 `UserDefaults` + `Codable`，但改了 key
/// （原方案写的 `com.yourname.audiolock.config` 是占位符）。
public final class ConfigStore: @unchecked Sendable {

    public static let defaultKey = "com.iseku.topologykeeper.config"

    private let lock = NSLock()
    private let defaults: UserDefaults
    private let key: String
    private var cached: AppConfig

    /// 配置变更回调（在调用 `update` 的线程上同步触发）
    private var observers: [@Sendable (AppConfig) -> Void] = []

    public init(defaults: UserDefaults = .standard,
                key: String = ConfigStore.defaultKey) {
        self.defaults = defaults
        self.key = key
        self.cached = Self.load(from: defaults, key: key)
    }

    // MARK: - 读

    public var config: AppConfig {
        lock.lock(); defer { lock.unlock() }
        return cached
    }

    // MARK: - 写

    /// 原子地修改配置并持久化
    public func update(_ body: (inout AppConfig) -> Void) {
        lock.lock()
        body(&cached)
        let snapshot = cached
        let observers = self.observers
        lock.unlock()

        persist(snapshot)
        for observer in observers { observer(snapshot) }
    }

    /// ★ **从 UserDefaults 重新加载**（外部进程改了配置后调用）。
    ///
    /// 为什么需要它：`tkctl mix/swap` 直接写 UserDefaults，
    /// 而 App 只在**启动时**读一次配置并缓存在 `cached` 里 ——
    /// 外部改了配置，App 完全不知道，会继续用旧值跑。
    /// 现象极具迷惑性："CLI 显示改了、App 行为没变"，
    /// 本会话为此绕了很久。（GUI 改配置走 `update`，所以它一直是好的。）
    ///
    /// 语义：重新读盘；若内容确实变了，通知 observers。
    @discardableResult
    public func reloadFromDefaults() -> Bool {
        let fresh = Self.load(from: defaults, key: key)
        lock.lock()
        let changed = (fresh != cached)
        if changed { cached = fresh }
        let observers = self.observers
        lock.unlock()
        if changed { for observer in observers { observer(fresh) } }
        return changed
    }

    /// 外部进程改配置后广播的通知名（`tkctl` 发、App 收）
    public static let externalChangeNotification = Notification.Name("com.iseku.topologykeeper.configChangedExternally")

    public func addObserver(_ observer: @escaping @Sendable (AppConfig) -> Void) {
        lock.lock(); defer { lock.unlock() }
        observers.append(observer)
    }

    // MARK: - 规则操作

    public func addRule(_ rule: DeviceRule) {
        update { $0.rules.append(rule) }
    }

    public func removeRule(id: UUID) {
        update { $0.rules.removeAll { $0.id == id } }
    }

    public func replaceRule(_ rule: DeviceRule) {
        update { config in
            if let index = config.rules.firstIndex(where: { $0.id == rule.id }) {
                config.rules[index] = rule
            }
        }
    }

    public func setRuleEnabled(_ id: UUID, _ enabled: Bool) {
        update { config in
            if let index = config.rules.firstIndex(where: { $0.id == id }) {
                config.rules[index].isEnabled = enabled
            }
        }
    }

    public func rule(forUID uid: String) -> DeviceRule? {
        config.rules.first { $0.deviceUID == uid }
    }

    /// 记录运行时诊断信息（不回写 UI 触发，避免循环）
    public func recordRuntime(ruleID: UUID, lastAppliedAt: Date?, lastError: String?, failures: Int) {
        lock.lock()
        if let index = cached.rules.firstIndex(where: { $0.id == ruleID }) {
            if let lastAppliedAt { cached.rules[index].lastAppliedAt = lastAppliedAt }
            cached.rules[index].lastError = lastError
            cached.rules[index].consecutiveFailures = failures
        }
        let snapshot = cached
        lock.unlock()
        persist(snapshot)      // 注意：不通知 observers，避免与 UI 形成回环
    }

    // MARK: - 持久化

    private func persist(_ config: AppConfig) {
        do {
            let data = try JSONEncoder().encode(config)
            defaults.set(data, forKey: key)
        } catch {
            Log.error("配置保存失败：\(error)")
        }
    }

    private static func load(from defaults: UserDefaults, key: String) -> AppConfig {
        guard let data = defaults.data(forKey: key) else {
            Log.info("未找到已有配置，使用默认配置")
            return AppConfig()
        }
        do {
            return try JSONDecoder().decode(AppConfig.self, from: data)
        } catch {
            // AppConfig 的 init(from:) 是宽松解码，走到这里说明结构完全不可读。
            // 不覆盖用户数据，只是本次以默认值启动。
            Log.error("配置解析失败（将使用默认配置，原数据保留）：\(error)")
            return AppConfig()
        }
    }

    /// 清除配置（调试用）
    public func reset() {
        lock.lock()
        cached = AppConfig()
        let snapshot = cached
        lock.unlock()
        persist(snapshot)
    }
}
