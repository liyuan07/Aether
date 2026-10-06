// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import ShortcutCore

@Test func rustShortcutPoliciesMatchOriginalSwiftAcrossGeneratedRules() {
    var seed: UInt64 = 7
    func next(_ limit: Int) -> Int {
        seed = seed &* 6364136223846793005 &+ 1
        return Int((seed >> 32) % UInt64(limit))
    }
    func key() -> KeyCombination {
        KeyCombination(keyCode: UInt16(next(8)), modifiers: ShortcutModifiers(rawValue: UInt8(next(16))),
            physicalModifiers: PhysicalModifierKeys(rawValue: UInt16(next(512))))
    }
    for _ in 0..<200 {
        let rules = (0..<40).map { _ in
            ShortcutRule(name: "合成规则", source: key(), action: next(3) == 0 ? .showDesktop : .remap(to: key()), isEnabled: next(4) != 0)
        }
        let actual = ShortcutRuleValidator.issues(in: rules)
        let expected = ReferenceShortcutRuleValidator.issues(in: rules)
        #expect(actual.count == expected.count)
        #expect(actual.allSatisfy { expected.contains($0) })
        for rule in rules {
            let event = ShortcutModifiers(rawValue: UInt8(next(16)))
            let physical = PhysicalModifierKeys(rawValue: UInt16(next(512)))
            let actual = ShortcutTriggerResolver.resolve(rule: rule, eventModifiers: event, activePhysicalModifiers: physical)
            let expected = ReferenceShortcutTriggerResolver.resolve(rule: rule, eventModifiers: event, activePhysicalModifiers: physical)
            #expect(actual?.action == expected?.action)
            #expect(actual?.isExactModifierMatch == expected?.isExactModifierMatch)
        }
    }
    // Include cycles and prefixes deliberately; random physical keys rarely collide.
    let a = KeyCombination(keyCode: 0, modifiers: .command)
    let b = KeyCombination(keyCode: 1, modifiers: .command)
    let c = KeyCombination(keyCode: 2, modifiers: .command)
    let cycle = [ShortcutRule(name: "a", source: a, action: .remap(to: b)),
        ShortcutRule(name: "b", source: b, action: .remap(to: a)),
        ShortcutRule(name: "c", source: c, action: .remap(to: a))]
    let expected = ReferenceShortcutRuleValidator.issues(in: cycle)
    let actual = ShortcutRuleValidator.issues(in: cycle)
    #expect(actual.count == expected.count)
    #expect(actual.allSatisfy { expected.contains($0) })
    let branches = [[7,8,9,0], [46,13,3], [46,123,124], [7,8], [6,7,8,9,0]]
    for branch in branches {
        for modifiers: UInt8 in 0..<16 {
            let keys = branch.map { KeyCombination(keyCode: UInt16($0), modifiers: .command) }
            for code: UInt16 in 0..<129 {
                let shortcut = KeyCombination(keyCode: code, modifiers: ShortcutModifiers(rawValue: modifiers))
                #expect(ApplicationMenuShortcutFilter.shouldInclude(shortcut, topLevelIndex: 2, branchShortcuts: keys)
                    == ReferenceApplicationMenuShortcutFilter.shouldInclude(shortcut, topLevelIndex: 2, branchShortcuts: keys))
            }
        }
    }
}



public enum ReferenceShortcutRuleValidator {
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

public enum ReferenceShortcutTriggerResolver {
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

public enum ReferenceApplicationMenuShortcutFilter {
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
