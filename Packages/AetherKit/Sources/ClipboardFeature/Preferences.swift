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
import ApplicationServices
import Foundation
import ServiceManagement

enum PreferenceKeys {
    static let launchAtLogin = "launchAtLogin"
    static let shortcutEnabled = "shortcutEnabled"
    static let monitoringEnabled = "monitoringEnabled"
    static let historyLimit = "historyLimit"
    static let expirationDays = "expirationDays"
    static let searchDebounceEnabled = "searchDebounceEnabled"
    static let searchDebounceMilliseconds = "searchDebounceMilliseconds"
    static let lockedPanelTab = "lockedPanelTab"
    static let quickClipboardRailExpanded = "quickClipboardRailExpanded"

    static func registerDefaults(in defaults: UserDefaults = AppEnvironment.clipboardDefaults) {
        defaults.register(defaults: [
            launchAtLogin: true,
            shortcutEnabled: true,
            monitoringEnabled: true,
            historyLimit: 5_000,
            expirationDays: 30,
            searchDebounceEnabled: true,
            searchDebounceMilliseconds:
                ClipboardSearchDebounce.defaultMilliseconds,
            lockedPanelTab: "",
            quickClipboardRailExpanded: true
        ])
    }
}

enum ClipboardSearchDebounce {
    static let defaultMilliseconds = 150
    static let supportedMilliseconds = 50...1_000
    static let stepMilliseconds = 50

    static func isEnabled(in defaults: UserDefaults = AppEnvironment.clipboardDefaults) -> Bool {
        guard defaults.object(forKey: PreferenceKeys.searchDebounceEnabled) != nil else {
            return true
        }
        return defaults.bool(forKey: PreferenceKeys.searchDebounceEnabled)
    }

    static func milliseconds(in defaults: UserDefaults = AppEnvironment.clipboardDefaults) -> Int {
        guard defaults.object(
            forKey: PreferenceKeys.searchDebounceMilliseconds
        ) != nil else {
            return defaultMilliseconds
        }
        return clamped(
            defaults.integer(forKey: PreferenceKeys.searchDebounceMilliseconds)
        )
    }

    static func clamped(_ milliseconds: Int) -> Int {
        min(
            max(milliseconds, supportedMilliseconds.lowerBound),
            supportedMilliseconds.upperBound
        )
    }

    static func nanoseconds(for milliseconds: Int) -> UInt64 {
        UInt64(clamped(milliseconds)) * 1_000_000
    }
}

enum ClipboardPanelTabLock {
    static func tab(in defaults: UserDefaults = AppEnvironment.clipboardDefaults) -> ClipboardTab? {
        guard let rawValue = defaults.string(
            forKey: PreferenceKeys.lockedPanelTab
        ), !rawValue.isEmpty else {
            return nil
        }
        return ClipboardTab(rawValue: rawValue)
    }

    static func set(
        _ tab: ClipboardTab?,
        in defaults: UserDefaults = AppEnvironment.clipboardDefaults
    ) {
        defaults.set(tab?.rawValue ?? "", forKey: PreferenceKeys.lockedPanelTab)
    }
}

extension Notification.Name {
    static let clipboardPreferencesDidChange = Notification.Name(
        "clipboardPreferencesDidChange"
    )
    static let clipboardAccessibilityDidChange = Notification.Name(
        "clipboardAccessibilityDidChange"
    )
}

@MainActor
enum AccessibilityController {
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    static func requestAccess() {
        AccessibilityPermissionMonitor.shared.waitForGrant()
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    static func openSystemSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
        ]
        for candidate in candidates {
            guard let url = URL(string: candidate) else { continue }
            if NSWorkspace.shared.open(url) {
                return
            }
        }
    }
}
