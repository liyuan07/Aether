import SharedSupport
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
    @AppStorage("customTimerDuration", store: AppEnvironment.appDefaults) private var customTimerDuration: Double = 600
    @State private var expandedPresetID: UUID?
    @State private var showingResetConfirmation = false

    var body: some View {
        SettingsContent("计时与护眼", subtitle: "选择默认时长，设置工作与休息的节奏。") {
            SettingsForm {
                timerSettingsCard
                eyeCareSettingsCard
            }
        }
    }

    private var eyeCareSettingsCard: some View {
        SettingsGroup {
            HStack(spacing: 8) {
                Text("每工作")
                EyeCareIntervalPicker(title: "工作时长", value: $eyeCareWorkDuration,
                                      range: EyeCareManager.workDurationRange, step: 300, minutes: true)
                    .disabled(!eyeCareEnabled)
                Text("休息")
                EyeCareIntervalPicker(title: "休息时长", value: $eyeCareRestDuration,
                                      range: EyeCareManager.restDurationRange, step: 10, minutes: false)
                    .disabled(!eyeCareEnabled)
                Spacer(minLength: 8)
                Toggle("启用护眼提醒", isOn: $eyeCareEnabled).labelsHidden().toggleStyle(.switch)
            }.frame(minHeight: SettingsLayout.rowHeight)
        } header: { Text("护眼提醒") }
        footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("手动开始，不在应用启动时自动计时；时长修改从下一阶段生效。")
                DisclosureGroup("了解 20-20-20 护眼提醒") {
                    Text("休息时请看向约 6 米外；本功能不能替代专业检查。若持续眼痛或明显视物模糊，请咨询眼科医生或视光专业人士。")
                        .fixedSize(horizontal: false, vertical: true).padding(.vertical, 6)
                }
            }
        }
    }

    private var timerSettingsCard: some View {
        SettingsGroup("倒计时") {
            SettingsRow("默认倒计时") {
                HStack(spacing: 8) {
                    CompactDurationPicker(title: "时", value: customHours, range: 0...23)
                    CompactDurationPicker(title: "分", value: customMinutes, range: 0...59)
                    CompactDurationPicker(title: "秒", value: customSeconds, range: 0...59)
                }
            }
            SettingsToggleRow("同步 macOS“时钟”", isOn: $mirrorSystemTimer)
                .help("同时显示在系统“时钟”App 中启动的计时器。")
            presetsCard
        }
    }

    private var presetsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("常用预设").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).padding(.top, 12)
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

private struct CompactDurationPicker: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var body: some View {
        HStack(spacing: 4) {
            Picker(title, selection: $value) {
                ForEach(Array(range), id: \.self) { number in
                    Text(String(format: "%02d", number)).tag(number)
                }
            }.labelsHidden().frame(width: 64)
            Text(title).foregroundStyle(.secondary)
        }
    }
}

private struct EyeCareIntervalPicker: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let minutes: Bool
    var body: some View {
        Picker(title, selection: $value) {
            ForEach(SettingsDurationOptions.values(in: range, step: step, current: value), id: \.self) { duration in
                Text(label(duration)).tag(duration)
            }
        }.labelsHidden().frame(width: 98)
    }
    private func label(_ duration: Double) -> String {
        if minutes && duration.truncatingRemainder(dividingBy: 60) == 0 {
            return "\(Int(duration / 60)) 分钟"
        }
        return duration.formatted(.number.precision(.fractionLength(0...2))) + " 秒"
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
                .frame(minHeight: SettingsLayout.rowHeight)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(spacing: 6) {
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
                        CompactDurationPicker(title: "时", value: hours, range: 0...23)
                        CompactDurationPicker(title: "分", value: minutes, range: 0...59)
                        CompactDurationPicker(title: "秒", value: seconds, range: 0...59)
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
                .padding(.vertical, 12)
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
