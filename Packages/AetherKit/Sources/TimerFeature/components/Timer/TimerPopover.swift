import SharedSupport
/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import SwiftUI
import Defaults

#if canImport(AppKit)
import AppKit

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
#endif

struct TimerPopover: View {
    @ObservedObject var timerManager = TimerManager.shared
    @ObservedObject private var eyeCareManager = EyeCareManager.shared
    @Default(.timerPresets) private var timerPresets
    @Default(.showRealtimeClock) private var showRealtimeClock
    @Default(.eyeCareEnabled) private var eyeCareEnabled
    @AppStorage("customTimerDuration", store: AppEnvironment.appDefaults) private var customTimerDuration: Double = 600
    @State private var customHours: Int = 0
    @State private var customMinutes: Int = 10
    @State private var customSeconds: Int = 0

    private var customDurationInSeconds: TimeInterval {
        TimeInterval(customHours * 3600 + customMinutes * 60 + customSeconds)
    }

    var body: some View {
        VStack(spacing: 12) {
            HeaderView(statusText: statusText)

            if timerManager.isTimerActive {
                ActiveTimerSection(timerManager: timerManager)
            } else {
                CustomTimerSection(hours: $customHours, minutes: $customMinutes, seconds: $customSeconds, startAction: startCustomTimer)
                    .onChange(of: customHours) { _, _ in updateStoredCustomDuration() }
                    .onChange(of: customMinutes) { _, _ in updateStoredCustomDuration() }
                    .onChange(of: customSeconds) { _, _ in updateStoredCustomDuration() }
            }

            if eyeCareEnabled {
                EyeCareStatusCard(manager: eyeCareManager)
            }

            Divider()

            DisclosureGroup("常用预设（\(timerPresets.count)）") {
                PresetList(presets: timerPresets, activePresetId: timerManager.activePresetId, startAction: startPreset)
                    .animation(.smooth, value: timerManager.activePresetId)
                    .padding(.top, 6)
            }

            Divider()

            HStack {
                Text("刘海实时时间")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("刘海实时时间", isOn: $showRealtimeClock)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            syncCustomDuration(with: customTimerDuration)
        }
        .onChange(of: customTimerDuration) { _, newValue in
            syncCustomDuration(with: newValue)
        }
    }

    private var statusText: String {
        if timerManager.isOvertime {
            return "超时"
        } else if timerManager.isPaused {
            return "已暂停"
        } else if timerManager.isTimerActive {
            return "运行中"
        } else {
            return "待开始"
        }
    }

    private func syncCustomDuration(with value: Double) {
        let components = TimerPreset.components(for: value)
        customHours = components.hours
        customMinutes = components.minutes
        customSeconds = components.seconds
    }

    private func updateStoredCustomDuration() {
        let newValue = customDurationInSeconds
        customTimerDuration = newValue
    }

    private func startCustomTimer() {
        let duration = customDurationInSeconds
        guard duration > 0 else { return }
        withAnimation(.smooth) {
            timerManager.startTimer(duration: duration, name: "自定义倒计时")
        }
    }

    private func startPreset(_ preset: TimerPreset) {
        withAnimation(.smooth) {
            timerManager.startTimer(duration: preset.duration, name: preset.name, preset: preset)
        }
    }
}

private struct EyeCareStatusCard: View {
    @ObservedObject var manager: EyeCareManager

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "eye.fill")
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                Text("20-20-20 护眼")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                stateBadge
            }

            stateContent

            if let message = manager.message {
                Text(message)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Color.primary.opacity(0.1).frame(height: 0.5) }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var stateContent: some View {
        switch manager.state {
        case .stopped:
            Text(ruleSummary)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: start) {
                Label("开始护眼循环", systemImage: "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

        case .working:
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("本轮工作剩余")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(EyeCareManager.formattedDuration(manager.remainingTime(at: manager.displayDate)))
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .contentTransition(.numericText())
                }
                Spacer()
                compactControls(primaryTitle: "暂停", primaryIcon: "pause.fill") {
                    manager.pause()
                }
            }

        case let .paused(_, remaining, reason):
            VStack(alignment: .leading, spacing: 7) {
                Text(pauseDescription(reason))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(EyeCareManager.formattedDuration(remaining))
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                compactControls(primaryTitle: "继续", primaryIcon: "play.fill", primaryAction: resume)
            }

        case .resting:
            EmptyView()

        case .awaitingCompletion:
            compactControls(
                primaryTitle: "开始下一轮",
                primaryIcon: "play.fill",
                stopTitle: "停止"
            ) {
                _ = manager.completeRest()
            }
        }
    }

    @ViewBuilder
    private var stateBadge: some View {
        Text(badgeText)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(badgeColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(badgeColor.opacity(0.14), in: Capsule())
    }

    private func compactControls(
        primaryTitle: String,
        primaryIcon: String,
        stopTitle: String = "结束",
        primaryAction: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 6) {
            Button(action: primaryAction) {
                Label(primaryTitle, systemImage: primaryIcon)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button(role: .destructive, action: manager.stop) {
                Label(stopTitle, systemImage: "stop.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .font(.system(size: 11, weight: .medium))
    }

    private var ruleSummary: String {
        let workMinutes = Int(manager.workDuration / 60)
        let restSeconds = Int(manager.restDuration)
        return "工作 \(workMinutes) 分钟后，看向约 6 米外休息 \(restSeconds) 秒"
    }

    private var badgeText: String {
        switch manager.state {
        case .stopped: return "未开始"
        case .working: return "工作中"
        case .resting: return "休息中"
        case .awaitingCompletion: return "待确认"
        case .paused: return "已暂停"
        }
    }

    private var badgeColor: Color {
        switch manager.state {
        case .working: return .green
        case .resting, .awaitingCompletion: return .orange
        case .stopped, .paused: return .secondary
        }
    }

    private func pauseDescription(_ reason: EyeCarePauseReason) -> String {
        switch reason {
        case .user:
            return "护眼循环已暂停，需要手动继续"
        case .timerConflict:
            return "另一项倒计时正在使用，护眼循环已暂停"
        case .away:
            return "离开屏幕期间已暂停"
        }
    }

    private func start() {
        _ = manager.start()
    }

    private func resume() {
        _ = manager.resume()
    }
}

private struct HeaderView: View {
    let statusText: String

    var body: some View {
        HStack {
            Text("倒计时")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Text(statusText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}

private struct ActiveTimerSection: View {
    @ObservedObject var timerManager: TimerManager
    @Default(.timerShowsProgress) private var showsProgress
    @Default(.timerProgressStyle) private var progressStyle
    @Default(.timerIconColorMode) private var colorMode
    @Default(.timerSolidColor) private var solidColor
    @Default(.timerPresets) private var timerPresets

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 4) {
                Text(timerManager.timerName)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                    .help(timerManager.timerName)

                Text(timerManager.formattedRemainingTime())
                    .font(.system(size: 36, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(timerManager.isOvertime ? Color.red : Color.primary)
                    .contentTransition(.numericText())
            }

            if showsProgress && progressStyle == .bar {
                ProgressView(value: min(timerManager.progress, 1.0))
                    .progressViewStyle(LinearProgressViewStyle(tint: progressTint))
                    .animation(.smooth(duration: 0.2), value: timerManager.progress)
            }

            HStack(spacing: 8) {
                if !timerManager.isOvertime {
                    Button(action: togglePause) {
                        Label(timerManager.isPaused ? "继续" : "暂停", systemImage: timerManager.isPaused ? "play.fill" : "pause.fill")
                            .font(.system(size: 12, weight: .medium))
                            .labelStyle(.titleAndIcon)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!timerManager.allowsManualInteraction)
                }

                Button(role: .destructive, action: stopTimer) {
                    Label("停止", systemImage: "stop.fill")
                        .font(.system(size: 12, weight: .medium))
                        .labelStyle(.titleAndIcon)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!timerManager.allowsManualInteraction)
            }
            .controlSize(.regular)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .animation(.smooth, value: timerManager.isPaused)
    }

    private func togglePause() {
        guard timerManager.allowsManualInteraction else { return }
        withAnimation(.smooth) {
            if timerManager.isPaused {
                timerManager.resumeTimer()
            } else {
                timerManager.pauseTimer()
            }
        }
    }

    private func stopTimer() {
        guard timerManager.allowsManualInteraction else {
            timerManager.endExternalTimer(triggerSmoothClose: false)
            return
        }
        withAnimation(.smooth) {
            timerManager.stopTimer()
        }
    }

    private var progressTint: Color {
        switch colorMode {
        case .adaptive:
            return activePresetColor ?? timerManager.timerColor
        case .solid:
            return solidColor
        }
    }

    private var activePresetColor: Color? {
        guard let presetId = timerManager.activePresetId else { return nil }
        return timerPresets.first { $0.id == presetId }?.color
    }
}

private struct CustomTimerSection: View {
    @Binding var hours: Int
    @Binding var minutes: Int
    @Binding var seconds: Int
    let startAction: () -> Void

    private var totalSeconds: Int {
        hours * 3600 + minutes * 60 + seconds
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                DurationStepper(title: "小时", value: $hours, range: 0...23)
                DurationStepper(title: "分钟", value: $minutes, range: 0...59)
                DurationStepper(title: "秒", value: $seconds, range: 0...59)
            }

            Button(action: startAction) {
                Label("开始倒计时", systemImage: "play.fill")
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(totalSeconds == 0)
        }
        .padding(.vertical, 4)
    }
}

private struct DurationStepper: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        Stepper(value: $value, in: range) {
            VStack(alignment: .leading, spacing: 3) {
                Text(String(format: "%02d", value))
                    .font(.system(size: 26, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .fixedSize()
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 60, maxWidth: .infinity)
        .accessibilityLabel(title)
        .accessibilityValue("\(value)")
    }
}

private struct PresetList: View {
    private static let maximumVisiblePresets = 5
    private static let presetRowHeight: CGFloat = 34
    private static let rowSpacing: CGFloat = 2

    let presets: [TimerPreset]
    let activePresetId: UUID?
    let startAction: (TimerPreset) -> Void

    private var fiveRowHeight: CGFloat {
        Self.presetRowHeight * CGFloat(Self.maximumVisiblePresets)
            + Self.rowSpacing * CGFloat(Self.maximumVisiblePresets - 1)
            + 8
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("预设")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            if presets.isEmpty {
                Text("在设置中添加常用预设")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if presets.count <= Self.maximumVisiblePresets {
                presetRows
            } else {
                ScrollView {
                    presetRows
                }
                .frame(height: fiveRowHeight)
                .scrollIndicators(.visible)
            }
        }
    }

    private var presetRows: some View {
        VStack(spacing: Self.rowSpacing) {
            ForEach(presets) { preset in
                TimerPresetRow(preset: preset, isActive: activePresetId == preset.id) {
                    startAction(preset)
                }
                .frame(height: Self.presetRowHeight)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct TimerPresetRow: View {
    let preset: TimerPreset
    let isActive: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle()
                    .fill(preset.color)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)

                Text(preset.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(preset.formattedDuration)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize()

                Image(systemName: isActive ? "checkmark" : "play.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isActive ? preset.color : Color.secondary)
                    .frame(width: 12)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isActive ? preset.color.opacity(0.1) : Color.secondary.opacity(isHovering ? 0.07 : 0))
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("开始\(preset.name) · \(preset.formattedDuration)")
        .accessibilityLabel("开始\(preset.name)，\(preset.formattedDuration)")
        .accessibilityValue(isActive ? "当前预设" : "")
    }
}

#Preview {
    TimerPopover()
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color.black)
}
