// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Dispatch
import Testing
import ShortcutCore
@testable import ShortcutsFeature

@MainActor
private func withIsolatedModel(_ rules: [ShortcutRule], _ body: (AppModel, URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AetherShortcutAnalysis-" + UUID().uuidString)
    let domain = "AetherShortcutAnalysis." + UUID().uuidString
    let defaults = UserDefaults(suiteName: domain)!
    let store = ShortcutRuleStore(fileURL: directory.appendingPathComponent("shortcuts.json"))
    try store.save(rules)
    defaults.set(DefaultShortcutRules.currentMigrationVersion, forKey: "defaultShortcutMigrationVersion")
    let model = AppModel(store: store, appPreferencesStore: .init(fileURL: directory.appendingPathComponent("preferences.json")),
        preferences: defaults)
    defer {
        model.flushSave()
        defaults.removePersistentDomain(forName: domain)
        try? FileManager.default.removeItem(at: directory)
    }
    try body(model, directory)
}

@Test("实际模型复用校验快照，权限和录制状态正确控制执行")
@MainActor func shortcutModelCachesAnalysisAndTracksPermission() throws {
    let physical = ShortcutRule(name: "合成物理规则", source: .init(keyCode: 1, modifiers: .command, physicalModifiers: .capsLock), action: .showDesktop)
    let ordinary = ShortcutRule(name: "合成普通规则", source: .init(keyCode: 2, modifiers: .command), action: .showDesktop)
    try withIsolatedModel([physical, ordinary]) { model, _ in
        let analysis = model.ruleAnalysis
        #expect(model.ruleAnalysis === analysis)
        #expect(model.executableRuleIDs == [ordinary.id])
        #expect(model.localFindings(for: physical.id).map(\.message) == ["物理修饰键组合需要开启输入监控权限"])
        var received: [[ShortcutRule]] = []
        model.onExecutableRulesChanged = { received.append($0) }
        model.notifyEngine()
        #expect(received.last == [])
        model.permissionGranted = true; model.notifyEngine()
        #expect(received.last == [ordinary])
        model.inputMonitoringGranted = true
        #expect(model.executableRuleIDs == [physical.id, ordinary.id])
        #expect(model.localFindings(for: physical.id).isEmpty)
        model.notifyEngine(); #expect(received.last == [physical, ordinary])
        model.setShortcutRecording(true); #expect(received.last == [])
        model.setShortcutRecording(false); #expect(received.last == [physical, ordinary])
        model.inputMonitoringGranted = false
        #expect(model.executableRuleIDs == [ordinary.id])
        #expect(model.ruleAnalysis === analysis)
    }
}

@Test("实际模型在编辑、重排、添加、删除及导入后立即丢弃旧校验")
@MainActor func shortcutModelInvalidatesAllRuleMutationPaths() throws {
    let first = ShortcutRule(name: "合成一", source: .init(keyCode: 1, modifiers: .command), action: .showDesktop)
    let second = ShortcutRule(name: "合成二", source: .init(keyCode: 2, modifiers: .command), action: .showDesktop)
    try withIsolatedModel([first, second]) { model, directory in
        model.permissionGranted = true; model.inputMonitoringGranted = true
        var snapshot = model.ruleAnalysis
        var changed = second; changed.source = first.source
        model.update(changed)
        #expect(model.ruleAnalysis !== snapshot)
        #expect(model.executableRuleIDs.isEmpty)
        #expect(model.localFindings(for: first.id).contains { $0.message.contains("合成二") })
        snapshot = model.ruleAnalysis
        changed.name = "合成重命名"; model.update(changed)
        #expect(model.ruleAnalysis !== snapshot)
        #expect(model.localFindings(for: first.id).contains { $0.message.contains("合成重命名") })
        snapshot = model.ruleAnalysis
        model.setEnabled(false, for: second.id)
        #expect(model.ruleAnalysis !== snapshot)
        #expect(model.executableRuleIDs == [first.id])
        snapshot = model.ruleAnalysis
        model.moveRules(fromOffsets: IndexSet(integer: 0), toOffset: 2)
        #expect(model.ruleAnalysis !== snapshot)
        #expect(model.rules.map(\.id) == [second.id, first.id])
        snapshot = model.ruleAnalysis
        let added = model.addRule()
        #expect(model.ruleAnalysis !== snapshot)
        #expect(model.selectedRuleID == added)
        #expect(model.executableRuleIDs == [first.id])
        snapshot = model.ruleAnalysis
        model.removeRule(id: first.id)
        #expect(model.ruleAnalysis !== snapshot)
        #expect(model.executableRuleIDs.isEmpty)
        let imported = [first, second]
        let file = directory.appendingPathComponent("synthetic-import.json")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(KeyPilotConfigurationArchive(shortcuts: imported, preferences: model.appPreferences)).write(to: file)
        snapshot = model.ruleAnalysis
        model.importConfiguration(from: file)
        #expect(model.ruleAnalysis !== snapshot)
        #expect(model.rules == imported)
        #expect(model.selectedRuleID == first.id)
        #expect(model.executableRuleIDs == Set(imported.map(\.id)))
        snapshot = model.ruleAnalysis
        // Archive.encode deliberately writes the current version, so construct the
        // unsupported on-disk fixture after encoding rather than mutating the DTO.
        let future = KeyPilotConfigurationArchive(shortcuts: [], preferences: model.appPreferences)
        var payload = try JSONSerialization.jsonObject(with: encoder.encode(future)) as! [String: Any]
        payload["schemaVersion"] = Int.max
        try JSONSerialization.data(withJSONObject: payload).write(to: file)
        model.importConfiguration(from: file)
        #expect(model.ruleAnalysis === snapshot)
        #expect(model.rules == imported)
        #expect(model.executableRuleIDs == Set(imported.map(\.id)))
    }
}

@Test("合成规则列表重复读取基准，仅显式启用 Release 时运行")
@MainActor func shortcutAnalysisReadBenchmark() throws {
    guard ProcessInfo.processInfo.environment["AETHER_RUN_CORE_BENCHMARKS"] == "1" else { return }
    guard !_isDebugAssertConfiguration() else { Issue.record("Benchmark requires Release"); return }
    let rules = (0..<500).map { ShortcutRule(name: "合成规则 \($0)",
        source: .init(keyCode: UInt16($0), modifiers: .command), action: .showDesktop) }
    try withIsolatedModel(rules) { model, _ in
        // Old AppModel paths for this valid, physical-modifier-free fixture. Both
        // validation calls, UUID-set construction and native rule lookup are included.
        func oldRead() -> Int {
            var checksum = 0
            for _ in 0..<3 {
                for rule in rules {
                    let invalid = Set(ShortcutRuleValidator.issues(in: rules).flatMap(\.affectedRuleIDs))
                    let ids = Set(rules.compactMap { candidate -> UUID? in
                        guard candidate.isEnabled, !invalid.contains(candidate.id),
                              candidate.source.physicalModifiers.isEmpty else { return nil }
                        return candidate.id
                    })
                    let localCount = ShortcutRuleValidator.issues(in: rules).filter { $0.affectedRuleIDs.contains(rule.id) }.count
                    let physicalCount = rules.first { $0.id == rule.id }.map { $0.source.physicalModifiers.isEmpty ? 0 : 1 } ?? 0
                    checksum += ids.count + localCount + physicalCount
                }
            }
            return checksum
        }
        @MainActor func newRead() -> Int {
            var checksum = 0
            for _ in 0..<3 {
                for rule in rules { checksum += model.executableRuleIDs.count + model.localFindings(for: rule.id).count }
            }
            return checksum
        }
        #expect(oldRead() == newRead()) // warm both paths; this measures subsequent UI reads
        var old: [UInt64] = []; var current: [UInt64] = []
        @MainActor func measure(_ body: @MainActor () -> Int) -> UInt64 {
            let start = DispatchTime.now().uptimeNanoseconds
            let checksum = body()
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            #expect(checksum == 750000)
            return elapsed
        }
        for round in 0..<7 {
            if round.isMultiple(of: 2) { old.append(measure(oldRead)); current.append(measure(newRead)) }
            else { current.append(measure(newRead)); old.append(measure(oldRead)) }
        }
        let output: [String: Any] = ["fixtureRules": rules.count, "listPasses": 3,
            "rounds": 7, "oldNs": old, "currentNs": current,
            "oldMedianNs": old.sorted()[3], "currentMedianNs": current.sorted()[3],
            "scope": "steady valid synthetic rule-list model reads; excludes rendering, startup, persistence, process resources"]
        print("SHORTCUT_ANALYSIS_BENCHMARK " + String(decoding: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), as: UTF8.self))
    }
}

