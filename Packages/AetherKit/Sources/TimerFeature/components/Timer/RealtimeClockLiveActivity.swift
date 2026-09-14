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
import SwiftUI

struct RealtimeClockText: NSViewRepresentable {
    static let displayWidth: CGFloat = 84

    @ObservedObject private var lockScreenManager = LockScreenManager.shared

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField(labelWithString: Self.formatted(Date()))
        textField.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        textField.textColor = .white
        textField.alignment = .left
        textField.lineBreakMode = .byClipping
        textField.setAccessibilityLabel("实时时间")
        context.coordinator.attach(textField)
        if !lockScreenManager.isLocked {
            context.coordinator.start()
        }
        return textField
    }

    func updateNSView(_ textField: NSTextField, context: Context) {
        context.coordinator.attach(textField)
        if lockScreenManager.isLocked {
            context.coordinator.stop()
        } else {
            context.coordinator.start()
        }
    }

    static func dismantleNSView(_ textField: NSTextField, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator: NSObject {
        private weak var textField: NSTextField?
        private var timer: Timer?
        private var secondsFromGMT = 0
        private var nextTimeZoneRefresh = Date.distantPast

        func attach(_ textField: NSTextField) {
            self.textField = textField
            updateText()
        }

        func start() {
            guard timer == nil else { return }
            let timer = Timer(
                timeInterval: 1.0 / 30.0,
                target: self,
                selector: #selector(updateText),
                userInfo: nil,
                repeats: true
            )
            timer.tolerance = 0.004
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            updateText()
        }

        func stop() {
            timer?.invalidate()
            timer = nil
        }

        @objc private func updateText() {
            guard let textField else {
                stop()
                return
            }
            let now = Date()
            if now >= nextTimeZoneRefresh {
                secondsFromGMT = TimeZone.autoupdatingCurrent.secondsFromGMT(for: now)
                nextTimeZoneRefresh = now.addingTimeInterval(60)
            }
            textField.stringValue = RealtimeClockText.formatted(
                now,
                secondsFromGMT: secondsFromGMT
            )
        }
    }

    private static func formatted(
        _ date: Date,
        secondsFromGMT: Int? = nil
    ) -> String {
        let offset = secondsFromGMT ?? TimeZone.autoupdatingCurrent.secondsFromGMT(for: date)
        let millisecondsPerDay: Int64 = 86_400_000
        let localMilliseconds = Int64(date.timeIntervalSince1970 * 1_000)
            + Int64(offset) * 1_000
        let millisecondsSinceMidnight = (
            localMilliseconds % millisecondsPerDay + millisecondsPerDay
        ) % millisecondsPerDay
        let hours = millisecondsSinceMidnight / 3_600_000
        let minutes = millisecondsSinceMidnight / 60_000 % 60
        let seconds = millisecondsSinceMidnight / 1_000 % 60
        let milliseconds = millisecondsSinceMidnight % 1_000
        return String(
            format: "%02d:%02d:%02d.%03d",
            Int(hours),
            Int(minutes),
            Int(seconds),
            Int(milliseconds)
        )
    }
}

struct RealtimeClockLiveActivity: View {
    @EnvironmentObject private var vm: DynamicIslandViewModel

    private let horizontalPadding: CGFloat = 12

    private var notchContentHeight: CGFloat {
        max(0, vm.effectiveClosedNotchHeight - 12)
    }

    private var wingWidth: CGFloat {
        RealtimeClockText.displayWidth + horizontalPadding
    }

    var body: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: wingWidth, height: notchContentHeight)
                .background(alignment: .leading) {
                    RealtimeClockText()
                        .frame(
                            width: RealtimeClockText.displayWidth,
                            height: notchContentHeight,
                            alignment: .leading
                        )
                        .padding(.horizontal, horizontalPadding / 2)
                }

            Rectangle()
                .fill(.black)
                .frame(width: vm.closedNotchSize.width, height: notchContentHeight)

        }
        .frame(height: vm.effectiveClosedNotchHeight, alignment: .center)
        .preference(
            key: NotchHorizontalOffsetPreferenceKey.self,
            value: CompactNotchLiveActivityMetrics.horizontalOffset(
                leftWingWidth: wingWidth,
                rightWingWidth: 0
            )
        )
        .accessibilityElement(children: .combine)
    }
}
