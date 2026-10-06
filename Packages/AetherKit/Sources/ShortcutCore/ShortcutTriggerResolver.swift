import CAetherCore

public struct ResolvedShortcutTrigger: Sendable {
    public let action: ShortcutAction
    public let isExactModifierMatch: Bool

    public init(action: ShortcutAction, isExactModifierMatch: Bool) {
        self.action = action
        self.isExactModifierMatch = isExactModifierMatch
    }
}

public enum ShortcutTriggerResolver {
    public static func resolve(
        rule: ShortcutRule,
        eventModifiers: ShortcutModifiers,
        activePhysicalModifiers: PhysicalModifierKeys
    ) -> ResolvedShortcutTrigger? {
        let target: KeyCombination?
        if case let .remap(value) = rule.action { target = value } else { target = nil }
        let match = aether_shortcut_resolve(rule.source.modifiers.rawValue, eventModifiers.rawValue,
            rule.source.physicalModifiers.rawValue, activePhysicalModifiers.rawValue, target == nil ? 0 : 1)
        switch match {
        case 1: return ResolvedShortcutTrigger(action: rule.action, isExactModifierMatch: true)
        case 2:
            guard let target else { return nil }
            return ResolvedShortcutTrigger(action: .remap(to: KeyCombination(keyCode: target.keyCode,
                modifiers: target.modifiers.union(.shift), physicalModifiers: target.physicalModifiers)), isExactModifierMatch: false)
        default: return nil
        }
    }
}
