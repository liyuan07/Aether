import Foundation

/// Carbon shortcuts cannot distinguish left/right physical modifiers. Reserve a
/// built-in combination when any enabled user rule can consume the same key.
public enum ShortcutRegistrationPolicy {
    public static func userRulesClaim(_ combination: KeyCombination, rules: [ShortcutRule]) -> Bool {
        rules.contains { rule in
            let effectiveModifiers = rule.source.modifiers.union(rule.source.physicalModifiers.logicalModifiers)
            return rule.isEnabled && rule.source.keyCode == combination.keyCode && effectiveModifiers == combination.modifiers
        }
    }
}