@Test("实际模型缓存应用目录，注册/规则/排序/默认值更新立即失效")
@MainActor func applicationCatalogModelInvalidation() throws {
    let target = ApplicationTarget(displayName: "旧目标", bundleIdentifier: "two", applicationPath: "/two")
    let legacy = ShortcutRule(name: "合成旧规则", source: .init(keyCode: 1, modifiers: .command),
        action: .application(target: target, mode: .activateExisting), isEnabled: false)
    try withIsolatedModel([legacy]) { model, directory in
        let apps = [RegisteredApplication(bundleIdentifier: "one", displayName: "一", applicationPath: "/one", initial: "A"),
            RegisteredApplication(bundleIdentifier: "two", displayName: "二", applicationPath: "/two", initial: "A")]
        model.setRegisteredApplications(apps)
        // Disabled persisted legacy targets retain their original seed priority.
        #expect(model.appPreferences.applicationShortcuts.defaultBundleIdentifiers["A"] == "two")
        #expect(model.defaultApplication(for: "A") == apps[1])
        var snapshot = model.applicationCatalog
        #expect(model.applicationCatalog === snapshot)
        model.updateAppPreferences { $0.app.showModifierButtons.toggle() }
        #expect(model.applicationCatalog === snapshot)
        model.moveApplications(for: "A", fromOffsets: [1], toOffset: 0)
        #expect(model.applicationCatalog !== snapshot)
        #expect(model.applications(for: "A") == apps.reversed())
        #expect(snapshot.applications(for: "A") == apps)
        snapshot = model.applicationCatalog
        model.setDefaultApplication(bundleIdentifier: "one", for: "A")
        #expect(model.applicationCatalog !== snapshot)
        #expect(model.defaultApplication(for: "A") == apps[0])
        snapshot = model.applicationCatalog
        var changed = legacy; changed.name = "改名"; model.update(changed)
        #expect(model.applicationCatalog !== snapshot)
        snapshot = model.applicationCatalog
        model.setRegisteredApplications([apps[1]])
        #expect(model.applicationCatalog !== snapshot)
        #expect(model.defaultApplication(for: "A") == apps[1]) // Singleton overrides a stale explicit default.
        #expect(model.registeredApplicationGroups.count == 1)
        #expect(model.applications(for: "unknown").isEmpty)
        snapshot = model.applicationCatalog
        var importedPreferences = model.appPreferences
        importedPreferences.applicationShortcuts.defaultBundleIdentifiers["A"] = "two"
        let archive = KeyPilotConfigurationArchive(shortcuts: [legacy], preferences: importedPreferences)
        let file = directory.appendingPathComponent("catalog-import.json")
        try JSONEncoder().encode(archive).write(to: file)
        model.importConfiguration(from: file)
        #expect(model.applicationCatalog !== snapshot)
        #expect(model.appPreferences.applicationShortcuts.defaultBundleIdentifiers["A"] == "two")
        snapshot = model.applicationCatalog
        let added = model.addRule()
        #expect(model.applicationCatalog !== snapshot)
        snapshot = model.applicationCatalog
        model.removeRule(id: added)
        #expect(model.applicationCatalog !== snapshot)
    }
}

