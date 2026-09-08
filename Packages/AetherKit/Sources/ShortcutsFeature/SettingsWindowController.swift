import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let model: AppModel
    private let navigation = SettingsNavigationModel()
    private let presentationChanged: (Bool) -> Void

    init(model: AppModel, presentationChanged: @escaping (Bool) -> Void = { _ in }) {
        self.model = model
        self.presentationChanged = presentationChanged
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "KeyPilot 设置"
        window.minSize = NSSize(width: 980, height: 640)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace]
        window.contentViewController = NSHostingController(
            rootView: SettingsView(model: model, navigation: navigation)
        )
        super.init(window: window)
        window.delegate = self
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(section: SettingsSection = .general, ruleID: UUID? = nil) {
        navigation.section = ruleID == nil ? section : .shortcuts
        if let ruleID { model.selectedRuleID = ruleID }
        presentationChanged(true)
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        presentationChanged(false)
    }

    func windowDidMiniaturize(_ notification: Notification) {
        presentationChanged(false)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        presentationChanged(true)
    }
}
