import AppKit
import ApplicationServices
import Carbon.HIToolbox
import ShortcutCore

final class ConflictScanner {
    static let shared = ConflictScanner()
    private let scanQueue = DispatchQueue(label: "com.liyuan.keypilot.conflict-scan", qos: .utility)

    func scan(rules: [ShortcutRule], completion: @escaping ([UUID: [ConflictFinding]]) -> Void) {
        var initial = [UUID: [ConflictFinding]]()
        for rule in rules {
            if let label = SystemShortcutCatalog.label(for: rule.source) {
                initial[rule.id, default: []].append(
                    ConflictFinding(confidence: .likely, message: "可能与系统快捷键“\(label)”冲突")
                )
            }
            if Self.hasExclusiveRegistrationConflict(rule.source) {
                initial[rule.id, default: []].append(
                    ConflictFinding(
                        confidence: .confirmed,
                        message: "其他进程已排他注册此全局快捷键（macOS 未提供进程名称）"
                    )
                )
            }
        }

        guard AccessibilityPermission.isGranted else {
            completion(initial)
            return
        }

        let candidates = rules.map { ($0.id, $0.source) }
        scanQueue.async {
            let menuFindings = Self.scanRunningApplicationMenus(candidates: candidates)
            DispatchQueue.main.async {
                var result = initial
                for (id, findings) in menuFindings {
                    result[id, default: []].append(contentsOf: findings)
                }
                completion(result)
            }
        }
    }

    private static func hasExclusiveRegistrationConflict(_ shortcut: KeyCombination) -> Bool {
        guard shortcut.physicalModifiers.isEmpty else { return false }
        var reference: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: OSType(0x4B_50_4C_54), id: UInt32(shortcut.keyCode))
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode),
            shortcut.modifiers.carbonModifiers,
            identifier,
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive),
            &reference
        )
        if let reference { UnregisterEventHotKey(reference) }
        return status == eventHotKeyExistsErr
    }

    private static func scanRunningApplicationMenus(
        candidates: [(id: UUID, shortcut: KeyCombination)]
    ) -> [UUID: [ConflictFinding]] {
        var result = [UUID: [ConflictFinding]]()
        let applications = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular
                && $0.bundleIdentifier != Bundle.main.bundleIdentifier
                && !$0.isTerminated
        }

        for application in applications {
            let appElement = AXUIElementCreateApplication(application.processIdentifier)
            guard let menuBarValue = AXHelpers.value(appElement, attribute: kAXMenuBarAttribute as CFString) else { continue }
            let menuBar = unsafeBitCast(menuBarValue, to: AXUIElement.self)
            var remainingNodes = 3_000
            scanMenuElement(
                menuBar,
                applicationName: application.localizedName ?? application.bundleIdentifier ?? "未知应用",
                candidates: candidates,
                result: &result,
                remainingNodes: &remainingNodes
            )
        }
        return result
    }

    private static func scanMenuElement(
        _ element: AXUIElement,
        applicationName: String,
        candidates: [(id: UUID, shortcut: KeyCombination)],
        result: inout [UUID: [ConflictFinding]],
        remainingNodes: inout Int
    ) {
        guard remainingNodes > 0 else { return }
        remainingNodes -= 1

        if let menuShortcut = MenuShortcutReader.shortcut(from: element) {
            let title = AXHelpers.string(element, attribute: kAXTitleAttribute as CFString) ?? "未命名菜单项"
            for candidate in candidates where candidate.shortcut == menuShortcut {
                let message = "\(applicationName) 菜单“\(title)”使用了 \(menuShortcut.displayString)"
                if result[candidate.id, default: []].contains(where: { $0.message == message }) == false {
                    result[candidate.id, default: []].append(
                        ConflictFinding(confidence: .possible, message: message)
                    )
                }
            }
        }

        for child in AXHelpers.elements(element, attribute: kAXChildrenAttribute as CFString) {
            scanMenuElement(
                child,
                applicationName: applicationName,
                candidates: candidates,
                result: &result,
                remainingNodes: &remainingNodes
            )
            guard remainingNodes > 0 else { break }
        }
    }

}

private extension ShortcutModifiers {
    var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        if contains(.command) { result |= UInt32(cmdKey) }
        if contains(.option) { result |= UInt32(optionKey) }
        if contains(.shift) { result |= UInt32(shiftKey) }
        if contains(.control) { result |= UInt32(controlKey) }
        return result
    }
}
