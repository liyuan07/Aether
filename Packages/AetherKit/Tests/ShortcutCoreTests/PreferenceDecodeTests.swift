// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import ShortcutCore

private struct PreferenceVersion: Decodable { let schemaVersion: Int }
private func prefError(_ error: Error) -> String {
    func path(_ c: DecodingError.Context) -> String { c.codingPath.map { "\($0.stringValue):\($0.intValue.map(String.init) ?? "nil")" }.joined(separator: "/") + ":" + c.debugDescription }
    switch error {
    case let DecodingError.dataCorrupted(c): return "corrupt:" + path(c)
    case let DecodingError.keyNotFound(k,c): return "key:" + k.stringValue + ":" + path(c)
    case let DecodingError.valueNotFound(t,c): return "value:" + String(describing:t) + ":" + path(c)
    case let DecodingError.typeMismatch(t,c): return "type:" + String(describing:t) + ":" + path(c)
    default: return String(describing:type(of:error))
    }
}
private func comparePreferenceDecoders(_ data: Data, coreRequired: Bool = false) throws {
    let native = Result { try JSONDecoder().decode(AppPreferencesConfiguration.self, from: data) }
    let actual = Result { try PreferenceJSON.decode(data) }
    let core = PreferenceJSON.decodeCore(data)
    if coreRequired { #expect(core != nil) }
    switch (native, actual) {
    case let (.success(expected), .success(decoded)):
        #expect(decoded.configuration == expected)
        #expect(decoded.configuration.applicationShortcuts.holdDuration.bitPattern == expected.applicationShortcuts.holdDuration.bitPattern)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(decoded.configuration) == encoder.encode(expected))
        let version = (try? JSONDecoder().decode(PreferenceVersion.self, from: data).schemaVersion) ?? 1
        #expect(decoded.storedSchemaVersion == version)
        if let core {
            #expect(core.storedSchemaVersion == version)
            #expect(try encoder.encode(core.configuration) == encoder.encode(expected))
        }
    case let (.failure(expected), .failure(error)):
        #expect(core == nil)
        #expect(prefError(error) == prefError(expected))
    default: Issue.record("Preference decoding differs for synthetic input: \(String(decoding: data.prefix(200), as: UTF8.self))")
    }
}

@Test func preferenceDecodeNativeAndRustEncodingFixtures() throws {
    for count in [0,1,128,1024] {
        var preferences = AppPreferencesConfiguration()
        for i in 0..<count {
            let key = "\(i)-合成\0cafe\u{301}"
            preferences.applicationShortcuts.defaultBundleIdentifiers[key] = "bundle/\(i)"
            preferences.applicationShortcuts.orderedBundleIdentifiers[key] = ["one", "two", "one", "👨‍👩‍👧‍👦"]
            preferences.applicationShortcuts.windowBehaviorOverrides[key] = ApplicationWindowBehavior.allCases[i % 4]
        }
        for hold in [0.0, -0.0, 0.3, 0.75, 1.5, -1, Double.leastNonzeroMagnitude, .leastNormalMagnitude, .greatestFiniteMagnitude, 0.5.nextUp] {
            preferences.applicationShortcuts.holdDuration = hold
            try comparePreferenceDecoders(JSONEncoder().encode(preferences), coreRequired: true)
            try comparePreferenceDecoders(PreferenceJSON.encode(preferences), coreRequired: true)
        }
    }
}

@Test func preferenceDecodeCanonicalDuplicateKeysRetainFirstLiteralBytes() throws {
    let pairs = [("a","a"), ("a", #"\u0061"#), ("café", #"cafe\u0301"#), (#"cafe\u0301"#, "café"), ("K","K"), ("K","K"), ("가", #"\u1100\u1161"#), ("\u{1F600}", #"\ud83d\ude00"#), ("a\u{301}\u{327}", "a\u{327}\u{301}")]
    for (first, second) in pairs {
        for (field, valid, invalid) in [
            ("defaultBundleIdentifiers", #""first""#, "null"),
            ("orderedBundleIdentifiers", #"["first","first"]"#, "false"),
            ("windowBehaviorOverrides", #""keepMinimized""#, #""invalid""#)
        ] {
            let text = "{\"applicationShortcuts\":{\"\(field)\":{\"\(first)\":\(valid),\"\(second)\":\(invalid)}}}"
            try comparePreferenceDecoders(Data(text.utf8), coreRequired: true)
        }
    }
    // Each map has its own literal key ownership even when equal keys occur in another map.
    let text = #"{"applicationShortcuts":{"defaultBundleIdentifiers":{"café":"first"},"orderedBundleIdentifiers":{"cafe\u0301":["second"]},"windowBehaviorOverrides":{"cafe\u0301":"activateOnly"}}}"#
    try comparePreferenceDecoders(Data(text.utf8), coreRequired: true)
    // A duplicate struct field forces first-wins normalization and a second core decode attempt.
    try comparePreferenceDecoders(Data((text.dropLast().description + #", "applicationShortcuts":null}"#).utf8), coreRequired: true)
}

@Test func preferenceDecodeCompatibilityAndErrors() throws {
    for text in [
        "{}", "[]", "null", "", "{}x", #"{"app":null}"#, #"{"general":null}"#, #"{"general":[]}"#,
        #"{"app":null,"general":{"launchAtLogin":"ignored","blockAutomaticABC":true}}"#,
        #"{"general":{"launchAtLogin":"bad"}}"#,
        #"{"app":{"launchAtLogin":true,"launchAtLogin":null}}"#,
        #"{"general":{"launchAtLogin":true,"blockAutomaticABC":null,"showModifierButtons":"ignored"}}"#,
        #"{"applicationShortcuts":null}"#, #"{"applicationShortcuts":[]}"#,
        #"{"applicationShortcuts":{"defaultBundleIdentifiers":null,"orderedBundleIdentifiers":null,"windowBehaviorOverrides":null}}"#,
        #"{"applicationShortcuts":{"defaultBundleIdentifiers":{"a":null,"a":"second"}}}"#,
        #"{"applicationShortcuts":{"orderedBundleIdentifiers":{"a":["first"],"a":[null]}}}"#,
        #"{"applicationShortcuts":{"holdDuration":-0}}"#, #"{"applicationShortcuts":{"holdDuration":1e9999}}"#,
        #"{"applicationShortcuts":{"holdDuration":1e-9999}}"#, #"{"applicationShortcuts":{"holdDuration":1e-324}}"#,
        #"{"applicationShortcuts":{"holdDuration":0e-9999}}"#, #"{"applicationShortcuts":{"holdDuration":-0e-9999}}"#,
        #"{"applicationShortcuts":{"holdDuration":"0.5"}}"#,
        #"{"unknown":"\ud800"}"#, #"{"unknown":1e9999}"#
    ] { try comparePreferenceDecoders(Data(text.utf8)) }
    for version in ["null", "true", "{}", "[]", "\"9\"", "-1", "9", "10", "1.0", "9e0", "1.0000000000000001", "9223372036854775807", "-9223372036854775808", "9223372036854775808", "1e9999"] {
        try comparePreferenceDecoders(Data("{\"schemaVersion\":\(version)}".utf8), coreRequired: true)
    }
    let source = #"{"general":{"launchAtLogin":true},"applicationShortcuts":{"defaultBundleIdentifiers":{"合成":"本地"}}}"#
    for encoding in [String.Encoding.utf8, .utf16, .utf16BigEndian, .utf16LittleEndian, .utf32, .utf32BigEndian, .utf32LittleEndian] {
        try comparePreferenceDecoders(source.data(using: encoding)!)
    }
    try comparePreferenceDecoders(Data([0xef,0xbb,0xbf]) + Data(source.utf8))
    for depth in [120,510,511,512,513] {
        let text = "{\"unknown\":" + String(repeating:"[",count:depth) + "0" + String(repeating:"]",count:depth) + "}"
        try comparePreferenceDecoders(Data(text.utf8))
    }
}

@Test func preferenceDecodeStructuralMutationMatrix() throws {
    let values: [Any] = [NSNull(),true,false,0,1,-1,0.5,"", "invalid",[],[:],["a":"value"],["a":["one","one"]]]
    for key in ["launchAtLogin","blockAutomaticABC","showModifierButtons"] {
        for value in values { try comparePreferenceDecoders(JSONSerialization.data(withJSONObject:["app":[key:value]])) }
    }
    for key in ["defaultBundleIdentifiers","orderedBundleIdentifiers","windowBehaviorOverrides","holdDuration","restoreMinimizedWindows"] {
        for value in values { try comparePreferenceDecoders(JSONSerialization.data(withJSONObject:["applicationShortcuts":[key:value]])) }
    }
}

@Test func preferenceDecodeConcurrentOwnershipAndIsolation() async throws {
    let source = Data(#"{"app":{"launchAtLogin":true},"applicationShortcuts":{"defaultBundleIdentifiers":{"café":"first","cafe\u0301":null},"orderedBundleIdentifiers":{"合成":["a\u0000b","👨‍👩‍👧‍👦"]}}}"#.utf8)
    let expected = try JSONDecoder().decode(AppPreferencesConfiguration.self, from: source)
    try await withThrowingTaskGroup(of: AppPreferencesConfiguration.self) { group in
        for _ in 0..<128 { group.addTask { try PreferenceJSON.decode(source).configuration } }
        for try await value in group { #expect(value == expected) }
    }
    let copied = PreferenceJSON.decodeCore(Data(source))!.configuration
    #expect(copied.applicationShortcuts.defaultBundleIdentifiers["café"] == "first")
    #expect(copied.applicationShortcuts.orderedBundleIdentifiers["合成"] == ["a\0b","👨‍👩‍👧‍👦"])
}


@Test func preferenceDecodeReleaseBenchmark() throws {
    guard ProcessInfo.processInfo.environment["AETHER_PREFERENCE_DECODE_BENCHMARK"] == "1" else { return }
    let preferences = preferenceFixture(2000)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
    let data = try encoder.encode(preferences)
    #expect(PreferenceJSON.decodeCore(data) != nil)
    var times = [[Double](),[Double](),[Double]()]
    for round in 0..<7 {
        for backend in (round.isMultiple(of:2) ? [0,1,2] : [2,1,0]) {
            var value = preferences; var version = 9
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<5 {
                if backend == 2 {
                    let decoded = try PreferenceJSON.decode(data); value = decoded.configuration; version = decoded.storedSchemaVersion
                } else {
                    let decoder = JSONDecoder()
                    if backend == 0 { version = (try? decoder.decode(PreferenceVersion.self,from:data).schemaVersion) ?? 1 }
                    value = try decoder.decode(AppPreferencesConfiguration.self,from:data)
                }
            }
            times[backend].append(Double(DispatchTime.now().uptimeNanoseconds-start)/1_000_000)
            #expect(value == preferences && version == 9)
        }
    }
    let result: [String:Any] = ["default_rows":preferences.applicationShortcuts.defaultBundleIdentifiers.count,
        "ordered_rows":preferences.applicationShortcuts.orderedBundleIdentifiers.count,"behavior_rows":preferences.applicationShortcuts.windowBehaviorOverrides.count,
        "input_bytes":data.count,"operations_per_round":5,"native_store_ms":times[0],"native_config_ms":times[1],"rust_ms":times[2],
        "native_store_median_ms":times[0].sorted()[3],"native_config_median_ms":times[1].sorted()[3],"rust_median_ms":times[2].sorted()[3]]
    print("PREFERENCE_DECODE_BENCHMARK " + String(decoding:try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]),as:UTF8.self))
}

@Test func preferenceDecodeFloatingPointBitPatternsAndRangeEdges() throws {
    var seed: UInt64 = 0x63c8a5d7
    for _ in 0..<1024 {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        let hold = Double(bitPattern: seed)
        guard hold.isFinite else { continue }
        var configuration = AppPreferencesConfiguration(); configuration.applicationShortcuts.holdDuration = hold
        try comparePreferenceDecoders(JSONEncoder().encode(configuration), coreRequired: true)
    }
    for literal in ["2e-324", "2.4703282292062327e-324", "2.4703282292062328e-324", "2.5e-324", "3e-324", "4e-324", "5e-324", "-2e-324", "-3e-324", "0e99999999", "1.7976931348623157e308", "1.7976931348623158e308", "1.7976931348623159e308"] {
        try comparePreferenceDecoders(Data("{\"applicationShortcuts\":{\"holdDuration\":\(literal)}}".utf8))
    }
}

@Test func preferenceDecodeStoreMigrationMetadataKeepsWriteTiming() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("preferences.json")
    let store = AppPreferencesStore(fileURL: file)
    for (literal, writes) in [("9", false), ("9.0", false), ("9e0", false), ("10", false), ("9999", false), ("1.0", true), ("true", true), ("null", true), ("1e9999", true)] {
        let data = Data("{\"schemaVersion\":\(literal),\"general\":{\"blockAutomaticABC\":true}}".utf8)
        try data.write(to: file)
        let configuration = try store.load(persistingMigrations: true)
        #expect(configuration.app.blockAutomaticABC)
        let after = try Data(contentsOf: file)
        #expect((after != data) == writes)
    }
}
