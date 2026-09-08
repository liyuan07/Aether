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

private final class EyeCarePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct EyeCareBreakWindowContent: View {
    var body: some View {
        EyeCareBreakView()
            .environment(\.colorScheme, .dark)
    }
}

struct EyeCareBreakView: View {
    @ObservedObject private var eyeCareManager = EyeCareManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "eye.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Color.green)
                    .frame(width: 36, height: 36)
                    .background(Color.green.opacity(0.16), in: Circle())
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text("该休息眼睛了")
                        .font(.system(size: 22, weight: .bold))
                    Text("看向约 6 米外，让眼睛放松")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.82))
                }
            }

            breakStatus
                .frame(maxWidth: .infinity)

            VStack(spacing: 10) {
                Button(action: completeRest) {
                    Label(primaryButtonTitle, systemImage: primaryButtonIcon)
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(!eyeCareManager.canCompleteRest)
                .accessibilityHint(
                    eyeCareManager.canCompleteRest
                        ? "开始下一轮护眼工作时间"
                        : "休息倒计时结束后可用"
                )

                Button(role: .destructive, action: stopEyeCare) {
                    Label("结束护眼", systemImage: "stop.fill")
                        .font(.system(size: 14, weight: .medium))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(20)
        .frame(width: 360)
        .foregroundStyle(Color.white)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(red: 0.055, green: 0.062, blue: 0.075))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.28), lineWidth: 1)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: eyeCareManager.state)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("20-20-20 护眼休息")
    }

    @ViewBuilder
    private var breakStatus: some View {
        switch eyeCareManager.state {
        case .resting:
            EyeCareBreakCountdown(manager: eyeCareManager)
        case .awaitingCompletion:
            VStack(spacing: 4) {
                Text("休息完成")
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(Color.green)
                Text("准备好后手动开始下一轮")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.78))
            }
        default:
            EmptyView()
        }
    }

    private var primaryButtonTitle: String {
        eyeCareManager.canCompleteRest ? "已休息，开始下一轮" : "请先休息"
    }

    private var primaryButtonIcon: String {
        eyeCareManager.canCompleteRest ? "play.fill" : "hourglass"
    }

    private func completeRest() {
        _ = eyeCareManager.completeRest()
    }

    private func stopEyeCare() {
        eyeCareManager.stop()
    }
}

private struct EyeCareBreakCountdown: View {
    @ObservedObject var manager: EyeCareManager

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 4) {
                Text("\(max(0, Int(ceil(manager.remainingTime(at: context.date))))) 秒")
                    .font(.system(size: 40, weight: .bold, design: .monospaced))
                    .contentTransition(.numericText())
                Text("慢慢眨眼，不需要盯着倒计时")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.78))
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("剩余休息时间")
            .accessibilityValue("\(max(0, Int(ceil(manager.remainingTime(at: context.date))))) 秒")
        }
    }
}

@MainActor
final class EyeCareBreakWindowManager {
    static let shared = EyeCareBreakWindowManager()

    private let rightMargin: CGFloat = 24
    private let contentTopMargin: CGFloat = 18
    private var window: EyeCarePanel?
    private var hostingView: NSHostingView<EyeCareBreakWindowContent>?
    private var presentedScreenName: String?

    private init() {}

    var isVisible: Bool {
        guard let window else { return false }
        return window.isVisible && window.alphaValue > 0.01
    }

    func present(preferredScreenName: String? = nil) {
        guard !LockScreenManager.shared.currentLockStatus else {
            hide()
            return
        }

        let screen = currentlyPresentedScreen()
            ?? resolveScreen(preferredScreenName: preferredScreenName)
        guard let screen else { return }
        presentedScreenName = screen.localizedName

        let hosting = ensureHostingView()
        hosting.layoutSubtreeIfNeeded()
        let fittingSize = hosting.fittingSize
        let size = CGSize(width: 360, height: ceil(fittingSize.height))
        hosting.frame = NSRect(origin: .zero, size: size)

        let panel = ensureWindow(on: screen)
        if panel.contentView !== hosting {
            panel.contentView = hosting
        }
        panel.setFrame(frame(for: size, on: screen), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    func bringForward() {
        guard let window, isVisible else { return }
        window.orderFrontRegardless()
    }

    func reposition(preferredScreenName: String? = nil) {
        guard isVisible else { return }
        presentedScreenName = nil
        present(preferredScreenName: preferredScreenName)
    }

    func hide() {
        guard let window else { return }
        window.orderOut(nil)
        window.alphaValue = 0
        presentedScreenName = nil
    }

    private func ensureHostingView() -> NSHostingView<EyeCareBreakWindowContent> {
        if let hostingView { return hostingView }
        let hosting = FirstMouseHostingView(rootView: EyeCareBreakWindowContent())
        hostingView = hosting
        return hosting
    }

    private func ensureWindow(on screen: NSScreen) -> EyeCarePanel {
        if let window { return window }

        let panel = EyeCarePanel(
            contentRect: NSRect(x: screen.frame.maxX - 384, y: screen.visibleFrame.maxY - 260, width: 360, height: 230),
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.isMovable = false
        panel.alphaValue = 0
        ScreenCaptureVisibilityManager.shared.register(panel, scope: .entireInterface)
        window = panel
        return panel
    }

    private func currentlyPresentedScreen() -> NSScreen? {
        guard let presentedScreenName else { return nil }
        return NSScreen.screens.first { $0.localizedName == presentedScreenName }
    }

    private func resolveScreen(preferredScreenName: String?) -> NSScreen? {
        let pointer = NSEvent.mouseLocation
        if let pointerScreen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) {
            return pointerScreen
        }
        if let preferredScreenName,
           let preferred = NSScreen.screens.first(where: { $0.localizedName == preferredScreenName }) {
            return preferred
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    private func frame(for size: CGSize, on screen: NSScreen) -> NSRect {
        let menuBarHeight = max(0, screen.frame.maxY - screen.visibleFrame.maxY)
        let safeTop = max(menuBarHeight, screen.safeAreaInsets.top)
        let x = screen.frame.maxX - size.width - rightMargin
        let y = screen.frame.maxY - safeTop - contentTopMargin - size.height
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }
}
