// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import CAetherCore

/// Native adapters supply typed preferences and canonical Swift string comparisons.
public enum MigrationPreferencePolicy {
    public enum Destination { case app, clipboard, shortcuts }
    public static func launchAtLogin(existing: Bool?, timer: Bool?, clipboard: Bool?, shortcuts: Bool?) -> Bool {
        func code(_ value: Bool?) -> UInt8 { value.map { $0 ? 2 : 1 } ?? 0 }
        return aether_migration_login(code(existing), code(timer), code(clipboard), code(shortcuts)) != 0
    }
    public static func destination(for source: String) -> Destination {
        switch aether_migration_destination(source == "Clipboard" ? 1 : 0, source == "Shortcuts" ? 1 : 0) {
        case 1: .clipboard
        case 2: .shortcuts
        default: .app
        }
    }
    public static func includes(key: String, source: String) -> Bool {
        aether_migration_preference(source == "General" ? 1 : 0, key == "launchAtLogin" ? 1 : 0,
            key.hasPrefix("didRequest") ? 1 : 0) != 0
    }
}
