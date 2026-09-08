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

@main
struct ClipboardApplication: App {
    @NSApplicationDelegateAdaptor(ClipboardAppDelegate.self)
    private var appDelegate

    var body: some Scene {
        Settings {
            ClipboardSettingsView()
        }
    }
}

@MainActor
final class ClipboardAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        PreferenceKeys.registerDefaults()
        NSApp.setActivationPolicy(.accessory)

        if let icon = NSImage(
            systemSymbolName: "doc.on.clipboard.fill",
            accessibilityDescription: "Clipboard"
        ) {
            NSApp.applicationIconImage = icon
        }

        _ = ClipboardStore.shared
        if UserDefaults.standard.bool(
            forKey: PreferenceKeys.monitoringEnabled
        ) {
            ClipboardStore.shared.startMonitoring()
        }
        LaunchAtLoginController.applyDefault()
        HotKeyManager.shared.refresh()
        StatusItemController.shared.install()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AccessibilityPermissionMonitor.shared.stop()
        ClipboardStore.shared.stopMonitoring()
        ClipboardStore.shared.flushArchive()
        HotKeyManager.shared.unregister()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        ClipboardPanelController.shared.showPanel()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        false
    }
}

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    static let shared = StatusItemController()

    private var statusItem: NSStatusItem?

    func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = item.button else { return }
        button.image = NSImage(
            systemSymbolName: "doc.on.clipboard",
            accessibilityDescription: "Clipboard"
        )
        button.image?.isTemplate = true
        button.setAccessibilityIdentifier("ClipboardStatusItem")
        button.toolTip = "Clipboard · ⇧⌘J"
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            ClipboardPanelController.shared.togglePanel()
        }
    }

    private func showMenu() {
        guard let statusItem else { return }
        let menu = makeMenu()
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let openItem = NSMenuItem(
            title: "打开剪切板",
            action: #selector(openPanel),
            keyEquivalent: ""
        )
        openItem.target = self
        menu.addItem(openItem)

        let settingsItem = NSMenuItem(
            title: "设置…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())

        let launchItem = NSMenuItem(
            title: "登录时自动启动",
            action: #selector(toggleLaunchAtLogin(_:)),
            keyEquivalent: ""
        )
        launchItem.target = self
        launchItem.state = UserDefaults.standard.bool(
            forKey: PreferenceKeys.launchAtLogin
        ) ? .on : .off
        menu.addItem(launchItem)

        let monitorItem = NSMenuItem(
            title: "记录剪切板历史",
            action: #selector(toggleMonitoring(_:)),
            keyEquivalent: ""
        )
        monitorItem.target = self
        monitorItem.state = UserDefaults.standard.bool(
            forKey: PreferenceKeys.monitoringEnabled
        ) ? .on : .off
        menu.addItem(monitorItem)
        menu.addItem(.separator())

        let restartItem = NSMenuItem(
            title: "重启 Clipboard",
            action: #selector(restart),
            keyEquivalent: ""
        )
        restartItem.target = self
        menu.addItem(restartItem)

        let quitItem = NSMenuItem(
            title: "退出 Clipboard",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    func menuDidClose(_ menu: NSMenu) {
        statusItem?.menu = nil
    }

    @objc private func openPanel() {
        ClipboardPanelController.shared.showPanel()
    }

    @objc private func openSettings() {
        ClipboardPanelController.shared.hidePanel()
        SettingsWindowController.shared.show()
    }

    @objc private func toggleLaunchAtLogin(_ item: NSMenuItem) {
        let enabled = item.state != .on
        UserDefaults.standard.set(
            enabled,
            forKey: PreferenceKeys.launchAtLogin
        )
        _ = LaunchAtLoginController.setEnabled(enabled)
    }

    @objc private func toggleMonitoring(_ item: NSMenuItem) {
        let enabled = item.state != .on
        UserDefaults.standard.set(
            enabled,
            forKey: PreferenceKeys.monitoringEnabled
        )
        NotificationCenter.default.post(
            name: .clipboardPreferencesDidChange,
            object: nil
        )
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func restart() {
        ApplicationRestartController.restart()
    }
}
