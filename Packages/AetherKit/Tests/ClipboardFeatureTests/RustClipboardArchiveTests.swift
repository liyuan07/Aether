// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
import CAetherCore
import RustCore
@testable import ClipboardFeature

final class RustClipboardArchiveTests: XCTestCase {
    func testTypedWriterPreservesNilEmptyAndRejectsInvalidDatesWithoutReplacement() throws {
        let context = Context(); defer { context.cleanup() }
        for groups: [ClipboardGroup]? in [nil, [], [ClipboardGroup(items: [])]] {
            let archive = ClipboardArchive(history: [], pinnedItems: [], groups: groups)
            try context.store.save(archive)
            let bytes = try Data(contentsOf: context.file)
            let native = try JSONDecoder().decode(ClipboardArchive.self, from: bytes)
            XCTAssertEqual(try encodedObject(native), try encodedObject(archive))
            for interval in [Double.nan, Double.infinity, -Double.infinity] {
                let item = ClipboardItem(stringData: "synthetic", type: .text, timestamp: Date(timeIntervalSinceReferenceDate: interval))
                let invalid = ClipboardArchive(history: [item], pinnedItems: [], groups: groups)
                XCTAssertThrowsError(try JSONEncoder().encode(invalid))
                XCTAssertThrowsError(try context.store.save(invalid))
                XCTAssertEqual(try Data(contentsOf: context.file), bytes)
            }
        }
    }

