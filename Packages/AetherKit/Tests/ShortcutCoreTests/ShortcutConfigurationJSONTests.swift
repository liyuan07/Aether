// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import ShortcutCore

private func archiveEncoder() -> JSONEncoder {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
    return encoder
}
private func archiveDecoder() -> JSONDecoder {
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    return decoder
}
private func archiveFixture(_ count: Int) -> KeyPilotConfigurationArchive {
    var preferences = AppPreferencesConfiguration()
    preferences.app.launchAtLogin = true
    preferences.app.blockAutomaticABC = true
    preferences.applicationShortcuts.holdDuration = 0.75
    preferences.applicationShortcuts.defaultBundleIdentifiers = ["合成": "synthetic.cafe\u{301}", "A": ""]
    preferences.applicationShortcuts.orderedBundleIdentifiers = ["A": ["same", "same", "different"], "\0": ["👨‍👩‍👧‍👦"]]
    preferences.applicationShortcuts.windowBehaviorOverrides = ["a": .followGlobal, "b": .activateOnly, "c": .keepMinimized, "d": .restoreMinimized]
    return .init(shortcuts: codecRules(count), preferences: preferences)
}
private func archiveError(_ error: Error) -> String {
    func context(_ c: DecodingError.Context) -> String { c.codingPath.map(\.stringValue).joined(separator: "/") + ":" + c.debugDescription }
    switch error {
    case let DecodingError.dataCorrupted(c): return "corrupt:" + context(c)
    case let DecodingError.keyNotFound(k, c): return "key:" + k.stringValue + ":" + context(c)
    case let DecodingError.typeMismatch(t, c): return "type:" + String(describing: t) + ":" + context(c)
    case let DecodingError.valueNotFound(t, c): return "value:" + String(describing: t) + ":" + context(c)
    default: return String(describing: type(of: error))
    }
}
private func compareArchives(_ data: Data, coreRequired: Bool = false) throws {
    let reference = Result { try archiveDecoder().decode(KeyPilotConfigurationArchive.self, from: data) }
    let actual = Result { try ShortcutConfigurationJSON.decode(data) }
    let core = ShortcutConfigurationJSON.decodeCore(data)
    if coreRequired { #expect(core != nil) }
    switch (reference, actual) {
    case let (.success(expected), .success(value)):
        #expect(value.schemaVersion == expected.schemaVersion)
        #expect(value.preferences == expected.preferences)
        #expect(value.shortcuts == expected.shortcuts)
        #expect(try archiveEncoder().encode(value) == archiveEncoder().encode(expected))
        #expect(ShortcutConfigurationJSON.isSupported(value) == (expected.schemaVersion <= KeyPilotConfigurationArchive.currentSchemaVersion && expected.preferences.schemaVersion <= AppPreferencesConfiguration.currentSchemaVersion))
        if let core { #expect(try archiveEncoder().encode(core) == archiveEncoder().encode(expected)) }
    case let (.failure(expected), .failure(value)):
        #expect(core == nil)
        #expect(archiveError(value) == archiveError(expected))
    default: Issue.record("Archive codec disagrees with independent native reference")
    }
}

@Test func shortcutArchiveFullJSONParityAndOwnership() async throws {
    for count in [0, 20, 96, 512] {
        var archive = archiveFixture(count)
        archive.schemaVersion = Int.max // Both encoders always write current version.
        let original = try archiveEncoder().encode(archive)
        let encoded = try ShortcutConfigurationJSON.encode(archive)
        let originalJSON = try JSONSerialization.jsonObject(with: original)
        let encodedJSON = try JSONSerialization.jsonObject(with: encoded)
        let canonicalOriginal = try JSONSerialization.data(withJSONObject: originalJSON, options: [.sortedKeys])
        let canonicalEncoded = try JSONSerialization.data(withJSONObject: encodedJSON, options: [.sortedKeys])
        #expect(canonicalOriginal == canonicalEncoded)
        try compareArchives(original, coreRequired: true)
        try compareArchives(encoded, coreRequired: true)
    }
    let archive = archiveFixture(96)
    let original = try archiveEncoder().encode(archive)
    let encoded = try ShortcutConfigurationJSON.encode(archive)
    let expected = try archiveDecoder().decode(KeyPilotConfigurationArchive.self, from: original)
    try await withThrowingTaskGroup(of: KeyPilotConfigurationArchive.self) { group in
        for _ in 0..<128 { group.addTask { try ShortcutConfigurationJSON.decode(encoded) } }
        for try await value in group {
            #expect(value.shortcuts == expected.shortcuts)
            #expect(value.preferences == expected.preferences)
        }
    }
    let copied = ShortcutConfigurationJSON.decodeCore(try ShortcutConfigurationJSON.encode(archiveFixture(512)))!
    #expect(copied.shortcuts.count == 512)
    #expect(copied.preferences.applicationShortcuts.orderedBundleIdentifiers["\0"] == ["👨‍👩‍👧‍👦"])
}

@Test func shortcutArchiveLegacyFramingAndErrorParity() throws {
    let source = #"{"schemaVersion":2,"shortcuts":[],"preferences":{}}"#
    for version in ["null", "1", "-1", "0", "2", "3", "9223372036854775807", "-9223372036854775808", "9223372036854775808", "1.0", "1e0", "1.0000000000000001", "true", "\"2\"", "{}", "[]"] {
        try compareArchives(Data(source.replacingOccurrences(of: #""schemaVersion":2"#, with: "\"schemaVersion\":\(version)").utf8))
    }
    for text in [
        #"{"shortcuts":[],"preferences":{}}"#,
        #"{"shortcuts":[],"inputAutomation":{}}"#,
        #"{"shortcuts":[],"preferences":null,"inputAutomation":{}}"#,
        #"{"shortcuts":[],"preferences":{},"inputAutomation":null}"#,
        #"{"shortcuts":[],"preferences":{},"preferences":null}"#,
        #"{"shortcuts":[],"preferences":null,"preferences":{}}"#,
        #"{"shortcuts":[],"preferences":true,"inputAutomation":{}}"#,
        #"{"schemaVersion":3,"schemaVersion":2,"shortcuts":[],"preferences":{}}"#,
        #"{"shortcuts":[],"preferences":{"schemaVersion":9999}}"#,
        #"{"shortcuts":[],"preferences":{"schemaVersion":true}}"#,
        #"{"shortcuts":[],"preferences":{"general":{"launchAtLogin":true,"blockAutomaticABC":true}}}"#,
        #"{"shortcuts":[],"preferences":{"app":null,"general":{"launchAtLogin":"ignored","blockAutomaticABC":false}}}"#,
        #"{"shortcuts":[],"preferences":{"applicationShortcuts":{"defaultBundleIdentifiers":{"café":"first","cafe\u0301":"second"}}}}"#,
        #"{"shortcuts":[],"preferences":{"app":{"launchAtLogin":true,"launchAtLogin":null}}}"#,
        #"{"shortcuts":[],"preferences":{"app":{"launchAtLogin":"bad"}}}"#,
        #"{"shortcuts":[{}],"preferences":{}}"#,
        #"{"shortcuts":[],"preferences":{ },"unknown":"\ud800"}"#,
        #"{"shortcuts":[],"preferences":{ },"unknown":1e9999}"#,
        "{}", "[]", "null", "", source + "x"
    ] { try compareArchives(Data(text.utf8)) }
    for encoding in [String.Encoding.utf8, .utf16, .utf16BigEndian, .utf16LittleEndian, .utf32, .utf32BigEndian, .utf32LittleEndian] {
        try compareArchives(source.data(using: encoding)!)
    }
    try compareArchives(Data([0xef, 0xbb, 0xbf]) + Data(source.utf8))
    for text in [
        #"{"shortcuts":[],"preferences":{}}"#,
        #"{"shortcuts":[],"inputAutomation":{}}"#,
        #"{"shortcuts":[],"preferences":null,"inputAutomation":{}}"#,
        #"{"schemaVersion":2,"schemaVersion":3,"shortcuts":[],"preferences":{}}"#,
        #"{"shortcuts":[],"preferences":{},"preferences":null}"#,
        #"{"shortcuts":[],"preferences":{"schemaVersion":9999}}"#
    ] { try compareArchives(Data(text.utf8), coreRequired: true) }
}

@Test func shortcutArchiveStructuralMutationAndVersionPolicy() throws {
    let data = try archiveEncoder().encode(archiveFixture(6))
    let original = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let values: [Any] = [NSNull(), true, false, 0, -1, 3, Int.max, "", "unknown", [], [:], ["general": NSNull()]]
    for key in ["schemaVersion", "preferences", "shortcuts"] {
        var missing = original; missing.removeValue(forKey: key)
        try compareArchives(JSONSerialization.data(withJSONObject: missing))
        for value in values {
            var changed = original; changed[key] = value
            try compareArchives(JSONSerialization.data(withJSONObject: changed))
        }
    }
    for version in [Int.min, -1, 0, 1, 2, 3, Int.max] {
        for preferenceVersion in [Int.min, -1, 0, 9, 10, Int.max] {
            var archive = archiveFixture(0); archive.schemaVersion = version; archive.preferences.schemaVersion = preferenceVersion
            #expect(ShortcutConfigurationJSON.isSupported(archive) == (version <= 2 && preferenceVersion <= 9))
        }
    }
    for value in [Double.nan, .infinity, -.infinity] {
        var archive = archiveFixture(0); archive.preferences.applicationShortcuts.holdDuration = value
        let native = Result { try archiveEncoder().encode(archive) }
        let core = Result { try ShortcutConfigurationJSON.encode(archive) }
        guard case let .failure(EncodingError.invalidValue(_, a)) = native,
              case let .failure(EncodingError.invalidValue(_, b)) = core else { Issue.record("Nonfinite value must preserve EncodingError"); continue }
        #expect(a.codingPath.map(\.stringValue) == b.codingPath.map(\.stringValue))
        #expect(a.debugDescription == b.debugDescription)
    }
}

@Test func shortcutArchiveReleaseBenchmark() throws {
    guard ProcessInfo.processInfo.environment["AETHER_SHORTCUT_ARCHIVE_BENCHMARK"] == "1" else { return }
    let archive = archiveFixture(3000)
    let input = try archiveEncoder().encode(archive)
    let expected = try archiveDecoder().decode(KeyPilotConfigurationArchive.self, from: input)
    #expect(ShortcutConfigurationJSON.decodeCore(input) != nil)
    var encodeTimes = [[Double](), [Double]()], decodeTimes = [[Double](), [Double]()]
    for round in 0..<7 {
        for backend in (round.isMultiple(of: 2) ? [0, 1] : [1, 0]) {
            var data = Data()
            var start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<5 { data = try backend == 0 ? archiveEncoder().encode(archive) : ShortcutConfigurationJSON.encode(archive) }
            encodeTimes[backend].append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            let decoded = try archiveDecoder().decode(KeyPilotConfigurationArchive.self, from: data)
            #expect(decoded.shortcuts == expected.shortcuts && decoded.preferences == expected.preferences)
            var value = expected
            start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<5 { value = try backend == 0 ? archiveDecoder().decode(KeyPilotConfigurationArchive.self, from: input) : ShortcutConfigurationJSON.decode(input) }
            decodeTimes[backend].append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            #expect(value.shortcuts == expected.shortcuts && value.preferences == expected.preferences && value.schemaVersion == expected.schemaVersion)
        }
    }
    let result: [String: Any] = ["rules": archive.shortcuts.count, "operations_per_round": 5, "input_bytes": input.count,
        "native_encode_ms": encodeTimes[0], "rust_encode_ms": encodeTimes[1], "native_decode_ms": decodeTimes[0], "rust_decode_ms": decodeTimes[1],
        "native_encode_median_ms": encodeTimes[0].sorted()[3], "rust_encode_median_ms": encodeTimes[1].sorted()[3],
        "native_decode_median_ms": decodeTimes[0].sorted()[3], "rust_decode_median_ms": decodeTimes[1].sorted()[3]]
    print("SHORTCUT_ARCHIVE_BENCHMARK " + String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
}
