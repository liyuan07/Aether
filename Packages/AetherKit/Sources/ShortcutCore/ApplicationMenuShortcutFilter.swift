public enum ApplicationMenuShortcutFilter {
    public static func shouldInclude(
        _ shortcut: KeyCombination,
        topLevelIndex: Int,
        branchShortcuts: [KeyCombination]
    ) -> Bool {
        guard topLevelIndex > 1 else { return false }

        if appearsToBeStandardEditMenu(branchShortcuts) {
            return !standardEditShortcuts.contains(shortcut)
                && shortcut.keyCode != 128
        }

        if appearsToBeStandardWindowMenu(branchShortcuts) {
            return !isStandardWindowShortcut(shortcut)
        }

        return true
    }

    private static let standardEditShortcuts: Set<KeyCombination> = [
        shortcut(6, [.command]),
        shortcut(6, [.command, .shift]),
        shortcut(7, [.command]),
        shortcut(8, [.command]),
        shortcut(9, [.command]),
        shortcut(0, [.command])
    ]

    private static let editMenuFingerprint: Set<KeyCombination> = [
        shortcut(7, [.command]),
        shortcut(8, [.command]),
        shortcut(9, [.command]),
        shortcut(0, [.command])
    ]

    private static let standardWindowShortcuts: Set<KeyCombination> = [
        shortcut(13, [.command]),
        shortcut(13, [.command, .option]),
        shortcut(46, [.command]),
        shortcut(46, [.command, .option]),
        shortcut(3, [.command, .control])
    ]

    private static func appearsToBeStandardEditMenu(_ shortcuts: [KeyCombination]) -> Bool {
        editMenuFingerprint.intersection(shortcuts).count >= 3
    }

    private static func appearsToBeStandardWindowMenu(_ shortcuts: [KeyCombination]) -> Bool {
        let shortcutSet = Set(shortcuts)
        let hasMinimize = shortcutSet.contains(shortcut(46, [.command]))
        let hasWindowManagement = shortcutSet.contains(shortcut(13, [.command]))
            || shortcutSet.contains(shortcut(3, [.command, .control]))
            || shortcuts.contains(where: isSystemTilingShortcut)
        return hasMinimize && hasWindowManagement
    }

    private static func isStandardWindowShortcut(_ shortcut: KeyCombination) -> Bool {
        standardWindowShortcuts.contains(shortcut) || isSystemTilingShortcut(shortcut)
    }

    private static func isSystemTilingShortcut(_ shortcut: KeyCombination) -> Bool {
        guard (123...126).contains(shortcut.keyCode),
              shortcut.modifiers.contains(.control)
        else { return false }

        let allowedModifiers: ShortcutModifiers = [.control, .option, .shift]
        return shortcut.modifiers.subtracting(allowedModifiers).isEmpty
    }

    private static func shortcut(
        _ keyCode: UInt16,
        _ modifiers: ShortcutModifiers
    ) -> KeyCombination {
        KeyCombination(keyCode: keyCode, modifiers: modifiers)
    }
}
