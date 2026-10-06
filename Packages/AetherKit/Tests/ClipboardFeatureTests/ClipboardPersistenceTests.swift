// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import ClipboardFeature

final class ClipboardPersistenceTests: XCTestCase {
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
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AetherPersistenceTests-\(UUID())")
        images = root.appendingPathComponent("Images"); payloads = root.appendingPathComponent("Payloads")
        archive = root.appendingPathComponent("history.json")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: payloads, withIntermediateDirectories: true)
        writer = ClipboardPersistenceCoordinator(archiveURL: archive, imagesDirectory: images, payloadsDirectory: payloads)
    }
    func create(_ name: String, in directory: URL) throws { try Data([7,8,9]).write(to: directory.appendingPathComponent(name)) }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}
