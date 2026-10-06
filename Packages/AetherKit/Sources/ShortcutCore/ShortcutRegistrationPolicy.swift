import Foundation
import CAetherCore

/// Carbon shortcuts cannot distinguish left/right physical modifiers. Reserve a
/// built-in combination when any enabled user rule can consume the same key.
public enum ShortcutRegistrationPolicy {
    public static func userRulesClaim(_ combination: KeyCombination, rules: [ShortcutRule]) -> Bool {
        let core = rules.map(\.rustRule)
        return core.withUnsafeBufferPointer {
            aether_shortcut_claims(combination.rustKey, $0.baseAddress, $0.count) != 0
        }
    }
}
