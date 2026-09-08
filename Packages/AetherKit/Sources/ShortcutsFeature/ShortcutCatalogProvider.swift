import SharedSupport
import AppKit
import ApplicationServices
import ShortcutCore

struct CatalogShortcut: Identifiable {
    let id: String
    let name: String
    let detail: String
    let shortcut: KeyCombination
}

struct ApplicationShortcutCatalog {
    let applicationName: String
    let shortcuts: [CatalogShortcut]
}

final class ApplicationShortcutCatalogProvider {
    static let shared = ApplicationShortcutCatalogProvider()

    private let queue = DispatchQueue(
        label: "com.liyuan.keypilot.application-shortcut-catalog",
        qos: .userInitiated
    )

    func load(
        for application: NSRunningApplication,
        completion: @escaping (ApplicationShortcutCatalog) -> Void
    ) {
        let applicationName = application.localizedName
            ?? application.bundleIdentifier
            ?? "当前软件"
        let processIdentifier = application.processIdentifier

        queue.async {
            let shortcuts = Self.scanMenuShortcuts(processIdentifier: processIdentifier)
            let catalog = ApplicationShortcutCatalog(
                applicationName: applicationName,
                shortcuts: shortcuts
            )
            DispatchQueue.main.async { completion(catalog) }
        }
    }

    private static func scanMenuShortcuts(processIdentifier: pid_t) -> [CatalogShortcut] {
        let appElement = AXUIElementCreateApplication(processIdentifier)
        guard let menuBarValue = AXHelpers.value(
            appElement,
            attribute: kAXMenuBarAttribute as CFString
        ) else { return [] }

        let menuBar = unsafeBitCast(menuBarValue, to: AXUIElement.self)
        var remainingNodes = 4_000
        var seen = Set<String>()
        var shortcuts: [CatalogShortcut] = []
        let topLevelMenus = AXHelpers.elements(
            menuBar,
            attribute: kAXChildrenAttribute as CFString
        )
        for (topLevelIndex, menu) in topLevelMenus.enumerated() {
            var branchItems: [(title: String, shortcut: KeyCombination)] = []
            scanBranch(menu, remainingNodes: &remainingNodes, items: &branchItems)
            let branchShortcuts = branchItems.map(\.shortcut)

            for item in branchItems where ApplicationMenuShortcutFilter.shouldInclude(
                item.shortcut,
                topLevelIndex: topLevelIndex,
                branchShortcuts: branchShortcuts
            ) {
                let identity = "\(item.shortcut.displayString)|\(item.title)"
                guard seen.insert(identity).inserted else { continue }
                shortcuts.append(
                    CatalogShortcut(
                        id: identity,
                        name: item.title,
                        detail: "应用专属菜单快捷键",
                        shortcut: item.shortcut
                    )
                )
            }
            guard remainingNodes > 0 else { break }
        }
        return shortcuts
    }

    private static func scanBranch(
        _ element: AXUIElement,
        remainingNodes: inout Int,
        items: inout [(title: String, shortcut: KeyCombination)]
    ) {
        guard remainingNodes > 0 else { return }
        remainingNodes -= 1

        if let shortcut = MenuShortcutReader.shortcut(from: element),
           let title = AXHelpers.string(element, attribute: kAXTitleAttribute as CFString),
           !title.isEmpty {
            items.append((title, shortcut))
        }

        for child in AXHelpers.elements(element, attribute: kAXChildrenAttribute as CFString) {
            scanBranch(
                child,
                remainingNodes: &remainingNodes,
                items: &items
            )
            guard remainingNodes > 0 else { break }
        }
    }
}

enum MenuShortcutReader {
    static func shortcut(from element: AXUIElement) -> KeyCombination? {
        let modifierNumber = AXHelpers.value(
            element,
            attribute: kAXMenuItemCmdModifiersAttribute as CFString
        ) as? NSNumber
        let rawModifiers = modifierNumber?.uint32Value ?? 0
        var modifiers: ShortcutModifiers = []
        if rawModifiers & (1 << 3) == 0 { modifiers.insert(.command) }
        if rawModifiers & (1 << 0) != 0 { modifiers.insert(.shift) }
        if rawModifiers & (1 << 1) != 0 { modifiers.insert(.option) }
        if rawModifiers & (1 << 2) != 0 { modifiers.insert(.control) }

        if let number = AXHelpers.value(
            element,
            attribute: kAXMenuItemCmdVirtualKeyAttribute as CFString
        ) as? NSNumber {
            return KeyCombination(keyCode: number.uint16Value, modifiers: modifiers)
        }
        guard let character = AXHelpers.string(
            element,
            attribute: kAXMenuItemCmdCharAttribute as CFString
        ), !character.isEmpty else { return nil }

        let normalized = character.uppercased()
        guard let keyCode = (UInt16(0)...UInt16(126)).first(where: {
            KeyCodeDisplay.name(for: $0) == normalized
        }) else { return nil }
        return KeyCombination(keyCode: keyCode, modifiers: modifiers)
    }
}

enum SystemShortcutCatalog {
    static let shortcuts: [CatalogShortcut] = [
        item("切换应用", keyCode: 48, modifiers: [.command]),
        item("聚焦搜索", keyCode: 49, modifiers: [.command]),
        item("Finder 搜索", keyCode: 49, modifiers: [.command, .option]),
        item("调度中心", keyCode: 126, modifiers: [.control]),
        item("应用程序窗口", keyCode: 125, modifiers: [.control]),
        item("切换到左侧空间", keyCode: 123, modifiers: [.control]),
        item("切换到右侧空间", keyCode: 124, modifiers: [.control]),
        item("截取整个屏幕", keyCode: 20, modifiers: [.command, .shift]),
        item("截取选定区域", keyCode: 21, modifiers: [.command, .shift]),
        item("截屏和录屏选项", keyCode: 23, modifiers: [.command, .shift]),
        item("锁定屏幕", keyCode: 12, modifiers: [.command, .control]),
        item("强制退出应用", keyCode: 53, modifiers: [.command, .option])
    ]

    static func label(for shortcut: KeyCombination) -> String? {
        shortcuts.first { $0.shortcut == shortcut }?.name
    }

    private static func item(
        _ name: String,
        keyCode: UInt16,
        modifiers: ShortcutModifiers
    ) -> CatalogShortcut {
        let shortcut = KeyCombination(keyCode: keyCode, modifiers: modifiers)
        return CatalogShortcut(
            id: "system|\(shortcut.displayString)|\(name)",
            name: name,
            detail: "macOS 系统快捷键",
            shortcut: shortcut
        )
    }
}
