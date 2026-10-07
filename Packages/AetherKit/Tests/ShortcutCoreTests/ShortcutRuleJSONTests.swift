// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import ShortcutCore

private func referenceRuleJSON(_ rules: [ShortcutRule]) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(rules)
}

private func codecRules(_ count: Int) -> [ShortcutRule] {
    let strings = ["", "合成规则", "café", "cafe\u{301}", "路径/带\\斜线", "\"\n\r\t\0", "👨‍👩‍👧‍👦", "\u{2028}\u{2029}"]
    return (0..<count).map { index in
        var source = KeyCombination(keyCode: index % 19 == 0 ? .max : UInt16(truncatingIfNeeded: index * 991),
            modifiers: .init(rawValue: UInt8(truncatingIfNeeded: index)),
            physicalModifiers: .init(rawValue: index % 7 == 0 ? .max : UInt16(truncatingIfNeeded: index * 37)))
        source.modifiers = .init(rawValue: UInt8(truncatingIfNeeded: index))
        var target = source
        target.keyCode = UInt16.max - source.keyCode
        target.modifiers = .init(rawValue: UInt8.max - source.modifiers.rawValue)
        let text = strings[index % strings.count]
        let action: ShortcutAction
        switch index % 6 {
        case 0:
            action = .application(target: .init(displayName: text,
                bundleIdentifier: index % 18 == 0 ? nil : (index % 18 == 6 ? "" : "synthetic.\(text)"),
                applicationPath: "/Synthetic/\(text).app"), mode: index % 12 == 0 ? .activateExisting : .newWindow)
        case 1: action = .finderFolder(path: text)
        case 2: action = .terminal(fallbackPath: text, useFrontmostFinder: index % 12 == 2)
        case 3: action = .showDesktop
        case 4: action = .windowLayout(WindowLayout.allCases[(index / 6) % 8])
        default: action = .remap(to: target)
        }
        return .init(id: UUID(uuid: (UInt8(truncatingIfNeeded: index), 255, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13)),
            name: text, source: source, action: action, isEnabled: index % 3 != 0)
    }
}

@Test func shortcutRuleJSONMatchesNativeEncoder() throws {
    for count in [0, 1, 96, 512] {
        let rules = codecRules(count)
        let actual = try ShortcutRuleJSON.encode(rules)
        let expected = try referenceRuleJSON(rules)
        let actualObject = try JSONSerialization.jsonObject(with: actual) as! NSArray
        let expectedObject = try JSONSerialization.jsonObject(with: expected) as! NSArray
        #expect(actualObject == expectedObject)
        // Canonical re-encoding compares literal Unicode bytes in every nested string as well.
        let canonicalActual = try JSONSerialization.data(withJSONObject: actualObject, options: [.sortedKeys])
        let canonicalExpected = try JSONSerialization.data(withJSONObject: expectedObject, options: [.sortedKeys])
        #expect(canonicalActual == canonicalExpected)
        // Decode both with the unchanged legacy parser: unknown logical bits are masked on load.
        let actualRules = try JSONDecoder().decode([ShortcutRule].self, from: actual)
        let expectedRules = try JSONDecoder().decode([ShortcutRule].self, from: expected)
        #expect(actualRules == expectedRules)
        #expect(try ShortcutRuleJSON.encode(rules) == actual)
    }
}

@Test func shortcutRuleJSONSaveReopensWithLegacyFormat() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ShortcutRuleStore(fileURL: directory.appendingPathComponent("rules.json"))
    let rules = codecRules(192)
    try store.save(rules)
    let saved = try Data(contentsOf: store.fileURL)
    let nativeDecoded = try JSONDecoder().decode([ShortcutRule].self, from: referenceRuleJSON(rules))
    let reopened = try store.load()
    #expect(reopened == nativeDecoded)
    #expect(try JSONSerialization.jsonObject(with: saved) is NSArray)
    // Legacy native files remain accepted; no envelope or schema migration is introduced.
    try referenceRuleJSON(rules).write(to: store.fileURL)
    let oldReopened = try store.load()
    #expect(oldReopened == nativeDecoded)
    try store.save([])
    let empty = try store.load()
    #expect(empty.isEmpty)
}

@Test func shortcutRuleJSONConcurrentIndependentBuffers() async throws {
    let rules = codecRules(96)
    let expected = try ShortcutRuleJSON.encode(rules)
    try await withThrowingTaskGroup(of: Data.self) { group in
        for _ in 0..<128 { group.addTask { try ShortcutRuleJSON.encode(rules) } }
        for try await value in group { #expect(value == expected) }
    }
    // Returned Data owns Rust output after the native input arena and rows have gone away.
    let decoded = try JSONDecoder().decode([ShortcutRule].self, from: expected)
    #expect(decoded.count == rules.count)
}

@Test func shortcutRuleJSONReleaseBenchmark() throws {
    guard ProcessInfo.processInfo.environment["AETHER_RULE_CODEC_BENCHMARK"] == "1" else { return }
    let rules = codecRules(3000)
    var native: [Double] = [], rust: [Double] = []
    for round in 0..<7 {
        for backend in (round.isMultiple(of: 2) ? [0, 1] : [1, 0]) {
            let start = DispatchTime.now().uptimeNanoseconds
            var data = Data()
            for _ in 0..<5 { data = try backend == 0 ? referenceRuleJSON(rules) : ShortcutRuleJSON.encode(rules) }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            if backend == 0 { native.append(elapsed) } else { rust.append(elapsed) }
            #expect(try JSONDecoder().decode([ShortcutRule].self, from: data).count == rules.count)
        }
    }
    let result: [String: Any] = ["rules": rules.count, "encodes_per_round": 5, "native_ms": native, "rust_ms": rust,
        "native_median_ms": native.sorted()[3], "rust_median_ms": rust.sorted()[3]]
    let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    print("RULE_CODEC_BENCHMARK " + String(decoding: data, as: UTF8.self))
}
