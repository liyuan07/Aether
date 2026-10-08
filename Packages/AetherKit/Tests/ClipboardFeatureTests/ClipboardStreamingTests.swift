// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin
import XCTest
import CAetherCore
@testable import ClipboardFeature

private func streamFixture(_ count: Int) throws -> ClipboardArchive {
    let kinds = ["text","url","file","image","rtf","unknown"]
    let texts = ["", "合成\0cafe\u{301}👨‍👩‍👧‍👦", "\\\"\n\r", String(repeating:"长",count:128)]
    let items: [[String: Any]] = (0..<count).map { n in
        var item: [String: Any] = ["id": UUID().uuidString, "type": kinds[n % 6], "timestamp": Double(n) * 0.125 - 500,
            "preview": texts[n % texts.count], "isPinned": n % 2 == 0]
        for (offset,key) in ["stringData","imageFileName","imageContentHash","rtfFileName"].enumerated() where (n + offset) % 3 != 0 {
            item[key] = texts[(n + offset) % texts.count]
        }
        if n % 3 != 0 { item["rtfData"] = Data([0,1,255,128,34,10]).base64EncodedString() }
        if n % 2 == 0 { item["fileURLs"] = n % 4 == 0 ? [] : ["file:///synthetic/合成", "cafe\u{301}\0", "file:///synthetic/合成"] }
        return item
    }
    let group: [String:Any] = ["id":UUID().uuidString,"timestamp":-0.125,"items":Array(items.prefix(8))]
    let raw: [String:Any] = ["history":items,"pinnedItems":Array(items.prefix(16)),"groups":[group,["id":UUID().uuidString,"timestamp":0,"items":[]]]]
    return try JSONDecoder().decode(ClipboardArchive.self,from:JSONSerialization.data(withJSONObject:raw))
}
private func streamWriteReference(_ archive: ClipboardArchive, owner: UnsafeMutableRawPointer?) -> UInt32 {
    ReferenceClipboardArchiveWire(archive).withViews { rows, urls, groups in
        aether_clipboard_archive_write_records(owner, rows.baseAddress, rows.count, archive.history.count,
            archive.pinnedItems.count, urls.baseAddress, urls.count, groups.baseAddress, groups.count, archive.groups == nil ? 0 : 1)
    }
}

