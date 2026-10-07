// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CAetherCore
import RustCore

/// Swift retains dictionary membership/Unicode equality; Rust owns the serialized format.
enum PreferenceJSON {
    static func encode(_ configuration: AppPreferencesConfiguration) throws -> Data {
        guard configuration.applicationShortcuts.holdDuration.isFinite else {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try encoder.encode(configuration) // Preserve the original EncodingError path and wording.
        }
        var bytes = [UInt8]()
        func text(_ string: String) -> AetherRuleText {
            let start = bytes.count; bytes.append(contentsOf: string.utf8)
            return .init(start: start, length: bytes.count - start)
        }
        let prefs = configuration.applicationShortcuts
        let defaults = prefs.defaultBundleIdentifiers.map { key, value in
            AetherPreferenceEntry(key: text(key), value: text(value), start: 0, count: 0, behavior: 0)
        }
        var values: [AetherRuleText] = []
        let orders = prefs.orderedBundleIdentifiers.map { key, strings in
            let start = values.count
            for string in strings { values.append(text(string)) }
            return AetherPreferenceEntry(key: text(key), value: .init(), start: start, count: strings.count, behavior: 0)
        }
        let behaviors = prefs.windowBehaviorOverrides.map { key, behavior in
            let tag: UInt8
            switch behavior {
            case .followGlobal: tag = 0
            case .keepMinimized: tag = 1
            case .restoreMinimized: tag = 2
            case .activateOnly: tag = 3
            }
            return AetherPreferenceEntry(key: text(key), value: .init(), start: 0, count: 0, behavior: tag)
        }
        return try defaults.withUnsafeBufferPointer { defaults in
            try orders.withUnsafeBufferPointer { orders in
                try values.withUnsafeBufferPointer { values in
                    try behaviors.withUnsafeBufferPointer { behaviors in
                        try bytes.withUnsafeBufferPointer { bytes in
                            var input = AetherPreferenceInput(hold: prefs.holdDuration,
                                launch: configuration.app.launchAtLogin ? 1 : 0, block: configuration.app.blockAutomaticABC ? 1 : 0,
                                show: configuration.app.showModifierButtons ? 1 : 0, restore: prefs.restoreMinimizedWindows ? 1 : 0,
                                defaults: defaults.baseAddress, default_count: defaults.count, orders: orders.baseAddress, order_count: orders.count,
                                values: values.baseAddress, value_count: values.count, behaviors: behaviors.baseAddress, behavior_count: behaviors.count)
                            return try RustBuffer.take(aether_preferences_encode(&input, .init(data: bytes.baseAddress, length: bytes.count)))
                        }
                    }
                }
            }
        }
    }
}
