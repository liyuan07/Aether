// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import ShortcutCore

private let ruleDecodeBase = #"[{"id":"01234567-89ab-cdef-0123-456789abcdef","name":"合成","source":{"keyCode":45,"modifiers":255},"action":{"showDesktop":{}},"isEnabled":true}]"#

private func decodeErrorSignature(_ error: Error) -> String {
    func context(_ context: DecodingError.Context) -> String {
        context.codingPath.map { "\($0.stringValue):\($0.intValue.map(String.init) ?? "nil")" }.joined(separator: "/") + ":" + context.debugDescription
    }
    switch error {
    case let DecodingError.dataCorrupted(c): return "corrupt:" + context(c)
    case let DecodingError.keyNotFound(key, c): return "key:" + key.stringValue + ":" + context(c)
    case let DecodingError.typeMismatch(type, c): return "type:" + String(describing: type) + ":" + context(c)
    case let DecodingError.valueNotFound(type, c): return "value:" + String(describing: type) + ":" + context(c)
    default: return String(describing: type(of: error))
    }
}

private func compareRuleDecoders(_ data: Data, coreRequired: Bool = false) throws {
    let reference = Result { try JSONDecoder().decode([ShortcutRule].self, from: data) }
    let actual = Result { try ShortcutRuleJSON.decode(data) }
    let core = ShortcutRuleJSON.decodeCore(data)
    if coreRequired { #expect(core != nil) }
    switch (reference, actual) {
    case let (.success(expected), .success(value)):
        #expect(value == expected)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Byte comparison catches normalization or accidental string alteration in nested fields.
        #expect(try encoder.encode(value) == encoder.encode(expected))
        if let core { #expect(try encoder.encode(core) == encoder.encode(expected)) }
    case let (.failure(expected), .failure(error)):
        #expect(core == nil)
        #expect(decodeErrorSignature(error) == decodeErrorSignature(expected))
    default:
        Issue.record("Rule decoder disagrees with independent Foundation reference")
    }
}

@Test func shortcutRuleDecodeAllNativeAndRustFixtures() throws {
    for count in [0, 1, 96, 512] {
        let rules = codecRules(count)
        try compareRuleDecoders(JSONEncoder().encode(rules), coreRequired: true)
        try compareRuleDecoders(ShortcutRuleJSON.encode(rules), coreRequired: true)
    }
}

@Test func shortcutRuleDecodeLegacyCompatibilityMatrix() throws {
    let replacements: [(String, [String])] = [
        (#""keyCode":45"#, [#""keyCode":0"#, #""keyCode":65535"#, #""keyCode":65536"#, #""keyCode":-1"#, #""keyCode":-0"#, #""keyCode":45.0"#, #""keyCode":4.5e1"#, #""keyCode":0e999999"#, #""keyCode":1.0000000000000001"#, #""keyCode":null"#, #""keyCode":"45"#, #""keyCode":true"#, #""keyCode":{}"#]),
        (#""modifiers":255"#, [#""modifiers":0"#, #""modifiers":256"#, #""modifiers":15.0"#, #""modifiers":1.5e1"#, #""modifiers":null"#, #""modifiers":{"rawValue":15}"#, #""modifiers":15,"physicalModifiers":null"#, #""modifiers":15,"physicalModifiers":65535"#, #""modifiers":15,"physicalModifiers":65536"#, #""modifiers":15,"physicalModifiers":6.5535e4"#]),
        (#""name":"合成""#, [#""name":null"#, #""name":false"#, #""name":"a\u0000b\n👨‍👩‍👧‍👦""#, #""name":"cafe\u0301""#, #""name":"\ud800""#, #""name":"\udc00""#, #""name":"\ud83d\ude00""#, #""name":"first","name":null"#, #""name":null,"name":"second""#]),
        (#""showDesktop":{}"#, [#""showDesktop":null"#, #""showDesktop":[]"#, #""showDesktop":0"#, #""showDesktop":{"ignored":1}"#, #""showDesktop":{},"ignored":{"deep":[{}]}"#, #""showDesktop":{},"finderFolder":{"path":"x"}"#, #""showDesktop":{},"showDesktop":null"#, #""unknown":{}"#, #""finderFolder":{"path":"合成\u0000路径"}"#, #""terminal":{"fallbackPath":"","useFrontmostFinder":true}"#, #""windowLayout":{"_0":"leftHalf"}"#, #""windowLayout":{"_0":"invalid"}"#, #""remap":{"to":{"keyCode":65535,"modifiers":255,"physicalModifiers":65535}}"#]),
        (#""source":{"keyCode":45,"modifiers":255}"#, [#""source":null"#, #""source":[45,255]"#, #""source":{}"#, #""source":{"keyCode":45,"modifiers":15,"keyCode":null}"#]),
        (#""isEnabled":true"#, [#""isEnabled":false"#, #""isEnabled":1"#, #""isEnabled":null"#, #""isEnabled":true,"ignored":"\ud800""#, #""isEnabled":true,"ignored":1e9999"#, #""isEnabled":true,"ignored":[1e9999]"#]),
        (#"01234567-89ab-cdef-0123-456789abcdef"#, ["01234567-89AB-CDEF-0123-456789ABCDEF", "0123456789abcdef0123456789abcdef", "{01234567-89ab-cdef-0123-456789abcdef}", "invalid", "00000000-0000-0000-0000-000000000000"])
    ]
    for (original, values) in replacements {
        for value in values {
            let source = ruleDecodeBase.replacingOccurrences(of: original, with: value)
            try compareRuleDecoders(Data(source.utf8))
        }
    }
    for text in ["", "null", "{}", "true", "1", "[null]", "[[]]", "[{}]", ruleDecodeBase + "x", "[" + ruleDecodeBase + "]"] {
        try compareRuleDecoders(Data(text.utf8))
    }
    for encoding in [String.Encoding.utf8, .utf16, .utf16BigEndian, .utf16LittleEndian, .utf32, .utf32BigEndian, .utf32LittleEndian] {
        try compareRuleDecoders(ruleDecodeBase.data(using: encoding)!)
    }
    try compareRuleDecoders(Data([0xef, 0xbb, 0xbf]) + Data(ruleDecodeBase.utf8))
    try compareRuleDecoders(Data([0xff, 0x00]))
    for depth in [120, 510, 511, 512, 513] {
        let unknown = String(repeating: "[", count: depth) + "0" + String(repeating: "]", count: depth)
        let source = ruleDecodeBase.replacingOccurrences(of: #""isEnabled":true"#, with: #""isEnabled":true,"ignored":"# + unknown)
        try compareRuleDecoders(Data(source.utf8))
    }
}



@Test func shortcutRuleDecodeExactNumericRepresentations() throws {
    for value in [0, 1, 15, 255, 256, 65535, 65536] {
        for zeroes in [0, 1, 10, 100, 1000] {
            let tail = String(repeating: "0", count: zeroes)
            let representations = ["\(value).\(tail)0", "\(value)\(tail)e-\(zeroes)", "0.\(tail)\(value)e\(zeroes + String(value).count)"]
            for number in representations {
                for field in ["keyCode", "modifiers"] {
                    let token = field == "keyCode" ? #""keyCode":45"# : #""modifiers":255"#
                    let source = ruleDecodeBase.replacingOccurrences(of: token, with: "\"\(field)\":\(number)")
                    try compareRuleDecoders(Data(source.utf8))
                }
            }
        }
    }
}

@Test func shortcutRuleDecodeCoreLegacySemantics() throws {
    for (original, replacement) in [
        (#""keyCode":45"#, #""keyCode":45.0"#),
        (#""keyCode":45"#, #""keyCode":4.5e1"#),
        (#""keyCode":45"#, #""keyCode":-0"#),
        (#""modifiers":255"#, #""modifiers":255,"physicalModifiers":null"#),
        (#""modifiers":255"#, #""modifiers":255,"physicalModifiers":65535.0"#),
        (#""name":"合成""#, #""name":"first","name":null"#),
        (#""showDesktop":{}"#, #""unknown":[],"showDesktop":{},"showDesktop":null"#),
        (#""showDesktop":{}"#, #""finderFolder":{"path":"first","path":null}"#),
        (#""source":{"keyCode":45,"modifiers":255}"#, #""source":{"keyCode":45,"modifiers":15,"keyCode":null}"#)
    ] {
        try compareRuleDecoders(Data(ruleDecodeBase.replacingOccurrences(of: original, with: replacement).utf8), coreRequired: true)
    }
}

@Test func shortcutRuleDecodeGeneratedStructuralMutations() throws {
    let rules = codecRules(96)
    let data = try JSONEncoder().encode(rules)
    let objects = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
    let values: [Any] = [NSNull(), true, false, 0, 1, -1, 65535, 65536, "", "unknown", [], [:], ["rawValue": 15]]
    for object in objects.prefix(24) {
        for key in ["id", "name", "source", "action", "isEnabled"] {
            var missing = object; missing.removeValue(forKey: key)
            try compareRuleDecoders(JSONSerialization.data(withJSONObject: [missing]))
            for value in values {
                var changed = object; changed[key] = value
                try compareRuleDecoders(JSONSerialization.data(withJSONObject: [changed]))
            }
        }
        if let actions = object["action"] as? [String: Any], let kind = actions.keys.first,
           let payload = actions[kind] as? [String: Any] {
            if let target = payload["target"] as? [String: Any] {
                for key in ["displayName", "bundleIdentifier", "applicationPath"] {
                    var missing = target; missing.removeValue(forKey: key)
                    var changed = object; var action = payload; action["target"] = missing; changed["action"] = [kind: action]
                    try compareRuleDecoders(JSONSerialization.data(withJSONObject: [changed]))
                    for value in values {
                        var target = target; target[key] = value
                        var changed = object; var action = payload; action["target"] = target; changed["action"] = [kind: action]
                        try compareRuleDecoders(JSONSerialization.data(withJSONObject: [changed]))
                    }
                }
            }
            for key in payload.keys {
                for value in values {
                    var changed = object; var action = payload; action[key] = value; changed["action"] = [kind: action]
                    try compareRuleDecoders(JSONSerialization.data(withJSONObject: [changed]))
                }
            }
        }
    }
}

@Test func shortcutRuleDecodeConcurrentOwnedOutput() async throws {
    let data = try ShortcutRuleJSON.encode(codecRules(96))
    let expected = try JSONDecoder().decode([ShortcutRule].self, from: data)
    try await withThrowingTaskGroup(of: [ShortcutRule].self) { group in
        for _ in 0..<128 { group.addTask { try ShortcutRuleJSON.decode(data) } }
        for try await rules in group { #expect(rules == expected) }
    }
    // Native values survive Rust owner destruction and release of the caller's input Data.
    let copied = ShortcutRuleJSON.decodeCore(try ShortcutRuleJSON.encode(codecRules(512)))!
    #expect(copied.count == 512)
    #expect(copied.last?.name.utf8.elementsEqual(codecRules(512).last!.name.utf8) == true)
}

@Test func shortcutRuleDecodeReleaseBenchmark() throws {
    guard ProcessInfo.processInfo.environment["AETHER_RULE_DECODE_BENCHMARK"] == "1" else { return }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(codecRules(3000))
    let expected = try JSONDecoder().decode([ShortcutRule].self, from: data)
    #expect(ShortcutRuleJSON.decodeCore(data) != nil)
    var native: [Double] = [], rust: [Double] = []
    for round in 0..<7 {
        for backend in (round.isMultiple(of: 2) ? [0, 1] : [1, 0]) {
            let start = DispatchTime.now().uptimeNanoseconds
            var rules: [ShortcutRule] = []
            for _ in 0..<5 { rules = try backend == 0 ? JSONDecoder().decode([ShortcutRule].self, from: data) : ShortcutRuleJSON.decode(data) }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            if backend == 0 { native.append(elapsed) } else { rust.append(elapsed) }
            #expect(rules == expected)
        }
    }
    let result: [String: Any] = ["rules": expected.count, "decodes_per_round": 5, "input_bytes": data.count,
        "native_ms": native, "rust_ms": rust, "native_median_ms": native.sorted()[3], "rust_median_ms": rust.sorted()[3]]
    let resultData = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    print("RULE_DECODE_BENCHMARK " + String(decoding: resultData, as: UTF8.self))
}
