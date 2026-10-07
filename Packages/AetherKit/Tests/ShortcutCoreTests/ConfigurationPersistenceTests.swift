// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import ShortcutCore

@Test func configurationPersistencePairsReopenAndRejectStaleSnapshots() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AetherPair-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let rules = ShortcutRuleStore(fileURL: root.appendingPathComponent("规则.json"))
    let preferences = AppPreferencesStore(fileURL: root.appendingPathComponent("other/偏好.json"))
    let persistence = ShortcutConfigurationPersistence(rules: rules, preferences: preferences)
    try persistence.recover()
    let oldGeneration = persistence.reserveRulesSave()
    let oldPreferenceGeneration = persistence.reservePreferencesSave()
    let importedRules = Array(DefaultShortcutRules.make().prefix(3))
    var importedPreferences = AppPreferencesConfiguration()
    importedPreferences.app.showModifierButtons = false
    importedPreferences.applicationShortcuts.defaultBundleIdentifiers["合成"] = "synthetic.bundle"
    try persistence.replace(rules: importedRules, preferences: importedPreferences)
    // Both snapshots carry the ticket from before import, including already running background work.
    try persistence.saveRules([], generation: oldGeneration)
    try persistence.savePreferences(AppPreferencesConfiguration(), generation: oldPreferenceGeneration)
    #expect(try rules.load() == importedRules)
    #expect(try preferences.load() == importedPreferences)
    let reopened = ShortcutConfigurationPersistence(rules: rules, preferences: preferences)
    try reopened.recover()
    #expect(try rules.load() == importedRules && preferences.load() == importedPreferences)
    try persistence.saveRules(Array(importedRules.prefix(1)), generation: persistence.reserveRulesSave())
    #expect(try rules.load() == Array(importedRules.prefix(1)))
    let earlier = persistence.reserveRulesSave()
    let preferenceTicket = persistence.reservePreferencesSave()
    let latest = persistence.reserveRulesSave()
    try persistence.saveRules(importedRules, generation: latest)
    try persistence.saveRules([], generation: earlier)
    try persistence.savePreferences(importedPreferences, generation: preferenceTicket)
    #expect(try rules.load() == importedRules && preferences.load() == importedPreferences)
    let obsoletePreference = persistence.reservePreferencesSave()
    _ = persistence.reservePreferencesSave()
    var invalid = importedPreferences; invalid.applicationShortcuts.holdDuration = .nan
    try persistence.savePreferences(invalid, generation: obsoletePreference) // Skip before encoding.
    #expect(try preferences.load() == importedPreferences)
    #expect(!FileManager.default.fileExists(atPath: rules.fileURL.path + ".aether-pair-journal"))
}

@Test func configurationPersistencePreflightsBothEncodingsAndDestinations() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AetherPairFailure-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let rules = ShortcutRuleStore(fileURL: root.appendingPathComponent("rules.json"))
    let preferences = AppPreferencesStore(fileURL: root.appendingPathComponent("preferences.json"))
    let originalRules = Array(DefaultShortcutRules.make().prefix(1))
    try rules.save(originalRules); try preferences.save(.init())
    let a = try Data(contentsOf: rules.fileURL); let b = try Data(contentsOf: preferences.fileURL)
    let persistence = ShortcutConfigurationPersistence(rules: rules, preferences: preferences)
    let generation = persistence.reserveRulesSave()
    var invalid = AppPreferencesConfiguration(); invalid.applicationShortcuts.holdDuration = .nan
    #expect(throws: EncodingError.self) { try persistence.replace(rules: [], preferences: invalid) }
    #expect(try Data(contentsOf: rules.fileURL) == a && Data(contentsOf: preferences.fileURL) == b)
    // Failed paired writes keep a previously reserved edit eligible.
    try persistence.saveRules(originalRules, generation: generation)
    #expect(try rules.load() == originalRules)
    try FileManager.default.removeItem(at: preferences.fileURL)
    try FileManager.default.createDirectory(at: preferences.fileURL, withIntermediateDirectories: true)
    #expect(throws: (any Error).self) { try persistence.replace(rules: [], preferences: .init()) }
    #expect(try Data(contentsOf: rules.fileURL) == a)
    // Failed paired writes keep a previously reserved edit eligible.
    try persistence.saveRules(originalRules, generation: generation)
    #expect(try rules.load() == originalRules)
}
