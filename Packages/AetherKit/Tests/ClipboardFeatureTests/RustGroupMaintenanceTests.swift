// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import ClipboardFeature

final class RustGroupMaintenanceTests: XCTestCase {
    private func same(_ lhs: [ClipboardItem], _ rhs: [ClipboardItem]) -> Bool {
        lhs.count == rhs.count && zip(lhs,rhs).allSatisfy { a,b in
            a.type == b.type && a.stringData == b.stringData && a.imageFileName == b.imageFileName
                && a.fileURLs == b.fileURLs && a.rtfFileName == b.rtfFileName
        }
    }
    private func original(_ groups: [ClipboardGroup]) -> [ClipboardGroup] {
        var result: [ClipboardGroup] = []
        for group in groups where !group.items.isEmpty {
            if !result.contains(where: { same($0.items,group.items) }) { result.append(group) }
        }
        return result
    }
    private func migrated(_ groups: [ClipboardGroup]) -> [ClipboardGroup] {
        let accumulator = ClipboardGroupAccumulator()
        for group in groups { accumulator.append(group) }
        return accumulator.groups
    }

    func testNativeHashEqualityAndIgnoredMetadataPreserveFirstGroup() {
        for type in ClipboardItemType.allCases {
            var first = ClipboardItem(stringData:"café",type:type,timestamp:Date(timeIntervalSinceReferenceDate:1))
            first.imageFileName = "café.png"; first.rtfFileName = "café.rtf"
            var canonical = ClipboardItem(stringData:"cafe\u{301}",type:type,timestamp:Date(timeIntervalSinceReferenceDate:9))
            canonical.imageFileName = "cafe\u{301}.png"; canonical.rtfFileName = "cafe\u{301}.rtf"
            canonical.preview = "Different presentation"; canonical.isPinned = true
            canonical.imageContentHash = "different-capture-identity"; canonical.rtfData = Data([1,2,3])
            XCTAssertTrue(same([first],[canonical]))
            XCTAssertEqual(clipboardGroupFingerprint([first]),clipboardGroupFingerprint([canonical]))
            let firstGroup = ClipboardGroup(items:[first]), duplicate = ClipboardGroup(items:[canonical])
            var changed = canonical; changed.rtfFileName = nil
            let distinct = ClipboardGroup(items:[changed])
            let input = [ClipboardGroup(items:[]),firstGroup,duplicate,distinct]
            XCTAssertEqual(migrated(input).map(\.id),[firstGroup.id,distinct.id])
        }
        let left = ClipboardItem(fileURLs:["file:///tmp/café","file:///tmp/中文"])
        let right = ClipboardItem(fileURLs:["file:///tmp/cafe\u{301}","file:///tmp/中文"])
        XCTAssertEqual(clipboardGroupFingerprint([left]),clipboardGroupFingerprint([right]))
        XCTAssertEqual(migrated([.init(items:[left]),.init(items:[right])]).count,1)
        let absent = ClipboardItem(stringData:"",type:.file), empty = ClipboardItem(fileURLs:[])
        XCTAssertFalse(same([absent],[empty]))
        XCTAssertEqual(migrated([.init(items:[absent]),.init(items:[empty])]).count,2)
    }

    func testGeneratedGroupsMatchIndependentOriginalSelection() {
        let phrases = ["", "中文", "café", "cafe\u{301}", "a\u{0000}b", "👨‍👩‍👦"]
        var source: [ClipboardGroup] = []
        for i in 0..<1_500 {
            var values: [ClipboardItem] = []
            for j in 0..<(i % 5) {
                var item = ClipboardItem(stringData:phrases[(i+j)%phrases.count],type:ClipboardItemType.allCases[(i+j)%6])
                if i.isMultiple(of:3) { item.imageFileName = "Synthetic \(j % 2).png" }
                if i.isMultiple(of:7) { item.rtfFileName = "Synthetic \(j % 2).rtf" }
                values.append(item)
            }
            source.append(.init(timestamp:Date(timeIntervalSinceReferenceDate:Double(i)),items:values))
        }
        let expected = original(source), actual = migrated(source)
        XCTAssertEqual(actual.map(\.id),expected.map(\.id))
        XCTAssertEqual(actual.map(\.timestamp),expected.map(\.timestamp))
        XCTAssertEqual(actual.map { $0.items.map(\.id) },expected.map { $0.items.map(\.id) })
    }

