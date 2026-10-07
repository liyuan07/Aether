import Foundation
import CAetherCore

public enum ShortcutRuleIssue: Equatable, Sendable {
    case missingModifier(ruleID: UUID)
    case duplicateShortcut(ruleIDs: Set<UUID>, shortcut: KeyCombination)
    case remapCycle(ruleIDs: Set<UUID>)

    public var affectedRuleIDs: Set<UUID> {
        switch self {
        case let .missingModifier(ruleID): [ruleID]
        case let .duplicateShortcut(ruleIDs, _): ruleIDs
        case let .remapCycle(ruleIDs): ruleIDs
        }
    }
}

public enum ShortcutRuleValidator {
    public static func issues(in rules: [ShortcutRule]) -> [ShortcutRuleIssue] {
        let core = rules.map(\.rustRule)
        let result = core.withUnsafeBufferPointer { aether_shortcut_validate($0.baseAddress, $0.count) }
        defer { aether_validation_destroy(result) }
        return decode(result, rules: rules)
    }

    static func decode(_ result: UnsafeMutableRawPointer?, rules: [ShortcutRule]) -> [ShortcutRuleIssue] {
        var issues: [ShortcutRuleIssue] = []
        var cycles = Set<Set<UUID>>()
        for index in 0..<aether_validation_count(result) {
            let issue = aether_validation_issue(result, index)
            let ids = Set(UnsafeBufferPointer(start: issue.members, count: issue.count).map { rules[$0].id })
            switch issue.kind {
            case 0: issues.append(.missingModifier(ruleID: rules[issue.source].id))
            case 1: issues.append(.duplicateShortcut(ruleIDs: ids, shortcut: rules[issue.source].source))
            case 2: cycles.insert(ids)
            default: break
            }
        }
        issues.append(contentsOf: cycles.map(ShortcutRuleIssue.remapCycle(ruleIDs:)))
        return issues
    }
}
