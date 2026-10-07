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
