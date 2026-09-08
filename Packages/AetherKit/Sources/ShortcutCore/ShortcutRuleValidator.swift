import Foundation

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
        let enabledRules = rules.filter(\.isEnabled)
        var issues = enabledRules.compactMap { rule in
            rule.source.isValidTrigger ? nil : ShortcutRuleIssue.missingModifier(ruleID: rule.id)
        }

        let groups = Dictionary(grouping: enabledRules, by: \.source)
        for (shortcut, duplicates) in groups where duplicates.count > 1 {
            issues.append(.duplicateShortcut(ruleIDs: Set(duplicates.map(\.id)), shortcut: shortcut))
        }

        issues.append(contentsOf: remapCycleIssues(in: enabledRules))
        return issues
    }

    private static func remapCycleIssues(in rules: [ShortcutRule]) -> [ShortcutRuleIssue] {
        var remaps: [KeyCombination: (target: KeyCombination, id: UUID)] = [:]
        for rule in rules {
            guard case let .remap(target) = rule.action, remaps[rule.source] == nil else { continue }
            remaps[rule.source] = (target, rule.id)
        }

        var reportedRuleSets = Set<Set<UUID>>()
        for source in remaps.keys {
            var visited: [KeyCombination: UUID] = [:]
            var cursor = source

            while let edge = remaps[cursor] {
                if let firstRuleID = visited[cursor] {
                    let cycleIDs = Set(visited.values).union([firstRuleID, edge.id])
                    reportedRuleSets.insert(cycleIDs)
                    break
                }
                visited[cursor] = edge.id
                cursor = edge.target
            }
        }

        return reportedRuleSets.map(ShortcutRuleIssue.remapCycle(ruleIDs:))
    }
}
