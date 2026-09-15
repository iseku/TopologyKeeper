import AppKit
import SwiftUI
import TopologyKeeperCore

/// 添加 / 编辑规则。
struct RuleEditorView: View {

    @ObservedObject var state: AppState
    /// nil = 新增
    let existingRule: DeviceRule?

    @Environment(\.dismiss) private var dismiss

    @State private var selectedUID: String = ""
    @State private var selection = FormatSelection(channelCount: 2, bitDepth: 24, sampleRate: 48000)
    @State private var conflictPolicy: ConflictPolicy = .enforceAlways
    /// 新增规则**默认不启用**：先让用户确认配置无误，再手动开启。
    /// 编辑时由 `load()` 覆盖成规则的实际值。
    @State private var isEnabled: Bool = false
    @State private var capability: DeviceCapability = .empty
    @State private var devices: [DeviceDescriptor] = []
    @State private var loadError: String?

    private var isEditing: Bool { existingRule != nil }

    private var selectedDevice: DeviceDescriptor? {
        devices.first { $0.uid == selectedUID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isEditing ? "编辑锁定规则" : "添加锁定规则")
                .font(.system(size: 14, weight: .semibold))

            // 设备选择
            VStack(alignment: .leading, spacing: 4) {
                Text("设备").font(.system(size: 11)).foregroundStyle(.secondary)
                if isEditing {
                    // 编辑时不允许改设备（改设备等于换一条规则）
                    Text(existingRule?.deviceName ?? "")
                        .font(.system(size: 12))
                    Text("UID: \(existingRule?.deviceUID ?? "")")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                } else if devices.isEmpty {
                    Text("所有输出设备都已有锁定规则。\n同一设备只能有一条规则，如需更改请直接编辑现有规则。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Picker("", selection: $selectedUID) {
                        Text("请选择…").tag("")
                        ForEach(devices, id: \.uid) { device in
                            Text(device.displayName).tag(device.uid)
                        }
                    }
                    .labelsHidden()
                    Text("已有锁定规则的设备不再列出 —— 同一设备只能有一条规则。")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            Divider()

            // 格式选择（级联）
            VStack(alignment: .leading, spacing: 6) {
                Text("目标格式").font(.system(size: 11, weight: .semibold))
                FormatCascadePicker(capability: capability, selection: $selection)

                if let device = selectedDevice {
                    let current = currentFormatText(of: device)
                    Text("设备当前格式：\(current)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            // 冲突策略
            VStack(alignment: .leading, spacing: 4) {
                Text("冲突策略").font(.system(size: 11, weight: .semibold))
                ForEach(ConflictPolicy.selectable, id: \.self) { policy in
                    VStack(alignment: .leading, spacing: 1) {
                        RadioButton(policy: policy,
                                    isSelected: conflictPolicy == policy) {
                            conflictPolicy = policy
                        }
                        Text(policy.explanation)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 18)
                    }
                }
            }

            // 两种模式都显示 —— 新增时默认关闭，让用户确认后再启用
            Toggle("启用该规则", isOn: $isEnabled)
                .font(.system(size: 12))

            if let loadError {
                Text(loadError)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }

            Divider()

            HStack {
                if isEditing {
                    Button("删除规则", role: .destructive) {
                        if let rule = existingRule {
                            state.removeRule(rule.id)
                        }
                        dismiss()
                    }
                }
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isEditing ? "保存" : "添加") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(18)
        .frame(width: 520)
        .onAppear(perform: load)
    }

    private var canSave: Bool {
        guard !selectedUID.isEmpty, !capability.isEmpty else { return false }
        return selection.isValid(against: capability)
    }

    // MARK: - 加载

    private func load() {
        // ★ 新增时排除"已有锁定规则的设备"—— 同一设备只能有一条规则。
        //   两条目标不同的规则会互相争夺同一台设备（本项目最怕的静默失效）。
        //   判据用 `DeviceRule.matches`（UID 优先、名称+传输兜底），
        //   与引擎判定"是否同一台设备"的口径**保持一致**：
        //   只按 UID 去重会漏掉 HDMI/DP 换端口后 UID 变化的情况，于是又能加出第二条。
        devices = isEditing
            ? state.listOutputDevices()
            : state.listOutputDevices().filter { device in
                !state.snapshots.contains { snapshot in
                    state.ruleForEditing(snapshot.ruleID)?.matches(device) ?? false
                }
            }

        if let rule = existingRule {
            selectedUID = rule.deviceUID
            selection = FormatSelection.from(rule.preset)
            // 「暂停」已从界面移除，旧配置在此迁移成「未启用 + 持续锁定」：
            // 保留用户可观察到的语义（这条规则不动作），但换用保留下来的机制。
            if rule.conflictPolicy == .paused {
                conflictPolicy = .enforceAlways
                isEnabled = false
            } else {
                conflictPolicy = rule.conflictPolicy
                isEnabled = rule.isEnabled
            }
        } else if let first = devices.first {
            selectedUID = first.uid
            isEnabled = false              // 新增默认不启用
        }
        reloadCapability(pinningToExistingPreset: existingRule?.preset)
    }

    private func reloadCapability(pinningToExistingPreset preset: AudioFormatPreset?) {
        guard !selectedUID.isEmpty else {
            capability = .empty
            return
        }
        capability = state.capability(forUID: selectedUID)

        if capability.isEmpty {
            loadError = selectedDevice == nil
                ? "设备未连接，无法读取能力清单。"
                : "读不到该设备的格式清单。"
            return
        }
        loadError = nil

        if let preset = preset {
            // 编辑已有规则：确保选择落在合法集合内
            selection = FormatSelection.from(preset)
            selection.normalize(pinningChanged: .channels, against: capability)
        } else if let preferred = FormatSelection.preferred(from: capability) {
            // 新增规则：默认选最大声道数 + 24bit + 96000（本工具的核心场景）
            selection = preferred
        }
    }

    private func currentFormatText(of device: DeviceDescriptor) -> String {
        // 编辑已有规则时优先用快照（含"未连接"等状态语义）；
        // 新增规则时快照还不存在，直接读设备当前格式。
        if let ruleID = existingRule?.id,
           let snapshot = state.snapshots.first(where: { $0.ruleID == ruleID }) {
            return snapshot.currentFormatText
        }
        return state.currentFormat(forUID: device.uid)?.displayString ?? "读取失败"
    }

    // MARK: - 保存

    private func save() {
        // ★ 保存前必须做存在性校验
        guard let preset = capability.preset(for: selection) else {
            loadError = "该组合在当前设备能力清单中不存在，无法保存。"
            return
        }
        let device = selectedDevice

        if var rule = existingRule {
            rule.preset = preset
            rule.conflictPolicy = conflictPolicy
            rule.isEnabled = isEnabled
            state.saveRule(rule)
        } else {
            let rule = DeviceRule(isEnabled: isEnabled,
                                  deviceUID: selectedUID,
                                  deviceName: device?.name ?? selectedUID,
                                  transportType: device?.transportType ?? 0,
                                  preset: preset,
                                  conflictPolicy: conflictPolicy)
            state.saveRule(rule)
        }
        dismiss()
    }
}

/// 简易单选按钮（避免 Picker 在 radio 形态下的样式问题）
private struct RadioButton: View {
    let policy: ConflictPolicy
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                Text(policy.displayText)
                    .font(.system(size: 12))
            }
        }
        .buttonStyle(.plain)
    }
}
