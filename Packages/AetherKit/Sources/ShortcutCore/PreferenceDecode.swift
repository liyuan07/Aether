// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CAetherCore

private final class PreferenceKeys {
    var keys: [[String]] = [[], [], []]
    var ids: [[String: Int]] = [[:], [:], [:]]
    func intern(_ key: String, kind: Int) -> Int {
        if let existing = ids[kind][key] { return existing }
        let id = keys[kind].count
        keys[kind].append(key); ids[kind][key] = id
        return id
    }
}
private func preferenceKeyToken(_ raw: UnsafeMutableRawPointer?, _ kind: UInt8, _ bytes: AetherBytes) -> Int {
    let context = Unmanaged<PreferenceKeys>.fromOpaque(raw!).takeUnretainedValue()
    let key = String(decoding: UnsafeBufferPointer(start: bytes.data, count: bytes.length), as: UTF8.self)
    return context.intern(key, kind: Int(kind))
}

extension PreferenceJSON {
    struct Decoded {
        let configuration: AppPreferencesConfiguration
        let storedSchemaVersion: Int
    }
    private struct SchemaVersion: Decodable { let schemaVersion: Int }
    private static func storedVersion(_ data: Data) -> Int {
        (try? JSONDecoder().decode(SchemaVersion.self, from: data).schemaVersion) ?? Int(RustPreferences.defaults.stored_default)
    }
    static func decode(_ data: Data, needsStoredVersion: Bool = true) throws -> Decoded {
        if let decoded = decodeCore(data, needsStoredVersion: needsStoredVersion) { return decoded }
        return .init(configuration: try JSONDecoder().decode(AppPreferencesConfiguration.self, from: data),
            storedSchemaVersion: needsStoredVersion ? storedVersion(data) : Int(RustPreferences.defaults.stored_default))
    }
    static func decodeCore(_ data: Data, needsStoredVersion: Bool = true) -> Decoded? {
        let keys = Unmanaged.passRetained(PreferenceKeys())
        defer { keys.release() }
        let handle = data.withUnsafeBytes {
            aether_preferences_decode(.init(data: $0.bindMemory(to: UInt8.self).baseAddress, length: $0.count), preferenceKeyToken, keys.toOpaque())
        }
        defer { aether_preferences_decoded_destroy(handle) }
        let view = aether_preferences_decoded_view(handle)
        guard view.status == 0 else { return nil }
        let arena = UnsafeBufferPointer(start: view.bytes.data, count: view.bytes.length)
        let values = UnsafeBufferPointer(start: view.values, count: view.value_count)
        let nativeKeys = keys.takeUnretainedValue().keys
        func text(_ span: AetherRuleText) -> String { String(decoding: arena[span.start..<(span.start + span.length)], as: UTF8.self) }
        var configuration = AppPreferencesConfiguration()
        configuration.app.launchAtLogin = view.launch != 0
        configuration.app.blockAutomaticABC = view.block != 0
        configuration.app.showModifierButtons = view.show != 0
        configuration.applicationShortcuts.holdDuration = view.hold
        configuration.applicationShortcuts.restoreMinimizedWindows = view.restore != 0
        for row in UnsafeBufferPointer(start: view.defaults, count: view.default_count) {
            configuration.applicationShortcuts.defaultBundleIdentifiers[nativeKeys[0][row.native_key]] = text(row.entry.value)
        }
        for row in UnsafeBufferPointer(start: view.orders, count: view.order_count) {
            configuration.applicationShortcuts.orderedBundleIdentifiers[nativeKeys[1][row.native_key]] = values[row.entry.start..<(row.entry.start + row.entry.count)].map(text)
        }
        for row in UnsafeBufferPointer(start: view.behaviors, count: view.behavior_count) {
            let behavior: ApplicationWindowBehavior
            switch row.entry.behavior {
            case 0: behavior = .followGlobal
            case 1: behavior = .keepMinimized
            case 2: behavior = .restoreMinimized
            case 3: behavior = .activateOnly
            default: preconditionFailure("Invalid decoded window behavior")
            }
            configuration.applicationShortcuts.windowBehaviorOverrides[nativeKeys[2][row.native_key]] = behavior
        }
        let version = view.version_known != 0 ? Int(view.version) : (needsStoredVersion ? storedVersion(data) : Int(RustPreferences.defaults.stored_default))
        return .init(configuration: configuration, storedSchemaVersion: version)
    }
}
