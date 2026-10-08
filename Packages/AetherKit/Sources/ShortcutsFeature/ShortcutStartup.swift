// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ShortcutCore
import CAetherCore

struct ShortcutStartupKeys {
    let migration: String, holdDuration: String, favorites: String
}
struct ShortcutStartupState {
    let rules: [ShortcutRule]
    let preferences: AppPreferencesConfiguration
    let legacyTargets: [ApplicationTarget]
    let holdDuration: TimeInterval
    let favorites: Set<String>
    let error: String?
}

func loadShortcutStartup(store: ShortcutRuleStore, preferencesStore: AppPreferencesStore,
                         persistence: ShortcutConfigurationPersistence, preferences: UserDefaults,
                         keys: ShortcutStartupKeys) -> ShortcutStartupState {
    let effects = ShortcutStartupEffects(store: store, preferencesStore: preferencesStore,
        persistence: persistence, preferences: preferences, keys: keys)
    withExtendedLifetime(effects) {
        precondition(aether_shortcut_startup({ pointer, step in
            Unmanaged<ShortcutStartupEffects>.fromOpaque(pointer!).takeUnretainedValue().perform(step)
        }, Unmanaged.passUnretained(effects).toOpaque()) != 0)
    }
    return .init(rules: effects.rules, preferences: effects.configuration, legacyTargets: effects.legacyTargets,
        holdDuration: effects.holdDuration, favorites: effects.favorites, error: effects.error)
}

/// Synchronous native effects; the core chooses load/default/upgrade and save-failure publication.
private final class ShortcutStartupEffects {
    let store: ShortcutRuleStore
    let preferencesStore: AppPreferencesStore
    let persistence: ShortcutConfigurationPersistence
    let preferences: UserDefaults
    let keys: ShortcutStartupKeys
    var configuration = AppPreferencesConfiguration()
    var rules: [ShortcutRule] = [], storedRules: [ShortcutRule] = [], migratedRules: [ShortcutRule] = []
    var legacyTargets: [ApplicationTarget] = []
    var storedVersion = 0
    var holdDuration = ShortcutGuideConfiguration.defaultHoldDuration
    var favorites: Set<String> = []
    var error: String?

    init(store: ShortcutRuleStore, preferencesStore: AppPreferencesStore, persistence: ShortcutConfigurationPersistence,
         preferences: UserDefaults, keys: ShortcutStartupKeys) {
        self.store = store; self.preferencesStore = preferencesStore; self.persistence = persistence
        self.preferences = preferences; self.keys = keys
    }
    func perform(_ step: UInt8) -> Int64 {
        switch step {
        case 0:
            do { try persistence.recover(); return 1 }
            catch { self.error = "恢复应用配置失败：\(error.localizedDescription)"; return 0 }
        case 1:
            guard let stored = try? preferencesStore.load(persistingMigrations: true) else { return 0 }
            configuration = stored
        case 2: configuration = AppPreferencesConfiguration()
        case 3:
            do { try persistence.savePreferences(configuration) }
            catch { self.error = "创建应用配置失败：\(error.localizedDescription)"; return 0 }
        case 4:
            holdDuration = ShortcutGuideConfiguration.normalizedHoldDuration(
                preferences.object(forKey: keys.holdDuration) as? TimeInterval ?? ShortcutGuideConfiguration.defaultHoldDuration)
            favorites = Set(preferences.stringArray(forKey: keys.favorites) ?? [])
        case 5:
            guard let stored = try? store.load(), !stored.isEmpty else { return 0 }
            storedRules = stored
        case 6:
            legacyTargets = storedRules.compactMap { rule in
                guard case let .application(target, _) = rule.action else { return nil }
                return target
            }
        case 7:
            storedVersion = preferences.integer(forKey: keys.migration)
            return Int64(storedVersion)
        case 8: migratedRules = DefaultShortcutRules.migrate(storedRules, fromVersion: storedVersion)
        case 9:
            do { try persistence.saveRules(migratedRules) }
            catch { self.error = "升级默认快捷键失败：\(error.localizedDescription)"; return 0 }
        case 10: preferences.set(DefaultShortcutRules.currentMigrationVersion, forKey: keys.migration)
        case 11: rules = migratedRules
        case 12: rules = storedRules
        case 13: rules = DefaultShortcutRules.make()
        case 14:
            do { try persistence.saveRules(rules) }
            catch { self.error = "保存默认快捷键失败：\(error.localizedDescription)"; return 0 }
        default: preconditionFailure("Invalid shortcut startup effect")
        }
        return 1
    }
}
