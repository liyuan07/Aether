// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CAetherCore
import RustCore

/// Rust serializes writes and owns recovery/generation state; Swift only encodes existing DTOs.
/// Capturing this owner in background work keeps the core alive until each call has returned.
public final class ShortcutConfigurationPersistence: @unchecked Sendable {
    private let core: UnsafeMutableRawPointer?
    public init(rules: ShortcutRuleStore, preferences: AppPreferencesStore) {
        core = rules.fileURL.standardizedFileURL.withUnsafeFileSystemRepresentation { rulesPath in
            preferences.fileURL.standardizedFileURL.withUnsafeFileSystemRepresentation { preferencesPath in
                aether_configuration_store_create(rulesPath, preferencesPath)
            }
        }
    }
    deinit { aether_configuration_store_destroy(core) }
    public func reserveRulesSave() -> UInt64 { aether_configuration_store_reserve(core, 0) }
    public func reservePreferencesSave() -> UInt64 { aether_configuration_store_reserve(core, 1) }
    public func recover() throws { try check(aether_configuration_store_recover(core)) }
    public func saveRules(_ rules: [ShortcutRule], generation: UInt64? = nil) throws {
        guard core != nil else { throw RustDiskError(status: 3) }
        let generation = generation ?? reserveRulesSave()
        guard aether_configuration_store_current(core, 0, generation) != 0 else { return }
        try save(ShortcutRuleJSON.encode(rules), slot: 0, generation: generation)
    }
    public func savePreferences(_ preferences: AppPreferencesConfiguration, generation: UInt64? = nil) throws {
        guard core != nil else { throw RustDiskError(status: 3) }
        let generation = generation ?? reservePreferencesSave()
        guard aether_configuration_store_current(core, 1, generation) != 0 else { return }
        try save(PreferenceJSON.encode(preferences), slot: 1, generation: generation)
    }
    public func replace(rules: [ShortcutRule], preferences: AppPreferencesConfiguration) throws {
        // Complete both encodings before the first file can be changed.
        let rules = try ShortcutRuleJSON.encode(rules)
        let preferences = try PreferenceJSON.encode(preferences)
        let status = rules.withUnsafeBytes { a in preferences.withUnsafeBytes { b in
            aether_configuration_store_replace(core,
                .init(data: a.bindMemory(to: UInt8.self).baseAddress, length: a.count),
                .init(data: b.bindMemory(to: UInt8.self).baseAddress, length: b.count))
        } }
        try check(status)
    }
    private func save(_ data: Data, slot: UInt8, generation: UInt64) throws {
        let status = data.withUnsafeBytes {
            aether_configuration_store_save(core, slot, .init(data: $0.bindMemory(to: UInt8.self).baseAddress, length: $0.count), generation)
        }
        try check(status)
    }
    private func check(_ status: UInt32) throws {
        // Stale snapshots are ignored after newer same-slot edits or a successful paired replacement.
        guard status == 0 || status == 1 else { throw RustDiskError(status: status) }
    }
}