    func testTypedWriterRejectsMalformedSpanMetadata() throws {
        let context = Context(); defer { context.cleanup() }
        let owner = context.file.withUnsafeFileSystemRepresentation { aether_clipboard_archive_create($0) }
        defer { aether_clipboard_archive_destroy(owner) }
        for counts in [(1, 0, 0), (0, 1, 0), (0, 0, 1), (Int.max, 1, 0)] {
            XCTAssertNotEqual(aether_clipboard_archive_write_records(owner, nil, 0, counts.0, counts.1,
                nil, 0, nil, counts.2, 0), 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: context.file.path))
        }
        XCTAssertNotEqual(aether_clipboard_archive_write_records(owner, nil, 1, 0, 0, nil, 0, nil, 0, 0), 0)
        XCTAssertNotEqual(aether_clipboard_archive_write_records(owner, nil, 0, 0, 0, nil, 1, nil, 0, 0), 0)
    }

    func testArchiveSaveBenchmark() throws {
        guard ProcessInfo.processInfo.environment["AETHER_RUN_CORE_BENCHMARKS"] == "1" else { throw XCTSkip("Run explicitly with synthetic archive") }
        let context = Context(); defer { context.cleanup() }
        let archive = ClipboardArchive(history: (0..<10_000).map { ClipboardItem(stringData: "synthetic clipboard item \($0)", type: .text) }, pinnedItems: [], groups: [])
        let old = context.file.withUnsafeFileSystemRepresentation { aether_clipboard_archive_create($0) }
        defer { aether_clipboard_archive_destroy(old) }
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<5 {
            let bytes = try JSONEncoder().encode(archive)
            XCTAssertEqual(bytes.withUnsafeBytes {
                aether_clipboard_archive_write(old, .init(data: $0.bindMemory(to: UInt8.self).baseAddress, length: $0.count))
            }, 0)
        }
        let oldNS = DispatchTime.now().uptimeNanoseconds - start
        let native = try JSONDecoder().decode(ClipboardArchive.self, from: Data(contentsOf: context.file))
        let newStart = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<5 { try context.store.save(archive) }
        let newNS = DispatchTime.now().uptimeNanoseconds - newStart
        XCTAssertEqual(try encodedObject(XCTUnwrap(context.store.load())), try encodedObject(native))
        print("AETHER_ARCHIVE_SAVE_BENCHMARK items=10000 iterations=5 old_ns=\(oldNS) rust_records_ns=\(newNS)")
    }
    func testDecodedRecordsPreserveEveryFieldAndOutliveRustOwner() throws {
        let context = Context(); defer { context.cleanup() }
        let uuid = "12345678-1234-5678-90AB-1234567890AB"
        let texts = ["", "合成\u{0000}👨‍👩‍👧‍👦", "a\u{301}", "\\\"\r\n", "file:///synthetic/%E4%B8%AD%E6%96%87", String(repeating: "长", count: 128)]
        let items: [[String: Any]] = (0..<3_000).map { index in
            var item: [String: Any] = ["id": uuid, "timestamp": Double(index) * 0.125 - 500,
                "type": ["text", "url", "file", "image", "rtf", "unknown"][index % 6], "isPinned": index % 2 == 0]
            for (offset, field) in ["preview", "stringData", "imageFileName", "imageContentHash", "rtfFileName"].enumerated() {
                if index % (offset + 2) != 0 { item[field] = texts[(index + offset) % texts.count] }
            }
            if index % 3 != 0 { item["fileURLs"] = index % 2 == 0 ? [] : texts }
            if index % 4 != 0 { item["rtfData"] = Data(texts[index % texts.count].utf8).base64EncodedString() }
            return item
        }
        let fixture: [String: Any] = ["history": items, "pinnedItems": Array(items.prefix(100)),
            "groups": [["id": uuid, "timestamp": -1.25, "items": Array(items.suffix(150))]]]
        let bytes = try JSONSerialization.data(withJSONObject: fixture)
        try context.put(bytes)
        let expected = try JSONDecoder().decode(ClipboardArchive.self, from: bytes)
        // load destroys the Rust owner before returning; all native values must remain usable.
        let actual = try XCTUnwrap(context.store.load())
        XCTAssertEqual(try encodedObject(actual), try encodedObject(expected))
        XCTAssertEqual(actual.history[1].stringData?.utf8.map { $0 }, expected.history[1].stringData?.utf8.map { $0 })
        XCTAssertEqual(try Data(contentsOf: context.file), bytes)
        try context.store.save(actual)
        XCTAssertEqual(try encodedObject(XCTUnwrap(context.store.load())), try encodedObject(expected))
    }

    func testArchiveLoadBenchmark() throws {
        guard ProcessInfo.processInfo.environment["AETHER_RUN_CORE_BENCHMARKS"] == "1" else { throw XCTSkip("Run explicitly with synthetic archive") }
        let context = Context(); defer { context.cleanup() }
        let uuid = "12345678-1234-5678-90AB-1234567890AB"
        let fixture: [String: Any] = ["history": (0..<10_000).map { index in
            ["id": uuid, "timestamp": index, "type": "text", "stringData": "synthetic clipboard item \(index)", "preview": "synthetic preview", "isPinned": false] as [String: Any]
        }, "pinnedItems": [], "groups": []]
        try context.put(JSONSerialization.data(withJSONObject: fixture))
        let old = context.file.withUnsafeFileSystemRepresentation { aether_clipboard_archive_create($0) }
        defer { aether_clipboard_archive_destroy(old) }
        var oldCount = 0, newCount = 0
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<5 {
            let bytes = try RustBuffer.take(aether_clipboard_archive_read(old))
            oldCount += try JSONDecoder().decode(ClipboardArchive.self, from: bytes).history.count
        }
        let oldNS = DispatchTime.now().uptimeNanoseconds - start
        let newStart = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<5 { newCount += try XCTUnwrap(context.store.load()).history.count }
        let newNS = DispatchTime.now().uptimeNanoseconds - newStart
        XCTAssertEqual(oldCount, newCount)
        print("AETHER_ARCHIVE_LOAD_BENCHMARK items=10000 iterations=5 old_ns=\(oldNS) rust_owned_ns=\(newNS)")
    }

    private func encodedObject(_ archive: ClipboardArchive) throws -> NSDictionary {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(archive)) as? NSDictionary)
    }
    func testSchemaValidationMatchesNativeLegacyDTOCodec() throws {
        let uuid = UUID().uuidString
        let values: [String: [Any]] = [
            "id": [NSNull(), uuid, uuid.lowercased(), uuid.replacingOccurrences(of: "-", with: ""), "{\(uuid)}", "bad", 1],
            "type": [NSNull(), "text", "url", "file", "image", "rtf", "unknown", "future", 1],
            "timestamp": [NSNull(), 0, -123.125, 812345678.9876543, "0", true],
            "isPinned": [NSNull(), true, false, 1, "true"],
            "preview": [NSNull(), "合成\u{0000}👨‍👩‍👧‍👦", 1, [:]],
            "stringData": [NSNull(), "a\u{301}", 1, []],
            "imageFileName": [NSNull(), "中文.png", 1],
            "imageContentHash": [NSNull(), "synthetic-hash", 1],
            "fileURLs": [NSNull(), [], ["file:///synthetic/中文"], [1], "wrong"],
            "rtfData": [NSNull(), "", "Zg==", "Zh==", "Zg", "Zg=", "====", "YWJj", "YWJj\n", "a===", "AB==", "========", "AA====", "AAAA=", "=AAA", "AA=AA", 1],
            "rtfFileName": [NSNull(), "合成.rtf", 1]
        ]
        for (field, values) in values {
            for value in values {
                try assertParity(["history": [[field: value]], "pinnedItems": []])
            }
        }
        for groups: Any in [NSNull(), [], [:], [["id": uuid, "timestamp": 0, "items": [[:]]]],
            [["id": uuid, "items": []]], [["id": "bad", "timestamp": 0, "items": []]],
            [["id": uuid, "timestamp": 0, "items": NSNull()]]] {
            try assertParity(["history": [], "pinnedItems": [], "groups": groups])
        }
        for fixture: Any in [[:], [], NSNull(), ["history": []], ["history": [], "pinnedItems": []],
            ["history": [], "pinnedItems": [], "unknownLegacyField": ["ignored": true]]] {
            try assertParity(fixture)
        }
        // The legacy DTO accepts JSON integer and fractional date representations without changing format.
        for time in ["0.0", "1e2", "1e309", "-1e309"] {
            let bytes = Data("{\"history\":[{\"timestamp\":\(time)}],\"pinnedItems\":[]}".utf8)
            XCTAssertEqual(validate(bytes), nativeAccepts(bytes))
        }
    }
    func testUnknownNestedMetadataMatchesNativeDecoder() {
        for depth in [1, 127, 128, 256, 511, 512, 513] {
            let nested = String(repeating: "[", count: depth) + "0" + String(repeating: "]", count: depth)
            let bytes = Data("{\"history\":[],\"pinnedItems\":[],\"unknown\":\(nested)}".utf8)
            XCTAssertEqual(validate(bytes), nativeAccepts(bytes), "depth \(depth)")
            assertDecodedAcceptance(bytes)
        }
    }
    func testDuplicateKeysKeepNativeFirstOccurrence() {
        let fixtures = [
            "{\"history\":[],\"history\":false,\"pinnedItems\":[]}",
            "{\"history\":false,\"history\":[],\"pinnedItems\":[]}",
            "{\"history\":[{\"stringData\":\"first\",\"stringData\":123}],\"pinnedItems\":[]}",
            "{\"history\":[{\"stringData\":123,\"stringData\":\"second\"}],\"pinnedItems\":[]}",
            "{\"history\":[{\"timestamp\":0,\"timestamp\":\"bad\"}],\"pinnedItems\":[]}",
            "{\"history\":[],\"pinnedItems\":[],\"groups\":null,\"groups\":false}"
        ]
        for fixture in fixtures {
            let data = Data(fixture.utf8)
            XCTAssertEqual(validate(data), nativeAccepts(data))
            assertDecodedAcceptance(data)
        }
    }

    func testMissingAndLegacyDefaultsAreLoadedWithoutRewritingFile() throws {
        let context = Context(); defer { context.cleanup() }
        XCTAssertNil(try context.store.load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.root.path))
        let bytes = Data("{\"history\":[{}, {\"id\":null,\"type\":null,\"isPinned\":null,\"stringData\":\"合成正文\"}],\"pinnedItems\":[],\"groups\":null}".utf8)
        try context.put(bytes)
        let before = Date()
        let loaded = try XCTUnwrap(context.store.load())
        let after = Date()
        XCTAssertEqual(loaded.history.map(\.type), [.unknown, .unknown])
        XCTAssertEqual(loaded.history.map(\.isPinned), [false, false])
        XCTAssertNotEqual(loaded.history[0].id, loaded.history[1].id)
        for item in loaded.history { XCTAssertGreaterThanOrEqual(item.timestamp, before); XCTAssertLessThanOrEqual(item.timestamp, after) }
        XCTAssertEqual(loaded.history[1].preview, "合成正文")
        XCTAssertEqual(try Data(contentsOf: context.file), bytes)
        try context.store.save(loaded)
        let reopened = try XCTUnwrap(RustClipboardArchive(fileURL: context.file).load())
        XCTAssertEqual(reopened.history.map(\.id), loaded.history.map(\.id))
        XCTAssertEqual(reopened.history.map(\.timestamp), loaded.history.map(\.timestamp))
        XCTAssertEqual(reopened.history.map(\.preview), loaded.history.map(\.preview))
    }
    func testCorruptArchiveCannotBeReplacedUntilExplicitRepairLoad() throws {
        let context = Context(); defer { context.cleanup() }
        let invalid = Data("{\"history\":[{\"type\":\"future\"}],\"pinnedItems\":[]}".utf8)
        try context.put(invalid)
        let empty = ClipboardArchive(history: [], pinnedItems: [], groups: [])
        XCTAssertThrowsError(try context.store.load())
        XCTAssertThrowsError(try context.store.save(empty))
        XCTAssertThrowsError(try RustClipboardArchive(fileURL: context.file).save(empty))
        XCTAssertEqual(try Data(contentsOf: context.file), invalid)
        let repaired = Data("{\"history\":[],\"pinnedItems\":[]}".utf8)
        try context.put(repaired)
        XCTAssertThrowsError(try context.store.save(empty))
        XCTAssertNotNil(try context.store.load())
        try context.store.save(empty)
        XCTAssertNotNil(try context.store.load())
    }
    func testExternalInvalidFileAfterLoadBlocksSaveAndCleanup() throws {
        let context = Context(); defer { context.cleanup() }
        let empty = ClipboardArchive(history: [], pinnedItems: [], groups: [])
        try context.store.save(empty)
        XCTAssertNotNil(try context.store.load())
        let bytes = Data("{ corrupted synthetic archive".utf8)
        try context.put(bytes)
        XCTAssertThrowsError(try context.store.save(empty))
        XCTAssertEqual(try Data(contentsOf: context.file), bytes)
    }
    private func assertParity(_ fixture: Any, file: StaticString = #filePath, line: UInt = #line) throws {
        let bytes = try JSONSerialization.data(withJSONObject: fixture, options: [.fragmentsAllowed])
        XCTAssertEqual(validate(bytes), nativeAccepts(bytes), "Synthetic fixture: " + String(decoding: bytes, as: UTF8.self), file: file, line: line)
        let context = Context(); defer { context.cleanup() }
        try context.put(bytes)
        XCTAssertEqual((try? context.store.load()) != nil, nativeAccepts(bytes), file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: context.file), bytes, file: file, line: line)
    }
    private func assertDecodedAcceptance(_ bytes: Data, file: StaticString = #filePath, line: UInt = #line) {
        let context = Context(); defer { context.cleanup() }
        do {
            try context.put(bytes)
            XCTAssertEqual((try? context.store.load()) != nil, nativeAccepts(bytes), file: file, line: line)
            XCTAssertEqual(try Data(contentsOf: context.file), bytes, file: file, line: line)
        } catch { XCTFail("Synthetic fixture setup failed", file: file, line: line) }
    }
    private func validate(_ bytes: Data) -> Bool {
        bytes.withUnsafeBytes { aether_clipboard_archive_validate(.init(data: $0.bindMemory(to: UInt8.self).baseAddress, length: $0.count)) == 0 }
    }
    private func nativeAccepts(_ bytes: Data) -> Bool { (try? JSONDecoder().decode(ClipboardArchive.self, from: bytes)) != nil }
}
private struct Context {
    let root: URL, file: URL, store: RustClipboardArchive
    init() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AetherArchiveTests-\(UUID())")
        file = root.appendingPathComponent("history.json")
        store = RustClipboardArchive(fileURL: file)
    }
    func put(_ bytes: Data) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try bytes.write(to: file)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}
