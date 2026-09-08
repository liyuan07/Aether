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
import QuartzCore
import SwiftUI

private struct TimerInteractionPanelContent: View {
    let hoverChanged: (Bool) -> Void

    var body: some View {
        TimerPopover()
            .environment(\.colorScheme, .dark)
            .onHover(perform: hoverChanged)
    }
}

@MainActor
final class TimerInteractionPanelManager {
    static let shared = TimerInteractionPanelManager()

    private var window: DynamicIslandWindow?
    private var hostingView: NSHostingView<TimerInteractionPanelContent>?
    private var hideTask: Task<Void, Never>?
    private var pointerMonitorTask: Task<Void, Never>?
    private var activeTriggerRect: CGRect?
    private var animationGeneration = 0

    private let rightMargin: CGFloat = 24
    private let contentTopMargin: CGFloat = 18

    private init() {}

    var isVisible: Bool {
        guard let window else { return false }
        return window.isVisible && window.alphaValue > 0.01
    }

    func present(using viewModel: DynamicIslandViewModel, triggerRect: CGRect? = nil) {
        cancelScheduledHide()
        activeTriggerRect = triggerRect
        EyeCareManager.shared.beginPanelDisplayUpdates()

        guard !LockScreenManager.shared.currentLockStatus,
              let screen = resolveScreen(from: viewModel, triggerRect: triggerRect) else {
            hide(animated: false)
            return
        }

        let content = TimerInteractionPanelContent { [weak self] hovering in
            self?.panelHoverChanged(hovering)
        }
        let hosting = ensureHostingView(with: content)
        hosting.layoutSubtreeIfNeeded()
        let measured = hosting.fittingSize
        let size = CGSize(
            width: ceil(measured.width),
            height: min(ceil(measured.height), screen.visibleFrame.height - 80)
        )
        hosting.frame = NSRect(origin: .zero, size: size)

        let window = ensureWindow(on: screen)
        if window.contentView !== hosting {
            window.contentView = hosting
        }

        let targetFrame = frame(for: size, on: screen)
        startPointerMonitoring()
        animationGeneration += 1
        let generation = animationGeneration

        if !isVisible {
            var startFrame = targetFrame
            startFrame.origin.y += 8
            window.setFrame(startFrame, display: true)
            window.alphaValue = 0
            window.orderFrontRegardless()

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().setFrame(targetFrame, display: true)
                window.animator().alphaValue = 1
            } completionHandler: { [weak self, weak window] in
                Task { @MainActor in
                    guard let self, let window, self.animationGeneration == generation else { return }
                    window.setFrame(targetFrame, display: false)
                }
            }
        } else {
            window.setFrame(targetFrame, display: true)
            window.alphaValue = 1
            window.orderFrontRegardless()
        }
    }

    func scheduleHide(after delay: Duration = .milliseconds(900)) {
        cancelScheduledHide()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide(animated: Bool = true) {
        cancelScheduledHide()
        stopPointerMonitoring()
        EyeCareManager.shared.endPanelDisplayUpdates()
        activeTriggerRect = nil
        guard let window, window.isVisible else { return }

        animationGeneration += 1
        let generation = animationGeneration

        guard animated, window.alphaValue > 0.01 else {
            window.orderOut(nil)
            window.alphaValue = 0
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        } completionHandler: { [weak self, weak window] in
            Task { @MainActor in
                guard let self, let window, self.animationGeneration == generation else { return }
                window.orderOut(nil)
            }
        }
    }

    private func panelHoverChanged(_ hovering: Bool) {
        if hovering {
            cancelScheduledHide()
        } else {
            scheduleHide(after: .milliseconds(220))
        }
    }

    private func startPointerMonitoring() {
        guard pointerMonitorTask == nil else { return }

        pointerMonitorTask = Task { @MainActor [weak self] in
            var outsideSince: Date?

            while !Task.isCancelled {
                guard let self,
                      self.isVisible,
                      let window = self.window else {
                    try? await Task.sleep(for: .milliseconds(100))
                    continue
                }

                let mouse = NSEvent.mouseLocation
                let panelRect = window.frame.insetBy(dx: -6, dy: -6)
                let isOnTrigger = self.activeTriggerRect?
                    .insetBy(dx: -6, dy: -6)
                    .contains(mouse) == true

                if panelRect.contains(mouse) || isOnTrigger {
                    outsideSince = nil
                    self.cancelScheduledHide()
                } else if let outsideSince {
                    if Date().timeIntervalSince(outsideSince) >= 0.9 {
                        self.hide()
                        break
                    }
                } else {
                    outsideSince = Date()
                }

                try? await Task.sleep(for: .milliseconds(100))
            }

            self?.pointerMonitorTask = nil
        }
    }

    private func stopPointerMonitoring() {
        pointerMonitorTask?.cancel()
        pointerMonitorTask = nil
    }

    private func cancelScheduledHide() {
        hideTask?.cancel()
        hideTask = nil
    }

    private func ensureHostingView(
        with content: TimerInteractionPanelContent
    ) -> NSHostingView<TimerInteractionPanelContent> {
        if let hostingView {
            hostingView.rootView = content
            return hostingView
        }

        let hosting = NSHostingView(rootView: content)
        hostingView = hosting
        return hosting
    }

    private func ensureWindow(on screen: NSScreen) -> DynamicIslandWindow {
        if let window { return window }

        let window = DynamicIslandWindow(
            contentRect: NSRect(x: screen.frame.maxX - 304, y: screen.frame.maxY - 380, width: 280, height: 320),
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.ignoresMouseEvents = false
        window.alphaValue = 0

        self.window = window
        return window
    }

    private func resolveScreen(
        from viewModel: DynamicIslandViewModel,
        triggerRect: CGRect?
    ) -> NSScreen? {
        if let triggerRect,
           let triggerScreen = NSScreen.screens.first(where: { $0.frame.intersects(triggerRect) }) {
            return triggerScreen
        }

        if let screenName = viewModel.screen,
           let screen = NSScreen.screens.first(where: { $0.localizedName == screenName }) {
            return screen
        }
        return NSScreen.main
    }

    private func frame(for size: CGSize, on screen: NSScreen) -> NSRect {
        let menuBarHeight = max(0, screen.frame.maxY - screen.visibleFrame.maxY)
        let safeTop = max(menuBarHeight, screen.safeAreaInsets.top)
        let x = screen.frame.maxX - size.width - rightMargin
        let y = screen.frame.maxY - safeTop - contentTopMargin - size.height
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }
}
