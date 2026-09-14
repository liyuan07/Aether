import AppKit
import PromptFeature
import SwiftUI

/// The application owns presentation; the feature retains the editor and history state.
@MainActor final class PromptWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    var isVisible: Bool { window?.isVisible == true }

    func show() {
        if window == nil {
            let controller = NSHostingController(rootView: PromptModule.shared.workspace())
            let window = NSWindow(contentViewController: controller)
            window.title = "Prompt 优化"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 1040, height: 720))
            window.minSize = NSSize(width: 900, height: 620)
            window.setFrameAutosaveName("AetherPromptWindow")
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        PromptModule.shared.stop()
    }
}
