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
import Combine
import Defaults
import QuartzCore
import SkyLightWindow
import SwiftUI

@MainActor
final class LockScreenTimerWidgetAnimator: ObservableObject {
    @Published var isPresented: Bool

    init(isPresented: Bool = false) {
        self.isPresented = isPresented
    }
}

@MainActor
final class LockScreenTimerWidgetManager {
    static let shared = LockScreenTimerWidgetManager()

    private let timerManager = TimerManager.shared
    private var cancellables = Set<AnyCancellable>()
    private var isLocked = false

    private init() {
        timerManager.$isTimerActive
            .combineLatest(timerManager.$activeSource)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.updateVisibility() }
            .store(in: &cancellables)

        Defaults.publisher(.enableLockScreenTimerWidget, options: [])
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateVisibility() }
            .store(in: &cancellables)
    }

    func handleLockStateChange(isLocked: Bool) {
        self.isLocked = isLocked
        updateVisibility()
    }

    private func updateVisibility() {
        guard isLocked,
              Defaults[.enableLockScreenTimerWidget],
              timerManager.hasManualTimerRunning else {
            LockScreenTimerWidgetPanelManager.shared.hide()
            return
        }
        LockScreenTimerWidgetPanelManager.shared.showWidget()
    }
}

@MainActor
final class LockScreenTimerWidgetPanelManager {
    static let shared = LockScreenTimerWidgetPanelManager()
    static let hideAnimationDurationNanoseconds: UInt64 = 360_000_000

    private var window: NSWindow?
    private var delegatedWindow = false
    private let animator = LockScreenTimerWidgetAnimator()
    private var hideTask: Task<Void, Never>?

    private init() {}

    func showWidget() {
        guard let screen = preferredScreen() else { return }
        let panel = ensureWindow()
        let frame = targetFrame(on: screen)
        panel.setFrame(frame, display: true)
        panel.contentView?.frame = NSRect(origin: .zero, size: frame.size)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        hideTask?.cancel()
        hideTask = nil
        animator.isPresented = true
    }

    func hide(animated: Bool = true) {
        guard let window else { return }
        hideTask?.cancel()
        animator.isPresented = false

        let delay = animated ? Self.hideAnimationDurationNanoseconds : 0
        guard delay > 0 else {
            window.orderOut(nil)
            return
        }

        hideTask = Task { [weak window, weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                window?.orderOut(nil)
                self?.hideTask = nil
            }
        }
    }

    private func ensureWindow() -> NSWindow {
        if let window { return window }

        let panel = NSWindow(
            contentRect: NSRect(origin: .zero, size: LockScreenTimerWidget.preferredSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = false
        panel.isMovable = false

        let hosting = NSHostingView(rootView: LockScreenTimerWidget(animator: animator))
        hosting.frame = NSRect(origin: .zero, size: LockScreenTimerWidget.preferredSize)
        hosting.autoresizingMask = [.width, .height]
        hosting.wantsLayer = true
        hosting.layer?.masksToBounds = true
        hosting.layer?.cornerRadius = LockScreenTimerWidget.cornerRadius
        panel.contentView = hosting

        ScreenCaptureVisibilityManager.shared.register(panel, scope: .entireInterface)
        if !delegatedWindow {
            SkyLightOperator.shared.delegateWindow(panel)
            delegatedWindow = true
        }

        window = panel
        return panel
    }

    private func preferredScreen() -> NSScreen? {
        let name = DynamicIslandViewCoordinator.shared.selectedScreen
        return NSScreen.screens.first { $0.localizedName == name } ?? NSScreen.main
    }

    private func targetFrame(on screen: NSScreen) -> NSRect {
        let size = LockScreenTimerWidget.preferredSize
        let offset = min(max(CGFloat(Defaults[.lockScreenTimerVerticalOffset]), -160), 160)
        let y = min(
            max(screen.frame.midY + 6 + offset, screen.frame.minY + 100),
            screen.frame.maxY - size.height - 72
        )
        return NSRect(
            x: screen.frame.midX - size.width / 2,
            y: y,
            width: size.width,
            height: size.height
        )
    }
}
