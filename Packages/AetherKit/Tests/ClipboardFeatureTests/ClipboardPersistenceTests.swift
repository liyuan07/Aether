// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import ClipboardFeature

final class ClipboardPersistenceTests: XCTestCase {
    func testResourceReferencesAreIndependentOfItemTypeAndPreserveLinkedTargets() throws {
        let context = try Context(); defer { context.cleanup() }
        var item = ClipboardItem(stringData: "合成", type: .unknown)
        item.imageFileName = "á.png"; item.rtfFileName = "a\u{301}.rtf"
        try context.create("a\u{301}.png", in: context.images)
        try context.create("á.rtf", in: context.payloads)
        let external = context.root.appendingPathComponent("external")
        try Data([4,5,6]).write(to: external)
        let link = context.images.appendingPathComponent("unreferenced-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
        let folder = context.payloads.appendingPathComponent("unreferenced-folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try context.create("child", in: folder)
        let archive = ClipboardArchive(history: [], pinnedItems: [], groups: [.init(items: [item, item])])
        context.writer.enqueue(archive, cleanup: true); context.writer.flush(archive)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: context.images.path)), ["á.png"])
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: context.payloads.path)), ["á.rtf"])
        XCTAssertEqual(try Data(contentsOf: external), Data([4,5,6]))
    }
    func testCleanupFollowsSuccessfulSaveAndContinuesAfterPlatformFailures() throws {
        let manager = CheckingFileManager()
        let context = try Context(fileManager: manager); defer { context.cleanup() }
        manager.archive = context.archive
        try context.create("failed.rtf", in: context.payloads)
        try context.create("remove.rtf", in: context.payloads)
        let empty = ClipboardArchive(history: [], pinnedItems: [], groups: [])
        context.writer.enqueue(empty, cleanup: true); context.writer.flush(empty)
        XCTAssertEqual(manager.enumerated, ["Images", "Payloads"])
        XCTAssertTrue(manager.archiveWasSavedBeforeEveryEnumeration)
        XCTAssertTrue(FileManager.default.fileExists(atPath: context.payloads.appendingPathComponent("failed.rtf").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.payloads.appendingPathComponent("remove.rtf").path))
        let original = try Data(contentsOf: context.archive)
        try Data("{ corrupt synthetic}".utf8).write(to: context.archive)
        manager.enumerated = []
        context.writer.enqueue(empty, cleanup: true); context.writer.flush(empty)
        XCTAssertTrue(manager.enumerated.isEmpty)
        try original.write(to: context.archive)
    }
    func testResourceCleanupReleaseBenchmark() throws {
        guard ProcessInfo.processInfo.environment["AETHER_CLIPBOARD_CLEANUP_BENCHMARK"] == "1" else { throw XCTSkip("Synthetic Release benchmark only") }
        let context = try Context(); defer { context.cleanup() }
        let store = RustClipboardArchive(fileURL: context.archive)
        let unique = ProcessInfo.processInfo.environment["AETHER_CLIPBOARD_CLEANUP_UNIQUE"] == "1"
        let prefix = ProcessInfo.processInfo.environment["AETHER_CLIPBOARD_CLEANUP_NONASCII"] == "1" ? "合成-" : ""
        let items = (0..<10_000).map { index in
            var item = ClipboardItem(stringData: "synthetic \(index)", type: .text)
            item.imageFileName = "\(prefix)image-\(unique ? index : index % 32).png"
            item.rtfFileName = "\(prefix)payload-\(unique ? index : index % 32).rtf"
            return item
        }
        let archive = ClipboardArchive(history: Array(items.prefix(8000)), pinnedItems: Array(items[8000..<9000]), groups: [.init(items: Array(items.suffix(1000)))])
        for index in 0..<32 {
            try context.create("\(prefix)image-\(index).png", in: context.images)
            try context.create("\(prefix)payload-\(index).rtf", in: context.payloads)
        }
        func legacy() throws {
            try store.save(archive)
            let all = archive.history + archive.pinnedItems + (archive.groups ?? []).flatMap(\.items)
            func remove(in directory: URL, keeping names: [String]) {
                guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
                for index in rustClipboardUnreferencedResources(keeping: names, files: files.map(\.lastPathComponent)) {
                    try? FileManager.default.removeItem(at: files[index])
                }
            }
            remove(in: context.images, keeping: all.compactMap(\.imageFileName))
            remove(in: context.payloads, keeping: all.compactMap(\.rtfFileName))
        }
        func current() throws {
            try store.save(archive, cleanup: ClipboardResourceFiles(images: context.images, payloads: context.payloads))
        }
        try autoreleasepool { try legacy(); try current() }
        var old: [Double] = [], new: [Double] = []
        for round in 0..<7 {
            for variant in round % 2 == 0 ? [0,1] : [1,0] {
                let start = DispatchTime.now().uptimeNanoseconds
                for _ in 0..<5 { try autoreleasepool { if variant == 0 { try legacy() } else { try current() } } }
                let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                if variant == 0 { old.append(ms) } else { new.append(ms) }
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: context.images.path).count, 32)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: context.payloads.path).count, 32)
                XCTAssertEqual(try XCTUnwrap(store.load()).history.count, 8000)
            }
        }
        let result: [String: Any] = ["scenario":(prefix.isEmpty ? "ascii-" : "unicode-") + (unique ? "unique-references" : "repeated-references"), "old_ms":old, "new_ms":new, "old_median_ms":old.sorted()[3], "new_median_ms":new.sorted()[3], "items":10000, "files":64, "operations_per_round":5]
        print("CLIPBOARD_CLEANUP_BENCHMARK " + String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
    }
    func testCoalescedCleanupKeepsHistoryPinsAndGroupReferences() throws {
        let context = try Context()
        defer { context.cleanup() }
        for name in ["保留.png", "组内.png", "á.png", "旧.png"] { try context.create(name, in: context.images) }
        for name in ["正文.rtf", "旧.rtf"] { try context.create(name, in: context.payloads) }
        var image = ClipboardItem(stringData: "合成", type: .image); image.imageFileName = "保留.png"
        var groupImage = ClipboardItem(stringData: "合成", type: .image); groupImage.imageFileName = "组内.png"
        var rich = ClipboardItem(stringData: "合成", type: .rtf); rich.rtfFileName = "正文.rtf"
        var canonicalImage = ClipboardItem(stringData: "合成", type: .image); canonicalImage.imageFileName = "a\u{301}.png"
        let archive = ClipboardArchive(history: [image, canonicalImage], pinnedItems: [rich], groups: [.init(items: [groupImage])])
        context.writer.enqueue(.init(history: [], pinnedItems: [], groups: []), cleanup: true)
        context.writer.enqueue(archive, cleanup: false)
        context.writer.flush(archive)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: context.images.path)), ["保留.png", "组内.png", "á.png"])
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: context.payloads.path)), ["正文.rtf"])
        let saved = try JSONDecoder().decode(ClipboardArchive.self, from: Data(contentsOf: context.archive))
        XCTAssertEqual(saved.history.map(\.id), archive.history.map(\.id))
        XCTAssertEqual(saved.pinnedItems.map(\.id), archive.pinnedItems.map(\.id))
        XCTAssertEqual(saved.groups?.first?.items.map(\.id), [groupImage.id])
        // Flush resets a previous cleanup request; a later ordinary save preserves unreferenced files.
        try context.create("稍后.png", in: context.images)
        context.writer.enqueue(archive, cleanup: false)
        context.writer.flush(archive)
        XCTAssertTrue(FileManager.default.fileExists(atPath: context.images.appendingPathComponent("稍后.png").path))
    }
    func testFailedArchiveReplacementDoesNotRemoveAnyPayload() throws {
        let context = try Context()
        defer { context.cleanup() }
        try FileManager.default.createDirectory(at: context.archive, withIntermediateDirectories: true)
        let original = context.archive.appendingPathComponent("original")
        try Data([1,2,3]).write(to: original)
        try context.create("unreferenced.png", in: context.images)
        context.writer.enqueue(.init(history: [], pinnedItems: [], groups: []), cleanup: true)
        context.writer.flush(.init(history: [], pinnedItems: [], groups: []))
        XCTAssertEqual(try Data(contentsOf: original), Data([1,2,3]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: context.images.appendingPathComponent("unreferenced.png").path))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: context.root.path)), ["Images", "Payloads", "history.json"])
    }
    func testCorruptArchiveBlocksCleanupUntilExplicitRepairLoad() throws {
        let context = try Context()
        defer { context.cleanup() }
        let archive = ClipboardArchive(history: [], pinnedItems: [], groups: [])
        let valid = try JSONEncoder().encode(archive)
        try valid.write(to: context.archive)
        _ = try context.writer.load()
        let corrupt = Data("{invalid archive}".utf8)
        try corrupt.write(to: context.archive)
        try context.create("unreferenced.png", in: context.images)
        context.writer.enqueue(archive, cleanup: true)
        context.writer.flush(archive)
        XCTAssertEqual(try Data(contentsOf: context.archive), corrupt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: context.images.appendingPathComponent("unreferenced.png").path))
        try valid.write(to: context.archive)
        context.writer.enqueue(archive, cleanup: true)
        context.writer.flush(archive)
        XCTAssertTrue(FileManager.default.fileExists(atPath: context.images.appendingPathComponent("unreferenced.png").path))
        _ = try context.writer.load()
        context.writer.enqueue(archive, cleanup: true)
        context.writer.flush(archive)
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.images.appendingPathComponent("unreferenced.png").path))
    }
    func testDeferredWriteActuallyPersistsWithoutFlush() async throws {
        let context = try Context()
        defer { context.cleanup() }
        let item = ClipboardItem(stringData: "合成定时写入", type: .text)
        context.writer.enqueue(.init(history: [item], pinnedItems: [], groups: []), cleanup: false)
        let deadline = ContinuousClock().now.advanced(by: .seconds(3))
        while !FileManager.default.fileExists(atPath: context.archive.path), ContinuousClock().now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let saved = try JSONDecoder().decode(ClipboardArchive.self, from: Data(contentsOf: context.archive))
        XCTAssertEqual(saved.history.map(\.id), [item.id])
    }
}
private struct Context {
    let root: URL, images: URL, payloads: URL, archive: URL
    let writer: ClipboardPersistenceCoordinator
    init(fileManager: FileManager = .default) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AetherPersistenceTests-\(UUID())")
        images = root.appendingPathComponent("Images"); payloads = root.appendingPathComponent("Payloads")
        archive = root.appendingPathComponent("history.json")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: payloads, withIntermediateDirectories: true)
        writer = ClipboardPersistenceCoordinator(archiveURL: archive, imagesDirectory: images, payloadsDirectory: payloads, fileManager: fileManager)
    }
    func create(_ name: String, in directory: URL) throws { try Data([7,8,9]).write(to: directory.appendingPathComponent(name)) }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private final class CheckingFileManager: FileManager, @unchecked Sendable {
    var archive: URL?
    var enumerated: [String] = []
    var archiveWasSavedBeforeEveryEnumeration = true
    override func contentsOfDirectory(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?, options mask: FileManager.DirectoryEnumerationOptions = []) throws -> [URL] {
        enumerated.append(url.lastPathComponent)
        if let archive {
            let saved = (try? Data(contentsOf: archive)).flatMap { try? JSONDecoder().decode(ClipboardArchive.self, from: $0) }
            archiveWasSavedBeforeEveryEnumeration = archiveWasSavedBeforeEveryEnumeration && saved != nil
        }
        if url.lastPathComponent == "Images" { throw CocoaError(.fileReadNoPermission) }
        return try super.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
    }
    override func removeItem(at URL: URL) throws {
        if URL.lastPathComponent == "failed.rtf" { throw CocoaError(.fileWriteNoPermission) }
        try super.removeItem(at: URL)
    }
}
