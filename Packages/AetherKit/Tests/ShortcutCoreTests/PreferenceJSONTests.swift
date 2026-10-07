// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import ShortcutCore

private func nativePreferenceData(_ preferences: AppPreferencesConfiguration) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(preferences)
}
func preferenceFixture(_ count: Int) -> AppPreferencesConfiguration {
    var preferences = AppPreferencesConfiguration()
    let strings = ["", "合成", "café", "cafe\u{301}", "a\0b", "\"\n\\", "👨‍👩‍👧‍👦", "路径/带斜线", "\u{2028}\u{2029}"]
    for i in 0..<count {
        let key = "\(i)-" + strings[i % strings.count]
        let value = strings[(i + 1) % strings.count]
        preferences.applicationShortcuts.defaultBundleIdentifiers[key] = value
        preferences.applicationShortcuts.orderedBundleIdentifiers[key] = i % 4 == 0 ? [] : [value, value, strings[(i + 2) % strings.count]]
        preferences.applicationShortcuts.windowBehaviorOverrides[key] = ApplicationWindowBehavior.allCases[i % 4]
    }
    // Swift canonical-equivalent keys retain one member; Rust must preserve the surviving literal bytes.
    preferences.applicationShortcuts.defaultBundleIdentifiers["café"] = "first"
    preferences.applicationShortcuts.defaultBundleIdentifiers["cafe\u{301}"] = "second"
    return preferences
}

@Test func preferenceJSONFullNativeParityAndFloatingPointBits() throws {
    let holds = [0.0, -0.0, 0.3, 0.5, 0.75, 1.5, -1, Double.leastNonzeroMagnitude, .leastNormalMagnitude, .greatestFiniteMagnitude, -Double.greatestFiniteMagnitude, 0.5.nextUp, 0.5.nextDown]
    for count in [0, 1, 32, 512] {
        for flags in 0..<16 {
            var preferences = preferenceFixture(count)
            preferences.schemaVersion = flags % 2 == 0 ? Int.max : Int.min
            preferences.app.launchAtLogin = flags & 1 != 0
            preferences.app.blockAutomaticABC = flags & 2 != 0
            preferences.app.showModifierButtons = flags & 4 != 0
            preferences.applicationShortcuts.restoreMinimizedWindows = flags & 8 != 0
            preferences.applicationShortcuts.holdDuration = holds[flags % holds.count]
            let actual = try PreferenceJSON.encode(preferences)
            let expected = try nativePreferenceData(preferences)
            var actualJSON = try JSONSerialization.jsonObject(with: actual) as! [String: Any]
            var expectedJSON = try JSONSerialization.jsonObject(with: expected) as! [String: Any]
            // JSONSerialization can coerce the native encoder's -0 token to integer zero.
            // Compare floating bits with the original typed decoder below, and literal strings here.
            var actualShortcuts = actualJSON["applicationShortcuts"] as! [String: Any]
            var expectedShortcuts = expectedJSON["applicationShortcuts"] as! [String: Any]
            actualShortcuts.removeValue(forKey: "holdDuration"); expectedShortcuts.removeValue(forKey: "holdDuration")
            actualJSON["applicationShortcuts"] = actualShortcuts; expectedJSON["applicationShortcuts"] = expectedShortcuts
            let canonicalActual = try JSONSerialization.data(withJSONObject: actualJSON, options: [.sortedKeys])
            let canonicalExpected = try JSONSerialization.data(withJSONObject: expectedJSON, options: [.sortedKeys])
            #expect(canonicalActual == canonicalExpected)
            let nativeDecoded = try JSONDecoder().decode(AppPreferencesConfiguration.self, from: expected)
            let rustDecoded = try JSONDecoder().decode(AppPreferencesConfiguration.self, from: actual)
            #expect(nativeDecoded == rustDecoded)
            #expect(nativeDecoded.applicationShortcuts.holdDuration.bitPattern == rustDecoded.applicationShortcuts.holdDuration.bitPattern)
            #expect(try nativePreferenceData(nativeDecoded) == nativePreferenceData(rustDecoded))
            #expect(try PreferenceJSON.encode(preferences) == actual)
        }
    }
}

@Test func preferenceJSONStoreReopenAndFailedEncodeProtection() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = AppPreferencesStore(fileURL: directory.appendingPathComponent("preferences.json"))
    var preferences = preferenceFixture(64)
    preferences.applicationShortcuts.holdDuration = 0.9
    try store.save(preferences)
    let nativeDecoded = try JSONDecoder().decode(AppPreferencesConfiguration.self, from: Data(contentsOf: store.fileURL))
    let reopened = try store.load()
    #expect(reopened == nativeDecoded && reopened == preferences)
    let before = try Data(contentsOf: store.fileURL)
    for value in [Double.nan, .infinity, -.infinity] {
        preferences.applicationShortcuts.holdDuration = value
        let native = Result { try nativePreferenceData(preferences) }
        let core = Result { try PreferenceJSON.encode(preferences) }
        guard case let .failure(EncodingError.invalidValue(_, a)) = native,
              case let .failure(EncodingError.invalidValue(_, b)) = core else { Issue.record("Nonfinite preference must preserve native error"); continue }
        #expect(a.codingPath.map(\.stringValue) == b.codingPath.map(\.stringValue))
        #expect(a.debugDescription == b.debugDescription)
        #expect(throws: (any Error).self) { try store.save(preferences) }
        let after = try Data(contentsOf: store.fileURL)
        #expect(before == after)
    }
}

@Test func preferenceJSONConcurrentIndependentOutputs() async throws {
    let preferences = preferenceFixture(96)
    let expected = try PreferenceJSON.encode(preferences)
    try await withThrowingTaskGroup(of: Data.self) { group in
        for _ in 0..<128 { group.addTask { try PreferenceJSON.encode(preferences) } }
        for try await data in group { #expect(data == expected) }
    }
    let owned = try PreferenceJSON.encode(preferenceFixture(512))
    let decoded = try JSONDecoder().decode(AppPreferencesConfiguration.self, from: owned)
    #expect(decoded.applicationShortcuts.orderedBundleIdentifiers.count == 512)
}

@Test func preferenceJSONReleaseBenchmark() throws {
    guard ProcessInfo.processInfo.environment["AETHER_PREFERENCE_CODEC_BENCHMARK"] == "1" else { return }
    let preferences = preferenceFixture(2000)
    var times = [[Double](), [Double]()]
    for round in 0..<7 {
        for backend in (round.isMultiple(of: 2) ? [0, 1] : [1, 0]) {
            var data = Data()
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<5 { data = try backend == 0 ? nativePreferenceData(preferences) : PreferenceJSON.encode(preferences) }
            times[backend].append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            let decoded = try JSONDecoder().decode(AppPreferencesConfiguration.self, from: data)
            #expect(decoded == preferences)
        }
    }
    let result: [String: Any] = ["default_rows": preferences.applicationShortcuts.defaultBundleIdentifiers.count,
        "ordered_rows": preferences.applicationShortcuts.orderedBundleIdentifiers.count,
        "behavior_rows": preferences.applicationShortcuts.windowBehaviorOverrides.count, "operations_per_round": 5,
        "native_ms": times[0], "rust_ms": times[1], "native_median_ms": times[0].sorted()[3], "rust_median_ms": times[1].sorted()[3]]
    print("PREFERENCE_CODEC_BENCHMARK " + String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
}
