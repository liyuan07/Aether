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

struct EyeCareLiveActivity: View {
    @EnvironmentObject private var vm: DynamicIslandViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var manager = EyeCareManager.shared

    @State private var showTransientLabel = false
    @State private var labelHideTask: DispatchWorkItem?

    @Default(.enableMinimalisticUI) private var enableMinimalisticUI
    @Default(.showRealtimeClock) private var showRealtimeClock

    private let transientLabelDuration: TimeInterval = 4
    private let transientTitle = "护眼"
    private let activityTitle = "20-20-20 护眼"

    private var notchContentHeight: CGFloat {
        max(0, vm.effectiveClosedNotchHeight - 12)
    }

    private var iconWidth: CGFloat {
        max(0, notchContentHeight)
    }

    private var leftWingWidth: CGFloat {
        if showRealtimeClock {
            return RealtimeClockText.displayWidth + 12
        }

        var width = iconWidth
            + CompactNotchLiveActivityMetrics.leadingInset
            + CompactNotchLiveActivityMetrics.iconTrailingAllowance
        if showTransientLabel {
            width += CompactNotchLiveActivityMetrics.contentSpacing + labelWidth
        }
        return width
    }

    private var rightWingWidth: CGFloat {
        (showRealtimeClock ? 8 : CompactNotchLiveActivityMetrics.trailingInset)
            + (showRealtimeClock ? 56 : CompactNotchLiveActivityMetrics.countdownWidth)
    }

    private var titleTextWidth: CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium)
        ]
        return ceil(NSAttributedString(string: transientTitle, attributes: attributes).size().width)
    }

    private var labelWidth: CGFloat {
        titleTextWidth + 12
    }

    var body: some View {
        HStack(spacing: 0) {
            leftWing

            Rectangle()
                .fill(.black)
                .frame(width: vm.closedNotchSize.width, height: notchContentHeight)

            rightWing
        }
        .frame(height: vm.effectiveClosedNotchHeight, alignment: .center)
        .contentShape(Rectangle())
        .preference(
            key: NotchHorizontalOffsetPreferenceKey.self,
            value: CompactNotchLiveActivityMetrics.horizontalOffset(
                leftWingWidth: leftWingWidth,
                rightWingWidth: rightWingWidth
            )
        )
        .accessibilityElement(children: .contain)
        .onAppear {
            if case .working = manager.state {
                triggerTransientLabel()
            }
        }
        .onDisappear {
            cancelTransientLabel()
        }
        .onChange(of: manager.state) { oldState, newState in
            switch newState {
            case .working:
                if case let .paused(_, _, reason) = oldState, reason != .away {
                    triggerTransientLabel()
                }
            case .paused:
                collapseTransientLabel()
            case .stopped, .resting, .awaitingCompletion:
                cancelTransientLabel()
            }
        }
    }

    private var leftWing: some View {
        Color.clear
            .frame(width: leftWingWidth, height: notchContentHeight)
            .background(alignment: .leading) {
                if showRealtimeClock {
                    RealtimeClockText()
                        .frame(
                            width: RealtimeClockText.displayWidth,
                            height: notchContentHeight,
                            alignment: .leading
                        )
                        .padding(.horizontal, 6)
                } else {
                    HStack(
                        spacing: showTransientLabel
                            ? CompactNotchLiveActivityMetrics.contentSpacing
                            : 0
                    ) {
                        Image(systemName: "eye")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.green)
                            .frame(width: iconWidth, height: notchContentHeight)
                            .accessibilityHidden(true)

                        if showTransientLabel {
                            labelSection
                                .transition(.opacity.combined(with: .move(edge: .leading)))
                        }
                    }
                    .padding(.leading, CompactNotchLiveActivityMetrics.leadingInset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
            }
    }

    private var labelSection: some View {
        Rectangle()
            .fill(.black)
            .frame(width: labelWidth, height: notchContentHeight)
            .overlay(alignment: .leading) {
                Text(transientTitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .frame(width: titleTextWidth, alignment: .leading)
                    .padding(.horizontal, 6)
            }
            .accessibilityHidden(true)
    }

    private var rightWing: some View {
        Color.clear
            .frame(width: rightWingWidth, height: notchContentHeight)
            .background(alignment: .trailing) {
                countdownContent
                    .frame(
                        width: showRealtimeClock
                            ? 56
                            : CompactNotchLiveActivityMetrics.countdownWidth,
                        alignment: .trailing
                    )
                    .padding(
                        .trailing,
                        showRealtimeClock ? 4 : CompactNotchLiveActivityMetrics.trailingInset
                    )
            }
    }

    @ViewBuilder
    private var countdownContent: some View {
        switch manager.state {
        case .working:
            TimelineView(.periodic(from: .now, by: 1)) { context in
                countdownText(EyeCareManager.formattedDuration(manager.remainingTime(at: context.date)))
                    .accessibilityLabel(
                        "\(activityTitle)，工作剩余\(EyeCareManager.formattedDuration(manager.remainingTime(at: context.date)))"
                    )
            }
        case let .paused(phase, remaining, _) where phase == .working:
            HStack(spacing: 4) {
                Image(systemName: "pause.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                countdownText(EyeCareManager.formattedDuration(remaining))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                "\(activityTitle)已暂停，剩余\(EyeCareManager.formattedDuration(remaining))"
            )
        default:
            EmptyView()
        }
    }

    private func countdownText(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 13, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func triggerTransientLabel() {
        guard !showRealtimeClock else { return }
        guard !enableMinimalisticUI else { return }

        cancelTransientLabel()
        setTransientLabelVisible(true)

        let task = DispatchWorkItem {
            setTransientLabelVisible(false)
            labelHideTask = nil
        }
        labelHideTask = task
        DispatchQueue.main.asyncAfter(
            deadline: .now() + transientLabelDuration,
            execute: task
        )
    }

    private func collapseTransientLabel() {
        cancelTransientLabel()
        setTransientLabelVisible(false)
    }

    private func cancelTransientLabel() {
        labelHideTask?.cancel()
        labelHideTask = nil
    }

    private func setTransientLabelVisible(_ visible: Bool) {
        if reduceMotion {
            showTransientLabel = visible
        } else {
            withAnimation(.smooth) {
                showTransientLabel = visible
            }
        }
    }

}
