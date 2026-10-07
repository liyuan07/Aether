// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import ShortcutCore

// Group/default/seed policy frozen from 6eeac41 AppModel. Ordering uses the independent original Swift implementation.
private func referenceCatalog(_ apps: [RegisteredApplication], _ prefs: ApplicationShortcutPreferences,
    _ legacy: [ApplicationTarget], _ rules: [ShortcutRule]) -> ([RegisteredApplicationGroup], [String: RegisteredApplication], [String: String]) {
    let groups = Set(apps.map(\.initial)).sorted().map { initial in
        RegisteredApplicationGroup(initial: initial, applications: OriginalOrder.ordered(apps.filter { $0.initial == initial },
            preferredBundleIdentifiers: prefs.orderedBundleIdentifiers[initial] ?? []))
    }
    var defaults: [String: RegisteredApplication] = [:], additions: [String: String] = [:]
    for group in groups {
        if group.applications.count == 1 { defaults[group.initial] = group.applications[0] }
        else if let bundle = prefs.defaultBundleIdentifiers[group.initial] {
            defaults[group.initial] = group.applications.first { $0.bundleIdentifier == bundle }
        }
    }
    for group in groups.filter({ $0.applications.count > 1 }) where prefs.defaultBundleIdentifiers[group.initial] == nil {
        let configuredTargets = legacy + rules.compactMap { rule -> ApplicationTarget? in
            guard rule.isEnabled, case let .application(target, _) = rule.action else { return nil }
            return target
        }
        guard let target = configuredTargets.first(where: { target in
            group.applications.contains { $0.bundleIdentifier == target.bundleIdentifier || $0.applicationPath == target.applicationPath }
        }), let app = group.applications.first(where: { $0.bundleIdentifier == target.bundleIdentifier || $0.applicationPath == target.applicationPath }) else { continue }
        additions[group.initial] = app.bundleIdentifier
    }
    return (groups, defaults, additions)
}
private func rawApps(_ apps: [RegisteredApplication]) -> [[[UInt8]]] {
    apps.map { [$0.initial, $0.bundleIdentifier, $0.displayName, $0.applicationPath].map { Array($0.utf8) } }
}

@Test("Rust 应用目录与独立旧策略保留分组、默认值、种子优先级及完整字段")
func applicationCatalogParity() {
    var seed: UInt64 = 725
    func next(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1; return Int((seed >> 32) % UInt64(n)) }
    let strings = ["", "A", "a", "É", "E\u{301}", "合成", "missing", "x\0y"]
    for _ in 0..<2000 {
        let apps = (0..<next(30)).map { index in RegisteredApplication(bundleIdentifier: strings[next(strings.count)], displayName: "合成 \(index)",
            applicationPath: strings[next(strings.count)], initial: strings[next(strings.count)]) }
        var prefs = ApplicationShortcutPreferences()
        for initial in strings where next(3) == 0 {
            prefs.defaultBundleIdentifiers[initial] = strings[next(strings.count)]
            prefs.orderedBundleIdentifiers[initial] = (0..<next(10)).map { _ in strings[next(strings.count)] }
        }
        func target() -> ApplicationTarget { .init(displayName: "合成", bundleIdentifier: next(4) == 0 ? nil : strings[next(strings.count)], applicationPath: strings[next(strings.count)]) }
        let legacy = (0..<next(8)).map { _ in target() }
        let rules = (0..<next(12)).map { _ in ShortcutRule(name: "合成", source: .init(keyCode: 1, modifiers: .command),
            action: next(3) == 0 ? .showDesktop : .application(target: target(), mode: .activateExisting), isEnabled: next(2) == 0) }
        let expected = referenceCatalog(apps, prefs, legacy, rules)
        let catalog = ApplicationCatalog(applications: apps, preferences: prefs, legacyTargets: legacy, rules: rules)
        #expect(catalog.groups == expected.0)
        #expect(catalog.groups.map { rawApps($0.applications) } == expected.0.map { rawApps($0.applications) })
        #expect(catalog.seedAdditions == expected.2)
        for initial in strings + ["absent"] {
            #expect(rawApps(catalog.applications(for: initial)) == rawApps(expected.0.first { $0.initial == initial }?.applications ?? []))
            #expect(catalog.defaultApplication(for: initial) == expected.1[initial])
        }
    }
}

@Test("不可变应用目录不受来源修改影响且可并发读取")
func applicationCatalogSnapshotLifetime() async {
    var apps = [RegisteredApplication(bundleIdentifier: "one", displayName: "一", applicationPath: "/one", initial: "A")]
    let catalog = ApplicationCatalog(applications: apps, preferences: .init(), legacyTargets: [], rules: [])
    apps[0].displayName = "修改"; apps.removeAll()
    await withTaskGroup(of: Bool.self) { tasks in
        for _ in 0..<256 { tasks.addTask { catalog.defaultApplication(for: "A")?.displayName == "一" && catalog.applications(for: "A").count == 1 } }
        for await result in tasks { #expect(result) }
    }
}
