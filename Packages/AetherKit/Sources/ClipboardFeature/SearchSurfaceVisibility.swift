// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI

/// Observe the actual window as well as SwiftUI removal: retained hosting views can be ordered out.
struct SearchSurfaceVisibility: NSViewRepresentable {
    let changed: (Bool) -> Void
    func makeNSView(context: Context) -> VisibilityView { VisibilityView(changed: changed) }
    func updateNSView(_ view: VisibilityView, context: Context) { view.changed = changed; view.report() }
    static func dismantleNSView(_ view: VisibilityView, coordinator: ()) { view.detach() }

    final class VisibilityView: NSView {
        var changed: (Bool) -> Void
        private var observers: [NSObjectProtocol] = []
        private var revision = 0
        init(changed: @escaping (Bool) -> Void) { self.changed = changed; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            detach()
            if let window {
                for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification] {
                    observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.report() }
                    })
                }
            }
            report()
        }
        func detach() {
            revision &+= 1
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
            changed(false)
        }
        func report() {
            revision &+= 1
            let expected = revision
            DispatchQueue.main.async { [weak self] in
                guard let self, self.revision == expected else { return }
                self.changed(self.window?.isVisible == true && self.window?.isMiniaturized == false)
            }
        }
    }
}
