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
import Foundation

@MainActor
enum ApplicationRestartController {
    static func restart() {
        ClipboardStore.shared.flushArchive()

        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = helperArguments(
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            bundlePath: Bundle.main.bundlePath
        )

        do {
            try helper.run()
            NSApp.terminate(nil)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "无法重启 Clipboard"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "好")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    static func helperArguments(
        processIdentifier: pid_t,
        bundlePath: String
    ) -> [String] {
        [
            "-c",
            """
            while kill -0 "$1" 2>/dev/null; do
              sleep 0.1
            done
            exec /usr/bin/open "$2"
            """,
            "clipboard-restart",
            String(processIdentifier),
            bundlePath
        ]
    }
}

@MainActor
final class AccessibilityPermissionMonitor {
    static let shared = AccessibilityPermissionMonitor()

    private var timer: Timer?
    private var deadline = Date.distantPast
    private var isPresentingRestartAlert = false

    private init() {}

    func waitForGrant() {
        guard !AccessibilityController.isTrusted else {
            postStatusChange()
            return
        }

        deadline = Date().addingTimeInterval(15 * 60)
        guard timer == nil else { return }

        let timer = Timer(timeInterval: 0.5, repeats: true) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkPermission()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func checkPermission() {
        if AccessibilityController.isTrusted {
            stop()
            postStatusChange()
            presentRestartAlert()
        } else if Date() >= deadline {
            stop()
        }
    }

    private func postStatusChange() {
        NotificationCenter.default.post(
            name: .clipboardAccessibilityDidChange,
            object: nil
        )
    }

    private func presentRestartAlert() {
        guard !isPresentingRestartAlert else { return }
        isPresentingRestartAlert = true
        defer { isPresentingRestartAlert = false }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "辅助功能权限已启用"
        alert.informativeText = "需要重启 Clipboard 后才能稳定使用自动粘贴。"
        alert.addButton(withTitle: "立即重启")
        alert.addButton(withTitle: "稍后")

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            ApplicationRestartController.restart()
        }
    }
}
