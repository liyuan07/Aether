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
        guard activePhysicalModifiers.intersection(rule.source.physicalModifiers)
                == rule.source.physicalModifiers
        else { return nil }

        let normalizedModifiers = normalizedModifierPair(
            required: rule.source.modifiers,
            event: eventModifiers,
            requiredPhysicalModifiers: rule.source.physicalModifiers
        )

        if normalizedModifiers.required == normalizedModifiers.event {
            return ResolvedShortcutTrigger(
                action: rule.action,
                isExactModifierMatch: true
            )
        }

        guard case let .remap(target) = rule.action,
              !normalizedModifiers.required.contains(.shift),
              normalizedModifiers.event == normalizedModifiers.required.union(.shift)
        else { return nil }

        let shiftedTarget = KeyCombination(
            keyCode: target.keyCode,
            modifiers: target.modifiers.union(.shift),
            physicalModifiers: target.physicalModifiers
        )
        return ResolvedShortcutTrigger(
            action: .remap(to: shiftedTarget),
            isExactModifierMatch: false
        )
    }

    private static func normalizedModifierPair(
        required: ShortcutModifiers,
        event: ShortcutModifiers,
        requiredPhysicalModifiers: PhysicalModifierKeys
    ) -> (required: ShortcutModifiers, event: ShortcutModifiers) {
        guard requiredPhysicalModifiers.contains(.capsLock),
              requiredPhysicalModifiers.intersection([.leftCommand, .rightCommand]).isEmpty
        else { return (required, event) }
        return (required.subtracting(.command), event.subtracting(.command))
    }
}