final class ClipboardStreamingTests: XCTestCase {
    private func isolated(_ body: (URL, UnsafeMutableRawPointer?) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AetherClipboardStream-"+UUID().uuidString)
        let file = directory.appendingPathComponent("history.json")
        let owner = file.withUnsafeFileSystemRepresentation { aether_clipboard_archive_create($0) }
        defer { aether_clipboard_archive_destroy(owner); try? FileManager.default.removeItem(at:directory) }
        try body(file,owner)
    }
    func testStreamingMatchesFrozenWriterBytesAndIndependentNativeCodec() throws {
        try isolated { file, owner in
            let store = RustClipboardArchive(fileURL:file)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            for count in [0,1,128,1024] {
                var archive = try streamFixture(count)
                for groups: [ClipboardGroup]? in [nil,[],archive.groups] {
                    archive.groups = groups
                    XCTAssertEqual(streamWriteReference(archive,owner:owner),0)
                    let reference = try Data(contentsOf:file)
                    let inode = try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as! NSNumber
                    try store.save(archive)
                    XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber,inode)
                    XCTAssertEqual(try Data(contentsOf:file),reference)
                    let native = try JSONDecoder().decode(ClipboardArchive.self,from:reference)
                    XCTAssertEqual(try encoder.encode(native),try encoder.encode(archive))
                    let reopened = try XCTUnwrap(RustClipboardArchive(fileURL:file).load())
                    XCTAssertEqual(try encoder.encode(reopened),try encoder.encode(archive))
                }
            }
        }
    }
    func testInvalidCompactMetadataNeverReplacesOriginalFile() throws {
        try isolated { file, owner in
            let archive = try streamFixture(4)
            XCTAssertEqual(streamWriteReference(archive,owner:owner),0)
            let original = try Data(contentsOf:file)
            for mutation in 0..<14 {
                var wire = ClipboardArchiveWire(archive)
                switch mutation {
                case 0: wire.rows[0].id.start = Int.max
                case 1: wire.rows[0].id.length = Int.max
                case 2: wire.rows[0].preview.start = Int.max
                case 3: wire.rows[0].timestamp = .nan
                case 4: wire.rows[0].kind = 6
                case 5: wire.rows[0].present = 0
                case 6: wire.rows[2].url_start = Int.max
                case 7: wire.rows[2].file_count = Int.max
                case 8: wire.groups[0].start = 0
                case 9: wire.groups[0].count = Int.max
                case 10: wire.groups[0].timestamp = .infinity
                case 11: wire.arena[wire.rows[0].id.start] = 255
                case 12: wire.rows[1].rtf_data = wire.rows[1].id // Invalid Base64.
                default: wire.groups[0].id = wire.rows[0].preview
                }
                let status = wire.withViews { rows,urls,groups,bytes in
                    aether_clipboard_archive_write_spans(owner,rows.baseAddress,rows.count,archive.history.count,
                        archive.pinnedItems.count,urls.baseAddress,urls.count,groups.baseAddress,groups.count,1,bytes)
                }
                XCTAssertNotEqual(status,0,"Mutation \(mutation)")
                XCTAssertEqual(try Data(contentsOf:file),original)
            }
            XCTAssertNotEqual(aether_clipboard_archive_write_spans(owner,nil,1,0,0,nil,0,nil,0,0,.init()),0)
            XCTAssertNotEqual(aether_clipboard_archive_write_spans(owner,nil,0,0,0,nil,1,nil,0,0,.init()),0)
            XCTAssertNotEqual(aether_clipboard_archive_write_spans(owner,nil,0,0,0,nil,0,nil,1,1,.init()),0)
            XCTAssertNotEqual(aether_clipboard_archive_write_spans(owner,nil,0,Int.max,1,nil,0,nil,0,0,.init()),0)
            XCTAssertEqual(try Data(contentsOf:file),original)
        }
    }
    func testStreamingWriterRetainsExistingCorruptFileProtection() throws {
        try isolated { file, owner in
            let archive = try streamFixture(8)
            XCTAssertEqual(streamWriteReference(archive,owner:owner),0)
            let store = RustClipboardArchive(fileURL:file)
            _ = try store.load()
            let valid = try Data(contentsOf:file)
            let corrupt = Data("{synthetic invalid archive".utf8)
            try corrupt.write(to:file)
            XCTAssertThrowsError(try store.save(archive))
            XCTAssertEqual(try Data(contentsOf:file),corrupt)
            // An explicit successful reload, rather than a write, clears blocked state.
            try valid.write(to:file)
            XCTAssertThrowsError(try store.save(archive))
            _ = try store.load()
            try store.save(archive)
        }
    }
    func testMatchingLeafSymlinkKeepsLegacyReplacementSemantics() throws {
        try isolated { file, owner in
            let archive = try streamFixture(8)
            XCTAssertEqual(streamWriteReference(archive,owner:owner),0)
            let original = try Data(contentsOf:file)
            let target = file.deletingLastPathComponent().appendingPathComponent("target.json")
            try FileManager.default.moveItem(at:file,to:target)
            try FileManager.default.createSymbolicLink(at:file,withDestinationURL:target)
            try RustClipboardArchive(fileURL:file).save(archive)
            XCTAssertEqual(try file.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink,false)
            XCTAssertEqual(try Data(contentsOf:target),original)
            XCTAssertEqual(try Data(contentsOf:file),original)
        }
    }
    func testStreamingBridgeLiveAllocationBenchmark() throws {
        guard ProcessInfo.processInfo.environment["AETHER_CLIPBOARD_STREAM_BENCHMARK"] == "1" else { throw XCTSkip("Explicit synthetic allocation benchmark") }
        let archive = try streamFixture(10_000)
        func stats() -> malloc_statistics_t {
            var value = malloc_statistics_t(); malloc_zone_statistics(nil, &value); return value
        }
        var bytes = [[Int](),[Int]()]; var blocks = [[Int](),[Int]()]
        // Warm both bridge shapes before measuring incremental live allocations across all zones.
        for round in 0..<8 {
            for backend in round.isMultiple(of:2) ? [0,1] : [1,0] {
                let before = stats()
                let after: malloc_statistics_t
                if backend == 0 {
                    let wire = ReferenceClipboardArchiveWire(archive)
                    after = withExtendedLifetime(wire) { wire.withViews { rows,urls,groups in
                        XCTAssertEqual(rows.count,10024); XCTAssertEqual(groups.count,2)
                        return stats()
                    } }
                } else {
                    let wire = ClipboardArchiveWire(archive)
                    after = withExtendedLifetime(wire) { wire.withViews { rows,urls,groups,arena in
                        XCTAssertEqual(rows.count,10024); XCTAssertEqual(groups.count,2)
                        return stats()
                    } }
                }
                if round > 0 {
                    bytes[backend].append(Int(after.size_in_use)-Int(before.size_in_use))
                    blocks[backend].append(Int(after.blocks_in_use)-Int(before.blocks_in_use))
                }
            }
        }
        let result: [String:Any] = ["history_rows":10000,"total_rows":10024,"old_live_bytes":bytes[0],"stream_live_bytes":bytes[1],"old_median_live_bytes":bytes[0].sorted()[3],"stream_median_live_bytes":bytes[1].sorted()[3],"old_median_live_blocks":blocks[0].sorted()[3],"stream_median_live_blocks":blocks[1].sorted()[3]]
        print("CLIPBOARD_STREAM_ALLOCATION "+String(decoding:try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]),as:UTF8.self))
    }
    func testStreamingReleaseBenchmark() throws {
        guard ProcessInfo.processInfo.environment["AETHER_CLIPBOARD_STREAM_BENCHMARK"] == "1" else { throw XCTSkip("Explicit synthetic benchmark") }
        try isolated { file,owner in
            let archive = try streamFixture(10_000)
            let store = RustClipboardArchive(fileURL:file)
            XCTAssertEqual(streamWriteReference(archive,owner:owner),0)
            let reference = try Data(contentsOf:file)
            try store.save(archive)
            XCTAssertEqual(try Data(contentsOf:file),reference)
            for changing in [false,true] {
                var times = [[Double](),[Double]()]
                for round in 0..<7 {
                    for backend in round.isMultiple(of:2) ? [0,1] : [1,0] {
                        var active = archive
                        XCTAssertEqual(streamWriteReference(active,owner:owner),0)
                        var status: UInt32 = 0
                        let start = DispatchTime.now().uptimeNanoseconds
                        for iteration in 0..<5 {
                            if changing { active.history[0].preview = "合成修改 \(round)-\(backend)-\(iteration)" }
                            if backend == 0 { status |= streamWriteReference(active,owner:owner) }
                            else { try store.save(active) }
                        }
                        times[backend].append(Double(DispatchTime.now().uptimeNanoseconds-start)/1_000_000)
                        XCTAssertEqual(status,0)
                        let actual = try Data(contentsOf:file)
                        XCTAssertEqual(streamWriteReference(active,owner:owner),0)
                        XCTAssertEqual(try Data(contentsOf:file),actual)
                    }
                }
                let result: [String:Any] = ["scenario":changing ? "changing" : "unchanged", "history_rows":10000,"pinned_rows":archive.pinnedItems.count,"group_rows":archive.groups!.reduce(0){$0+$1.items.count},"input_bytes":reference.count,"operations_per_round":5,"old_ms":times[0],"stream_ms":times[1],"old_median_ms":times[0].sorted()[3],"stream_median_ms":times[1].sorted()[3]]
                print("CLIPBOARD_STREAM_BENCHMARK "+String(decoding:try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]),as:UTF8.self))
            }
        }
    }
}