@Test("合成应用分组重复读取基准，仅显式启用 Release 时运行")
@MainActor func applicationCatalogReadBenchmark() throws {
    guard ProcessInfo.processInfo.environment["AETHER_RUN_CORE_BENCHMARKS"] == "1" else { return }
    guard !_isDebugAssertConfiguration() else { Issue.record("Benchmark requires Release"); return }
    let rules = [ShortcutRule(name: "合成规则", source: .init(keyCode: 1, modifiers: .command), action: .showDesktop)]
    try withIsolatedModel(rules) { model, _ in
        let apps = (0..<1000).map { i in RegisteredApplication(bundleIdentifier: "synthetic.\(i)", displayName: "合成 \(i)",
            applicationPath: "/synthetic/\(i).app", initial: String(UnicodeScalar(65 + i % 26)!)) }
        model.setRegisteredApplications(apps)
        model.updateAppPreferences { configuration in
            for initial in Set(apps.map(\.initial)) {
                let identifiers = apps.filter { $0.initial == initial }.map(\.bundleIdentifier).reversed()
                configuration.applicationShortcuts.orderedBundleIdentifiers[initial] = Array(identifiers)
                configuration.applicationShortcuts.defaultBundleIdentifiers[initial] = identifiers.first
            }
        }
        let prefs = model.appPreferences.applicationShortcuts
        // Frozen AppModel read flow; ordering deliberately uses the same pre-existing Rust resolver.
        func oldGroups() -> [RegisteredApplicationGroup] {
            Set(apps.map(\.initial)).sorted().map { initial in
                .init(initial: initial, applications: ApplicationOrderResolver.ordered(apps.filter { $0.initial == initial },
                    preferredBundleIdentifiers: prefs.orderedBundleIdentifiers[initial] ?? []))
            }
        }
        func oldDefault(_ initial: String) -> RegisteredApplication? {
            let rows = ApplicationOrderResolver.ordered(apps.filter { $0.initial == initial },
                preferredBundleIdentifiers: prefs.orderedBundleIdentifiers[initial] ?? [])
            if rows.count == 1 { return rows[0] }
            guard let bundle = prefs.defaultBundleIdentifiers[initial] else { return nil }
            return rows.first { $0.bundleIdentifier == bundle }
        }
        #expect(oldGroups() == model.registeredApplicationGroups)
        for group in oldGroups() { #expect(oldDefault(group.initial) == model.defaultApplication(for: group.initial)) }
        func oldRead() -> Int {
            var checksum = 0
            for _ in 0..<20 { for group in oldGroups() {
                checksum += group.applications.count
                if oldDefault(group.initial) != nil { checksum += 1 }
            } }
            return checksum
        }
        @MainActor func newRead() -> Int {
            var checksum = 0
            for _ in 0..<20 { for group in model.registeredApplicationGroups {
                checksum += group.applications.count
                if model.defaultApplication(for: group.initial) != nil { checksum += 1 }
            } }
            return checksum
        }
        var old: [UInt64] = [], current: [UInt64] = []
        @MainActor func measure(_ read: @MainActor () -> Int) -> UInt64 {
            let start = DispatchTime.now().uptimeNanoseconds
            let checksum = read()
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            #expect(checksum == 20520)
            return elapsed
        }
        for round in 0..<7 {
            if round.isMultiple(of: 2) { old.append(measure(oldRead)); current.append(measure(newRead)) }
            else { current.append(measure(newRead)); old.append(measure(oldRead)) }
        }
        let output: [String: Any] = ["fixtureApplications": apps.count, "groups": 26, "passes": 20, "rounds": 7,
            "oldNs": old, "currentNs": current, "oldMedianNs": old.sorted()[3], "currentMedianNs": current.sorted()[3],
            "scope": "steady synthetic application-group and default model reads; excludes rendering, scanning, initial catalog, persistence and process resources"]
        print("APPLICATION_CATALOG_BENCHMARK " + String(decoding: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), as: UTF8.self))
    }
}