    func testActualMaintenanceFiltersBeforeGroupDeduplication() async throws {
        let a = ClipboardItem(stringData:"café",type:.text), b = ClipboardItem(stringData:"中文",type:.url)
        let equivalent = ClipboardItem(stringData:"cafe\u{301}",type:.text)
        let missing = ClipboardItem(stringData:"Synthetic missing image",type:.image)
        let first = ClipboardGroup(items:[a,b,missing]), duplicate = ClipboardGroup(items:[equivalent,b]), reversed = ClipboardGroup(items:[b,a])
        let source = ClipboardArchive(history:[a,b],pinnedItems:[a,missing],groups:[.init(items:[]),first,duplicate,reversed,.init(items:[missing])])
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let before = try encoder.encode(source)
        let processor = ClipboardMaintenanceProcessor()
        let result = try await processor.archive(from:source,expirationDays:0,historyLimit:1,now:Date())
        XCTAssertEqual(result.history.map(\.id),[a.id])
        XCTAssertEqual(result.pinnedItems.map(\.id),[a.id])
        XCTAssertEqual(result.groups?.map(\.id),[first.id,reversed.id])
        XCTAssertEqual(result.groups?.first?.items.map(\.id),[a.id,b.id])
        XCTAssertEqual(result.groups?.first?.timestamp,first.timestamp)
        XCTAssertEqual(try encoder.encode(source),before)
        let empty = try await processor.archive(from:.init(history:[],pinnedItems:[],groups:nil),expirationDays:0,historyLimit:1,now:Date())
        XCTAssertEqual(empty.groups?.count,0)
    }

    func testCancelledMaintenanceDoesNotReturnPartialArchive() async {
        let processor = ClipboardMaintenanceProcessor()
        let item = ClipboardItem(stringData:"Synthetic cancellation",type:.text)
        let source = ClipboardArchive(history:[item],pinnedItems:[],groups:[.init(items:[item])])
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let task = Task {
            for await _ in stream { break }
            return try await processor.archive(from:source,expirationDays:0,historyLimit:10,now:Date())
        }
        task.cancel()
        continuation.finish()
        do { _ = try await task.value; XCTFail("Cancelled maintenance returned a partial archive") }
        catch is CancellationError { }
        catch { XCTFail("Unexpected cancellation error type") }
    }

    func testGroupMaintenanceBenchmark() throws {
        guard ProcessInfo.processInfo.environment["AETHER_RUN_CORE_BENCHMARKS"] == "1" else { throw XCTSkip("Run explicitly for group maintenance comparison") }
        let unique = (0..<2_000).map { i in ClipboardGroup(items:[ClipboardItem(stringData:"Synthetic unique group \(i)",type:.text),ClipboardItem(stringData:"Synthetic shared",type:.url)]) }
        let source = unique + Array(unique.suffix(500))
        func legacy() -> [ClipboardGroup] {
            var result: [ClipboardGroup] = []
            for group in source where !group.items.isEmpty {
                if !result.contains(where:{rustClipboardGroupItemsMatch($0.items,group.items)}) { result.append(group) }
            }
            return result
        }
        XCTAssertEqual(legacy().map(\.id),migrated(source).map(\.id))
        var oldNS: [UInt64] = [], newNS: [UInt64] = []
        for _ in 0..<7 {
            let start = DispatchTime.now().uptimeNanoseconds
            let old = legacy()
            oldNS.append(DispatchTime.now().uptimeNanoseconds-start)
            let next = DispatchTime.now().uptimeNanoseconds
            let new = migrated(source)
            newNS.append(DispatchTime.now().uptimeNanoseconds-next)
            XCTAssertEqual(old.map(\.id),new.map(\.id))
        }
        print("AETHER_GROUP_MAINTENANCE_BENCHMARK groups=2500 unique=2000 iterations=7 original_median_ns=\(oldNS.sorted()[3]) rust_median_ns=\(newNS.sorted()[3])")
    }
}
