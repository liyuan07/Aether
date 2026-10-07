import SharedSupport
/*
 * Clipboard
 * Copyright (C) 2026 Li Yuan
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import AppKit
import SwiftUI

extension Notification.Name {
    static let clipboardPanelActivateSelection = Notification.Name(
        "clipboardPanelActivateSelection"
    )
}

private enum PanelNotificationKey {
    static let extendsSelection = "extendsSelection"
}

final class ClipboardPanel: NSPanel {
    private var localKeyMonitor: Any?
    private var backgroundObserver: NSObjectProtocol?

    init(onClose: @escaping () -> Void) {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        configureWindow()
        let rootView = ClipboardPanelView(onClose: onClose)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.wantsLayer = true
        hostingView.layer?.cornerRadius = 14
        hostingView.layer?.masksToBounds = true
        contentView = hostingView

        let size = preferredSize()
        hostingView.setFrameSize(size)
        setContentSize(size)
        installKeyMonitor()
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: .clipboardBackgroundDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateBackgroundSize() }
        }
        BackgroundManager.shared.loadIfNeeded()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, handleKey(event) {
            return
        }
        super.sendEvent(event)
    }

    override func close() {
        if let backgroundObserver {
            NotificationCenter.default.removeObserver(backgroundObserver)
            self.backgroundObserver = nil
        }
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
        super.close()
    }

    func positionOnActiveScreen() {
        guard let screen = screenAtPointer() else { return }
        updateBackgroundSize(on: screen)
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.midX - frame.width / 2,
            y: visible.midY - frame.height / 2
        )
        setFrameOrigin(origin)
    }

    private func configureWindow() {
        ClipboardPanelKeyboardRouter.shared.area = .history
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        level = .floating
        isMovableByWindowBackground = true
        isFloatingPanel = true
        acceptsMouseMovedEvents = true
        collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .fullScreenAuxiliary
        ]
    }

    private func preferredSize(on target: NSScreen? = nil) -> NSSize {
        guard let screen = target ?? screenAtPointer() else {
            return NSSize(width: 1_180, height: 700)
        }
        let size = screen.visibleFrame.size
        return NSSize(
            width: min(
                max(size.width * 0.76, 1_120),
                min(size.width * 0.94, 1_380)
            ),
            height: min(max(size.height * 0.78, 580), size.height * 0.94)
        )
    }

    private func updateBackgroundSize(on target: NSScreen? = nil) {
        guard let screen = target ?? self.screen ?? screenAtPointer() else { return }
        let manager = BackgroundManager.shared
        let image = manager.settings.mode == .windowToImage ? manager.payload?.size : nil
        let size = BackgroundGeometry.windowSize(base: preferredSize(on: screen), image: image, visible: screen.visibleFrame.size)
        guard size != frame.size else { return }
        let visible = screen.visibleFrame
        let center = NSPoint(x: frame.midX, y: frame.midY)
        setFrame(NSRect(x: min(max(center.x - size.width / 2, visible.minX), visible.maxX - size.width),
                        y: min(max(center.y - size.height / 2, visible.minY), visible.maxY - size.height),
                        width: size.width, height: size.height), display: true)
    }

    private func screenAtPointer() -> NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(location) })
            ?? NSScreen.main
    }

    private func installKeyMonitor() {
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { [weak self] event in
            guard let self, self.isVisible, self.handleKey(event) else {
                return event
            }
            return nil
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        if isEditingText {
            return false
        }
        if ClipboardPanelKeyboardRouter.shared.handle(event) {
            return true
        }
        switch event.keyCode {
        case 36, 76:
            NotificationCenter.default.post(
                name: .clipboardPanelActivateSelection,
                object: self,
                userInfo: [
                    PanelNotificationKey.extendsSelection:
                        event.modifierFlags.contains(.command)
                ]
            )
            return true
        case 53:
            close()
            return true
        default:
            return false
        }
    }

    private var isEditingText: Bool {
        firstResponder is NSTextView || firstResponder is NSTextField
    }
}

@MainActor
final class ClipboardPanelController {
    static let shared = ClipboardPanelController()

    private var panel: ClipboardPanel?

    private init() {}

    var isVisible: Bool {
        panel?.isVisible == true
    }

    func showPanel() {
        hidePanel()
        PasteCoordinator.shared.captureCurrentApplication()

        let panel = ClipboardPanel { [weak self] in
            self?.hidePanel()
        }
        panel.positionOnActiveScreen()
        self.panel = panel

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        DispatchQueue.main.async {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func hidePanel() {
        let existing = panel
        panel = nil
        if existing?.isVisible == true {
            existing?.close()
        }
    }

    func togglePanel() {
        isVisible ? hidePanel() : showPanel()
    }

    /// Repeated presentation keeps the current panel and its search state.
    func presentPanel() {
        guard let panel, panel.isVisible else { showPanel(); return }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }
}

struct ClipboardVisualEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
