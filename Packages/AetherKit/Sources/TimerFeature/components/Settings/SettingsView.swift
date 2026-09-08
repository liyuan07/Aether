/*
 * package counter
 * Derived from Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import AppKit
import Defaults
import SwiftUI

struct SettingsView: View {
    @Default(.mirrorSystemTimer) private var mirrorSystemTimer
    @Default(.timerPresets) private var timerPresets
    @Default(.eyeCareEnabled) private var eyeCareEnabled
    @Default(.eyeCareWorkDuration) private var eyeCareWorkDuration
    @Default(.eyeCareRestDuration) private var eyeCareRestDuration
    @AppStorage("customTimerDuration") private var customTimerDuration: Double = 600
    @State private var expandedPresetID: UUID?
    @State private var showingResetConfirmation = false

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                timerSettingsCard
                eyeCareSettingsCard
                presetsCard
            }
            .padding(14)
        }
        .scrollIndicators(.automatic)
        .frame(minWidth: 500, minHeight: 400)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var eyeCareSettingsCard: some View {
        SettingsCard(title: "护眼提醒", systemImage: "eye") {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("启用 20-20-20 护眼循环")
                        .font(.body.weight(.medium))
                    Text("手动开始，不会在应用启动时自动计时")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                Toggle("", isOn: $eyeCareEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            if eyeCareEnabled {
                Divider()

                HStack(spacing: 10) {
                    EyeCareDurationStepper(
                        title: "工作时长",
                        valueText: "\(Int(eyeCareWorkDuration / 60)) 分钟",
                        value: $eyeCareWorkDuration,
                        range: EyeCareManager.workDurationRange,
                        step: 5 * 60
                    )

                    EyeCareDurationStepper(
                        title: "休息时长",
                        valueText: "\(Int(eyeCareRestDuration)) 秒",
                        value: $eyeCareRestDuration,
                        range: EyeCareManager.restDurationRange,
                        step: 10
                    )
                }

                Text("修改从下一阶段生效。休息时请看向约 6 米外；本功能不能替代专业检查。若持续眼痛或明显视物模糊，请咨询眼科医生或视光专业人士。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var timerSettingsCard: some View {
        SettingsCard(title: "常规", systemImage: "gearshape") {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("同步 macOS“时钟”计时器")
                        .font(.body.weight(.medium))
                    Text("显示在系统“时钟”App 中启动的计时器")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                Toggle("", isOn: $mirrorSystemTimer)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("默认自定义倒计时")
                            .font(.body.weight(.medium))
                        Text("从操作面板新建倒计时时使用")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text(customDurationDisplay)
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    CompactDurationStepper(title: "小时", value: customHours, range: 0...23)
                    CompactDurationStepper(title: "分钟", value: customMinutes, range: 0...59)
                    CompactDurationStepper(title: "秒", value: customSeconds, range: 0...59)
                }
            }
        }
    }

    private var presetsCard: some View {
        SettingsCard(title: "倒计时预设", systemImage: "list.bullet.rectangle") {
            if timerPresets.isEmpty {
                ContentUnavailableView(
                    "暂无预设",
                    systemImage: "timer",
                    description: Text("添加一个常用倒计时时长")
                )
                .frame(maxWidth: .infinity, minHeight: 84)
            } else {
                VStack(spacing: 0) {
                    ForEach($timerPresets) { $preset in
                        let presetID = preset.id
                        TimerPresetDisclosureRow(
                            preset: $preset,
                            isExpanded: expandedPresetID == presetID,
                            isFirst: timerPresets.first?.id == presetID,
                            isLast: timerPresets.last?.id == presetID,
                            toggleExpanded: { togglePreset(presetID) },
                            moveUp: { movePreset(presetID, offset: -1) },
                            moveDown: { movePreset(presetID, offset: 1) },
                            remove: { removePreset(presetID) }
                        )

                        if presetID != timerPresets.last?.id {
                            Divider()
                                .padding(.leading, 32)
                        }
                    }
                }
            }

            Divider()

            HStack(spacing: 10) {
                Button("添加预设", systemImage: "plus", action: addPreset)

                Spacer()

                Button("恢复默认", systemImage: "arrow.counterclockwise") {
                    showingResetConfirmation = true
                }
                .confirmationDialog(
                    "恢复默认倒计时预设？",
                    isPresented: $showingResetConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("恢复", role: .destructive) {
                        expandedPresetID = nil
                        timerPresets = TimerPreset.defaultPresets
                    }
                    Button("取消", role: .cancel) {}
                }
            }
        }
    }

    private var customDurationDisplay: String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = customTimerDuration >= 3600
            ? [.hour, .minute, .second]
            : [.minute, .second]
        formatter.zeroFormattingBehavior = [.pad]
        return formatter.string(from: customTimerDuration) ?? "0:00"
    }

    private var customDurationComponents: TimerPreset.DurationComponents {
        TimerPreset.components(for: customTimerDuration)
    }

    private var customHours: Binding<Int> {
        Binding(
            get: { customDurationComponents.hours },
            set: { updateCustomDuration(hours: $0) }
        )
    }

    private var customMinutes: Binding<Int> {
        Binding(
            get: { customDurationComponents.minutes },
            set: { updateCustomDuration(minutes: $0) }
        )
    }

    private var customSeconds: Binding<Int> {
        Binding(
            get: { customDurationComponents.seconds },
            set: { updateCustomDuration(seconds: $0) }
        )
    }

    private func updateCustomDuration(
        hours: Int? = nil,
        minutes: Int? = nil,
        seconds: Int? = nil
    ) {
        var components = customDurationComponents
        if let hours { components.hours = hours }
        if let minutes { components.minutes = minutes }
        if let seconds { components.seconds = seconds }
        customTimerDuration = TimerPreset.duration(from: components)
    }

    private func togglePreset(_ id: UUID) {
        withAnimation(.smooth(duration: 0.2)) {
            expandedPresetID = expandedPresetID == id ? nil : id
        }
    }

    private func addPreset() {
        let preset = TimerPreset(
            name: "预设 \(timerPresets.count + 1)",
            duration: 5 * 60,
            color: .orange
        )
        withAnimation(.smooth(duration: 0.2)) {
            timerPresets.append(preset)
            expandedPresetID = preset.id
        }
    }

    private func movePreset(_ id: UUID, offset: Int) {
        guard let source = timerPresets.firstIndex(where: { $0.id == id }) else { return }
        let destination = source + offset
        guard timerPresets.indices.contains(destination) else { return }
        withAnimation(.smooth(duration: 0.2)) {
            timerPresets.swapAt(source, destination)
        }
    }

    private func removePreset(_ id: UUID) {
        guard let index = timerPresets.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(.smooth(duration: 0.2)) {
            if expandedPresetID == id {
                expandedPresetID = nil
            }
            timerPresets.remove(at: index)
        }
    }

}

private struct SettingsCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(.primary)

            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }
}

private struct CompactDurationStepper: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        Stepper(value: $value, in: range) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(String(format: "%02d", value))
                    .font(.system(.body, design: .monospaced).weight(.medium))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: .infinity)
    }
}

private struct EyeCareDurationStepper: View {
    let title: String
    let valueText: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        Stepper(value: $value, in: range, step: step) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(valueText)
                    .font(.system(.body, design: .monospaced).weight(.medium))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: .infinity)
    }
}

private struct TimerPresetDisclosureRow: View {
    @Binding var preset: TimerPreset
    let isExpanded: Bool
    let isFirst: Bool
    let isLast: Bool
    let toggleExpanded: () -> Void
    let moveUp: () -> Void
    let moveDown: () -> Void
    let remove: () -> Void

    private var components: TimerPreset.DurationComponents {
        TimerPreset.components(for: preset.duration)
    }

    private var hours: Binding<Int> {
        Binding(get: { components.hours }, set: { updateDuration(hours: $0) })
    }

    private var minutes: Binding<Int> {
        Binding(get: { components.minutes }, set: { updateDuration(minutes: $0) })
    }

    private var seconds: Binding<Int> {
        Binding(get: { components.seconds }, set: { updateDuration(seconds: $0) })
    }

    private var color: Binding<Color> {
        Binding(get: { preset.color }, set: { preset.updateColor($0) })
    }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: toggleExpanded) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(preset.color.gradient)
                        .frame(width: 16, height: 16)

                    Text(preset.name)
                        .lineLimit(1)
                        .foregroundStyle(.primary)

                    Spacer(minLength: 8)

                    Text(preset.formattedDuration)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(spacing: 10) {
                    Divider()

                    HStack(spacing: 10) {
                        Text("名称")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 30, alignment: .leading)
                        TextField("预设名称", text: $preset.name)
                            .textFieldStyle(.roundedBorder)
                    }

                    HStack(spacing: 8) {
                        CompactDurationStepper(title: "时", value: hours, range: 0...23)
                        CompactDurationStepper(title: "分", value: minutes, range: 0...59)
                        CompactDurationStepper(title: "秒", value: seconds, range: 0...59)
                    }

                    HStack(spacing: 8) {
                        ColorPicker("颜色", selection: color, supportsOpacity: false)
                            .fixedSize()

                        Spacer()

                        Button(action: moveUp) { Image(systemName: "arrow.up") }
                            .disabled(isFirst)
                            .help("上移")
                        Button(action: moveDown) { Image(systemName: "arrow.down") }
                            .disabled(isLast)
                            .help("下移")
                        Button(role: .destructive, action: remove) {
                            Image(systemName: "trash")
                        }
                        .help("删除")
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.bottom, 10)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func updateDuration(
        hours: Int? = nil,
        minutes: Int? = nil,
        seconds: Int? = nil
    ) {
        var value = components
        if let hours { value.hours = hours }
        if let minutes { value.minutes = minutes }
        if let seconds { value.seconds = seconds }
        preset.duration = TimerPreset.duration(from: value)
    }
}
