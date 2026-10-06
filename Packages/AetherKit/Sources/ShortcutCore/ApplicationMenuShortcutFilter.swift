// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import CAetherCore

public enum ApplicationMenuShortcutFilter {
    public static func shouldInclude(_ shortcut: KeyCombination, topLevelIndex: Int, branchShortcuts: [KeyCombination]) -> Bool {
        let core = branchShortcuts.map(\.rustKey)
        return core.withUnsafeBufferPointer { aether_menu_include(shortcut.rustKey, topLevelIndex, $0.baseAddress, $0.count) != 0 }
    }
}
