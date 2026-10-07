// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import ShortcutCore
@testable import ShortcutsFeature

@Test @MainActor func configurationImportFailureKeepsFilesModelSelectionAndNotifications() throws {
    let original = Array(DefaultShortcutRules.make().prefix(2))
    try withIsolatedModel(original) { model, directory in
        model.flushSave()
        let rulesFile = directory.appendingPathComponent("shortcuts.json")
        let preferencesFile = directory.appendingPathComponent("preferences.json")
        let originalBytes = try Data(contentsOf: rulesFile)
        let priorPreferences = model.appPreferences
        let selected = model.selectedRuleID; let analysis = model.ruleAnalysis
        let archiveFile = directory.appendingPathComponent("import.json")
        let imported = KeyPilotConfigurationArchive(shortcuts: [], preferences: .init())
        try ShortcutConfigurationJSON.encode(imported).write(to: archiveFile)
        try FileManager.default.removeItem(at: preferencesFile)
        try FileManager.default.createDirectory(at: preferencesFile, withIntermediateDirectories: true)
        var notifications: [String] = []
        model.onExecutableRulesChanged = { _ in notifications.append("engine") }
        model.onAppPreferencesChanged = { _ in notifications.append("preferences") }
        model.onConflictScanRequested = { _ in notifications.append("scan") }
        model.importConfiguration(from: archiveFile)
        #expect(model.lastError?.hasPrefix("导入配置失败：") == true)
        #expect(model.rules == original && model.appPreferences == priorPreferences)
        #expect(model.selectedRuleID == selected && model.ruleAnalysis === analysis)
        #expect(notifications.isEmpty)
        #expect(try Data(contentsOf: rulesFile) == originalBytes)
        #expect(!FileManager.default.fileExists(atPath: rulesFile.path + ".aether-pair-journal"))
    }
}

@Test @MainActor func configurationImportRejectsPendingOldRulesAndPreferences() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AetherImportPending-" + UUID().uuidString)
    let domain = "AetherImportPending." + UUID().uuidString
    let defaults = UserDefaults(suiteName: domain)!
    defer { defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: directory) }
    let ruleStore = ShortcutRuleStore(fileURL: directory.appendingPathComponent("shortcuts.json"))
    let preferenceStore = AppPreferencesStore(fileURL: directory.appendingPathComponent("preferences.json"))
    let original = Array(DefaultShortcutRules.make().prefix(2))
    try ruleStore.save(original)
    defaults.set(DefaultShortcutRules.currentMigrationVersion, forKey: "defaultShortcutMigrationVersion")
    let model = AppModel(store: ruleStore, appPreferencesStore: preferenceStore, preferences: defaults)
    defer { model.flushSave() }
    var pending = original[0]; pending.name = "合成待保存旧规则"
    model.update(pending)
    model.updateAppPreferences { $0.app.showModifierButtons = false }
    let importedRules = Array(DefaultShortcutRules.make().suffix(1))
    var importedPreferences = AppPreferencesConfiguration(); importedPreferences.applicationShortcuts.holdDuration = 1.25
    let archive = KeyPilotConfigurationArchive(shortcuts: importedRules, preferences: importedPreferences)
    let file = directory.appendingPathComponent("import.json")
    try ShortcutConfigurationJSON.encode(archive).write(to: file)
    model.importConfiguration(from: file)
    try await Task.sleep(for: .milliseconds(500))
    #expect(model.lastError == nil)
    #expect(model.rules == importedRules && model.appPreferences == importedPreferences)
    #expect(try ruleStore.load() == importedRules)
    #expect(try preferenceStore.load() == importedPreferences)
}

@Test @MainActor func configurationStartupRecoversPartialPairAndProtectsUnknownJournal() throws {
    let originalRules = Array(DefaultShortcutRules.make().prefix(2))
    try withIsolatedModel(originalRules) { model, directory in
        model.flushSave()
        let ruleStore = ShortcutRuleStore(fileURL: directory.appendingPathComponent("shortcuts.json"))
        let preferenceStore = AppPreferencesStore(fileURL: directory.appendingPathComponent("preferences.json"))
        let paths = [ruleStore.fileURL, preferenceStore.fileURL]
        let old = try paths.map { try Data(contentsOf: $0) }
        let modes = try paths.map { (try FileManager.default.attributesOfItem(atPath: $0.path)[.posixPermissions] as! NSNumber).intValue }
        let newRules = Array(DefaultShortcutRules.make().suffix(1))
        var newPreferences = AppPreferencesConfiguration(); newPreferences.app.showModifierButtons = false
        let tempPreferences = directory.appendingPathComponent("synthetic-new-preferences.json")
        try AppPreferencesStore(fileURL: tempPreferences).save(newPreferences)
        let replacement = [try JSONEncoder().encode(newRules), try Data(contentsOf: tempPreferences)]
        let journal: [String: Any] = ["version": 1, "paths": paths.map(\.path), "original": (0..<2).map { ["File": ["bytes": [UInt8](old[$0]), "mode": modes[$0]]] }, "replacement": replacement.map { [UInt8]($0) }, "committed": false]
        let journalFile = URL(fileURLWithPath: ruleStore.fileURL.path + ".aether-pair-journal")
        try JSONSerialization.data(withJSONObject: journal).write(to: journalFile)
        try replacement[0].write(to: ruleStore.fileURL)
        let domain = "AetherRecoverModel." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(DefaultShortcutRules.currentMigrationVersion, forKey: "defaultShortcutMigrationVersion")
        let reopened = AppModel(store: ruleStore, appPreferencesStore: preferenceStore, preferences: defaults)
        #expect(reopened.lastError == nil)
        #expect(reopened.rules == originalRules && reopened.appPreferences == model.appPreferences)
        #expect(try paths.map { try Data(contentsOf: $0) } == old)
        #expect(!FileManager.default.fileExists(atPath: journalFile.path))
        let unknown = Data(#"{"version":999,"synthetic":"preserve"}"#.utf8)
        try unknown.write(to: journalFile)
        let blocked = AppModel(store: ruleStore, appPreferencesStore: preferenceStore, preferences: defaults)
        blocked.flushSave()
        #expect(blocked.lastError != nil)
        #expect(try paths.map { try Data(contentsOf: $0) } == old)
        #expect(try Data(contentsOf: journalFile) == unknown)
    }
}