@Test("实际规则编辑保持通知、删除选择、重复身份和无效重排行为")
@MainActor func shortcutRuleEditIntegration() throws {
    let first = ShortcutRule(name: "一", source: .init(keyCode: 1, modifiers: .command), action: .showDesktop)
    var duplicate = first; duplicate.name = "重复"; duplicate.isEnabled = false
    let last = ShortcutRule(name: "尾", source: .init(keyCode: 2, modifiers: .command), action: .showDesktop)
    try withIsolatedModel([first, duplicate, last]) { model, directory in
        var notifications = 0, scans = 0
        model.onExecutableRulesChanged = { _ in notifications += 1 }
        model.onConflictScanRequested = { _ in scans += 1 }
        var index = model.ruleIndex
        #expect(model.rule(withID: first.id) == first)
        #expect(model.ruleIndex === index)
        #expect(model.rule(withID: nil) == nil)
        var renamed = first; renamed.name = "改名"; renamed.action = .finderFolder(path: "/synthetic")
        model.update(renamed)
        #expect(model.ruleIndex !== index)
        #expect(model.rules == [renamed, duplicate, last])
        #expect(notifications == 1 && scans == 0)
        index = model.ruleIndex
        model.update(.init(name: "未找到", source: first.source, action: .showDesktop))
        #expect(model.ruleIndex === index)
        #expect(notifications == 1 && scans == 0)
        model.setEnabled(false, for: first.id)
        #expect(notifications == 2 && scans == 1)
        #expect(model.rules[0].isEnabled == false)
        model.moveRules(fromOffsets: [2], toOffset: 0)
        #expect(model.rules.map(\.name) == ["尾", "改名", "重复"])
        #expect(notifications == 2 && scans == 1) // Reordering only schedules persistence.
        index = model.ruleIndex
        for (offsets, destination) in [(IndexSet(), 0), (IndexSet(integer: 3), 0), (IndexSet(integer: 0), -1), (IndexSet(integer: 0), Int.max)] {
            model.moveRules(fromOffsets: offsets, toOffset: destination)
            #expect(model.ruleIndex === index)
        }
        model.selectedRuleID = last.id
        model.finishConflictScan([first.id: [.init(confidence: .confirmed, message: "合成冲突")]])
        model.removeRule(id: first.id)
        #expect(model.rules == [last, duplicate])
        #expect(model.selectedRuleID == duplicate.id)
        #expect(model.externalConflicts[first.id] == nil)
        #expect(notifications == 3 && scans == 2)
        #expect(model.rule(withID: first.id) == duplicate)
        model.removeRule(id: first.id)
        #expect(model.selectedRuleID == last.id)
        model.removeRule(id: last.id)
        #expect(model.rules.isEmpty && model.selectedRuleID == nil)
        index = model.ruleIndex
        model.removeRule(id: last.id)
        #expect(model.ruleIndex === index)
        let id = model.addRule()
        #expect(model.selectedRuleID == id)
        #expect(model.rules.count == 1 && model.rules[0].id == id && !model.rules[0].isEnabled)
        model.flushSave()
        let persisted = try ShortcutRuleStore(fileURL: directory.appendingPathComponent("shortcuts.json")).load()
        #expect(persisted == model.rules)
        index = model.ruleIndex
        let imported = KeyPilotConfigurationArchive(shortcuts: [duplicate, last], preferences: model.appPreferences)
        let file = directory.appendingPathComponent("rule-edit-import.json")
        try JSONEncoder().encode(imported).write(to: file)
        model.importConfiguration(from: file)
        #expect(model.ruleIndex !== index)
        #expect(model.rule(withID: duplicate.id) == duplicate)
        #expect(model.rules == [duplicate, last])
        index = model.ruleIndex
        model.moveRules(fromOffsets: [0], toOffset: 1) // Valid identity move still publishes/saves.
        #expect(model.ruleIndex !== index)
        #expect(model.rules == [duplicate, last])
    }
}
