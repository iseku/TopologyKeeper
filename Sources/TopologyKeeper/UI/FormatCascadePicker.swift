import AppKit
import SwiftUI
import TopologyKeeperCore

/// 级联格式选择器。
///
/// **不是三个独立下拉框**，而是设备能力清单的投影（《详细设计.md》§10.5）：
/// * 一级：可用声道数
/// * 二级：依所选声道过滤后的位深
/// * 三级：依所选声道+位深过滤后的采样率
///
/// 边界情况（都有实测依据）：
/// * 27C3A Pro：21 种组合，注意 **768000 只有 `2ch/16bit` 支持**
/// * Sculptor (DP)：只有 2ch → 声道下拉需置灰
/// * BlackHole 16ch：**唯一组合** → 声道与位深都置灰
struct FormatCascadePicker: View {

    let capability: DeviceCapability
    @Binding var selection: FormatSelection

    private var channelOptions: [UInt32] { capability.allChannelCounts }
    private var bitDepthOptions: [UInt32] { selection.availableBitDepths(in: capability) }
    private var sampleRateOptions: [Double] { selection.availableSampleRates(in: capability) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if capability.isEmpty {
                // 不加符号：橙色文字本身已经表达了"这里有问题"（全项目输出一律纯文本）
                Text("设备未连接或读不到能力清单，无法选择格式。")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            } else {
                HStack(alignment: .top, spacing: 14) {
                    dimension(label: "声道",
                              options: channelOptions,
                              value: selection.channelCount,
                              display: { "\($0)ch" },
                              isLocked: channelOptions.count <= 1) { newValue in
                        selection.channelCount = newValue
                        selection.normalize(pinningChanged: .channels, against: capability)
                    }

                    dimension(label: "位深",
                              options: bitDepthOptions,
                              value: selection.bitDepth,
                              display: { "\($0)bit" },
                              isLocked: bitDepthOptions.count <= 1) { newValue in
                        selection.bitDepth = newValue
                        selection.normalize(pinningChanged: .bitDepth, against: capability)
                    }

                    dimension(label: "采样率",
                              options: sampleRateOptions,
                              value: selection.sampleRate,
                              display: { "\(AudioFormatPreset.rateString($0))Hz" },
                              isLocked: sampleRateOptions.count <= 1) { newValue in
                        selection.sampleRate = newValue
                        selection.normalize(pinningChanged: .sampleRate, against: capability)
                    }
                }

                HStack(spacing: 6) {
                    Image(systemName: selection.isValid(against: capability)
                          ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(selection.isValid(against: capability) ? .green : .orange)
                    Text(validationText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                if hasLockedDimension {
                    Text("该设备在此维度上只有唯一可选值（已置灰）。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var hasLockedDimension: Bool {
        channelOptions.count <= 1 || bitDepthOptions.count <= 1
    }

    private var validationText: String {
        let count = capability.combinationCount
        if selection.isValid(against: capability) {
            return "合法组合（设备共 \(count) 个可用组合）"
        }
        return "该组合在当前设备能力清单中不存在"
    }

    /// 单维度下拉。只有唯一值时置灰并加说明。
    @ViewBuilder
    private func dimension<T: Hashable & Comparable>(
        label: String,
        options: [T],
        value: T,
        display: @escaping (T) -> String,
        isLocked: Bool,
        onChange: @escaping (T) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Picker("", selection: Binding(
                get: { value },
                set: { onChange($0) })) {
                ForEach(options, id: \.self) { option in
                    Text(display(option)).tag(option)
                }
            }
            .labelsHidden()
            .frame(minWidth: 92)
            .disabled(isLocked || options.isEmpty)
        }
    }
}
