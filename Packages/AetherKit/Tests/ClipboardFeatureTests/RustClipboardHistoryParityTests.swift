// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import ClipboardFeature

final class RustClipboardHistoryParityTests: XCTestCase {
    func testGeneratedCaptureHistoryMatchesIndependentPreviousSwift() throws {
        let ids = (0..<20).map { _ in UUID() }
        for seed in 0..<300 {
            let history = try (0..<(seed % 65)).map { index in
                try fixture(id: ids[index % ids.count], seed: seed + index * 3, time: Double((index * 13 + seed) % 31))
            }
            let candidate = try fixture(id: ids[seed % ids.count], seed: seed + seed % 7, time: Double(seed % 31))
            let protected = Set(ids.enumerated().filter { ($0.offset + seed) % 3 != 0 }.map(\.element))
            let override: Set<UUID>? = seed % 2 == 0 ? Set(ids.enumerated().filter { ($0.offset + seed) % 4 == 0 }.map(\.element)) : nil
            for limit in [0, 1, 4, 32, 80] {
                let actual = clipboardHistoryByInserting(candidate, into: history, matchingDuplicateIDs: override, limit: limit, protecting: protected)
                let expected = previousClipboardHistoryByInserting(candidate, into: history, matchingDuplicateIDs: override, limit: limit, protecting: protected)
                XCTAssertEqual(actual.items.map(\.id),expected.items.map(\.id))
                XCTAssertEqual(actual.items.map(\.timestamp),expected.items.map(\.timestamp))
                XCTAssertEqual(actual.items.map(\.type),expected.items.map(\.type))
                XCTAssertEqual(actual.didInsert,expected.didInsert)
                XCTAssertEqual(actual.needsPayloadCleanup,expected.needsPayloadCleanup)
                XCTAssertEqual(rustClipboardTrim(history,limit:limit,protecting:protected).map(\.id),previousTrim(history,limit:limit,protected:protected).map(\.id))
            }
        }
    }
    func testContentIdentityMatchesPreviousAllKindsAndOptionalFields() throws {
        let items = try (0..<60).map { try fixture(id:UUID(),seed:$0,time:Double($0)) }
        for lhs in items {
            for rhs in items {
                XCTAssertEqual(lhs.hasSameContent(as:rhs),previousClipboardContentMatches(lhs,rhs))
            }
        }
        // Swift canonical equality must remain independent of UTF-8 encoding.
        let a = ClipboardItem(stringData:"a\u{301}",type:.text)
        let b = ClipboardItem(stringData:"á",type:.text)
        XCTAssertTrue(a.hasSameContent(as:b))
    }
    func testGroupIdentityPreservesPersistedFieldsInsteadOfCaptureHash() throws {
        let items = try (0..<30).map { try fixture(id:UUID(),seed:$0,time:Double($0)) }
        for index in 0..<30 {
            let lhs = Array(items.prefix(index))
            let rhs = Array(items.suffix(index))
            XCTAssertEqual(rustClipboardGroupItemsMatch(lhs,rhs),previousGroupMatches(lhs,rhs))
            XCTAssertTrue(rustClipboardGroupItemsMatch(lhs,lhs))
            XCTAssertFalse(rustClipboardGroupItemsMatch(lhs,lhs + [items[0]]))
        }
    }
    func testGroupIdentityDoesNotAdoptImageHashOrInlineRTFIdentity() {
        var imageA=ClipboardItem(stringData:"合成",type:.image)
        imageA.imageFileName="synthetic.png"; imageA.imageContentHash="hash-a"
        var imageB=imageA; imageB.imageContentHash="hash-b"
        XCTAssertFalse(imageA.hasSameContent(as:imageB))
        XCTAssertTrue(rustClipboardGroupItemsMatch([imageA],[imageB]))
        var rtfA=ClipboardItem(stringData:"合成",type:.rtf)
        rtfA.rtfData=Data([1,2,3])
        var rtfB=rtfA; rtfB.rtfData=Data([4,5,6])
        XCTAssertFalse(rtfA.hasSameContent(as:rtfB))
        XCTAssertTrue(rustClipboardGroupItemsMatch([rtfA],[rtfB]))
    }

    func testPinPlansAndMaintenanceSelectionMatchPreviousNativeRules() throws {
        let items = try (0..<50).map { try fixture(id:UUID(),seed:$0,time:Double($0)) }
        for seed in 0..<100 {
            let history=Array(items.prefix(seed % 50)), pinned=Array(items.suffix(seed % 15))
            var item=items[seed % items.count]; item.isPinned=seed % 2 == 0
            for action:UInt8 in [0,1,2] {
                let actual=rustClipboardPin(item,history:history,pinned:pinned,action:action,limit:seed % 12)
                let expected=previousPin(item,history:history,pinned:pinned,action:action,limit:seed % 12)
                XCTAssertEqual(actual.history.map(\.id),expected.history.map(\.id))
                XCTAssertEqual(actual.pinned.map(\.id),expected.pinned.map(\.id))
                XCTAssertEqual(actual.history.map(\.isPinned),expected.history.map(\.isPinned))
                XCTAssertEqual(actual.pinned.map(\.isPinned),expected.pinned.map(\.isPinned))
                XCTAssertEqual(actual.isPinned,expected.isPinned)
            }
            let cutoff=seed % 2 == 0 ? Date(timeIntervalSinceReferenceDate:Double(seed % 40)) : nil
            let rows=items.enumerated().map { rustClipboardRow($0.element,valid:($0.offset + seed) % 4 != 0) }
            let actual=rustClipboardPlan(rows,action:2,limit:seed % 17,cutoff:cutoff).indices
            let expected=items.indices.filter { ($0 + seed) % 4 != 0 && (cutoff == nil || !(items[$0].timestamp < cutoff!)) }.prefix(seed % 17)
            XCTAssertEqual(actual,Array(expected))
            for tab in ClipboardTab.allCases {
                for item in items { XCTAssertEqual(tab.includes(item),previousTabIncludes(tab,item)) }
            }
        }
    }
    func testHistoryTrimBenchmark() throws {
        guard ProcessInfo.processInfo.environment["AETHER_RUN_CORE_BENCHMARKS"] == "1" else { throw XCTSkip("Opt-in synthetic benchmark") }
        let items = (0..<5000).map { ClipboardItem(stringData:"合成\($0)",type:.text,timestamp:Date(timeIntervalSince1970:Double($0))) }
        let protected = Set(items.suffix(2500).map(\.id))
        var rustTimes:[Double]=[],swiftTimes:[Double]=[]
        for _ in 0..<7 {
            let clock=ContinuousClock(), start=ContinuousClock().now
            let rust=rustClipboardTrim(items,limit:2500,protecting:protected)
            let middle=clock.now
            let swift=previousTrim(items,limit:2500,protected:protected)
            let end=clock.now
            XCTAssertEqual(rust.map(\.id),swift.map(\.id))
            rustTimes.append(milliseconds(start.duration(to:middle)))
            swiftTimes.append(milliseconds(middle.duration(to:end)))
        }
        print("HISTORY_TRIM_SYNTHETIC 5000 rows / 2500 protected median Rust=\(rustTimes.sorted()[3])ms Swift=\(swiftTimes.sorted()[3])ms")
    }
    private func milliseconds(_ duration:Duration)->Double {
        let parts=duration.components
        return Double(parts.seconds)*1000+Double(parts.attoseconds)/1e15
    }

    private func fixture(id:UUID,seed:Int,time:Double) throws -> ClipboardItem {
        let kinds:[ClipboardItemType]=[.text,.url,.file,.image,.rtf,.unknown]
        var json:[String:Any]=["id":id.uuidString,"type":kinds[seed % 6].rawValue,"timestamp":time,"preview":"合成预览","isPinned":seed % 7 == 0]
        if seed % 5 != 0 { json["stringData"]=["中文","合成\u{0000}","á","a\u{301}"][seed % 4] }
        if seed % 3 != 0 { json["imageFileName"]="synthetic-\(seed % 4).png" }
        if seed % 4 != 0 { json["imageContentHash"]="synthetic-hash-\(seed % 3)" }
        if seed % 5 != 0 { json["fileURLs"]=["file:///synthetic/\(seed % 7)"] }
        // Inline bytes avoid touching any real payload directory.
        if seed % 3 != 0 { json["rtfData"]=Data("合成富文本\(seed % 5)".utf8).base64EncodedString() }
        return try JSONDecoder().decode(ClipboardItem.self,from:JSONSerialization.data(withJSONObject:json))
    }
}

// Independent copy of the pre-migration insertion policy.
private func previousClipboardHistoryByInserting(
    _ item: ClipboardItem,
    into history: [ClipboardItem],
    matchingDuplicateIDs: Set<UUID>? = nil,
    limit: Int,
    protecting protectedIDs: Set<UUID> = []
) -> ClipboardHistoryUpdate {
    let duplicateItems: [ClipboardItem]
    if let matchingDuplicateIDs {
        duplicateItems = history.filter { matchingDuplicateIDs.contains($0.id) }
    } else {
        duplicateItems = history.filter { previousClipboardContentMatches($0,item) }
    }
    if duplicateItems.contains(where: { $0.timestamp >= item.timestamp }) {
        return ClipboardHistoryUpdate(
            items: history,
            didInsert: false,
            needsPayloadCleanup: item.type == .rtf
        )
    }

    let duplicateIDs = Set(duplicateItems.map(\.id))
    var updated = history.filter { existing in
        !duplicateIDs.contains(existing.id)
    }
    let insertionIndex = updated.firstIndex {
        $0.timestamp < item.timestamp
    } ?? updated.endIndex
    updated.insert(item, at: insertionIndex)

    var removedPayload = duplicateItems.contains {
        $0.type == .image || $0.type == .rtf
    }
    while updated.count > limit {
        guard let index = updated.lastIndex(where: {
            !protectedIDs.contains($0.id)
        }) else {
            removedPayload = removedPayload || updated.dropFirst(limit).contains {
                $0.type == .image || $0.type == .rtf
            }
            updated = Array(updated.prefix(limit))
            break
        }
        let removed = updated[index]
        removedPayload = removedPayload
            || removed.type == .image
            || removed.type == .rtf
        updated.remove(at: index)
    }

    return ClipboardHistoryUpdate(
        items: updated,
        didInsert: true,
        needsPayloadCleanup: removedPayload
    )
}

private func previousClipboardContentMatches(_ lhs:ClipboardItem,_ other:ClipboardItem)->Bool {
        guard lhs.type == other.type else { return false }
        switch lhs.type {
        case .image:
            if let imageContentHash = lhs.imageContentHash, let otherHash = other.imageContentHash {
                return imageContentHash == otherHash
            }
            return lhs.imageFileName == other.imageFileName
        case .file:
            return lhs.fileURLs == other.fileURLs
        case .rtf:
            return lhs.stringData == other.stringData && lhs.getRTFData() == other.getRTFData()
        default:
            return lhs.stringData == other.stringData
        }
    }

private func previousTrim(_ history:[ClipboardItem],limit:Int,protected:Set<UUID>)->[ClipboardItem] {
    var updated=history
    while updated.count>limit {
        guard let index=updated.lastIndex(where:{ !protected.contains($0.id) }) else { updated=Array(updated.prefix(limit)); break }
        updated.remove(at:index)
    }
    return updated
}
private func previousPin(_ item:ClipboardItem,history:[ClipboardItem],pinned:[ClipboardItem],action:UInt8,limit:Int)->(history:[ClipboardItem],pinned:[ClipboardItem],isPinned:Bool) {
    var h=history,p=pinned,item=item
    let unpin=action==1 || (action==2 && (item.isPinned || p.contains { $0.id==item.id }))
    if unpin {
        p.removeAll { $0.id==item.id }; item.isPinned=false; h.insert(item,at:0)
        h=previousTrim(h,limit:limit,protected:[])
    } else {
        item.isPinned=true; h.removeAll { $0.id==item.id }
        if !p.contains(where:{ $0.id==item.id }) { p.insert(item,at:0) }
    }
    return (h,p,!unpin)
}
private func previousGroupMatches(_ lhs:[ClipboardItem],_ rhs:[ClipboardItem])->Bool {
    guard lhs.count==rhs.count else { return false }
    return zip(lhs,rhs).allSatisfy { a,b in a.type==b.type && a.stringData==b.stringData && a.imageFileName==b.imageFileName && a.fileURLs==b.fileURLs && a.rtfFileName==b.rtfFileName }
}
private func previousTabIncludes(_ tab:ClipboardTab,_ item:ClipboardItem)->Bool {
    switch tab {
    case .all: !item.isPinned
    case .text: !item.isPinned && [.text,.url,.rtf,.unknown].contains(item.type)
    case .images: !item.isPinned && item.type == .image
    case .files: !item.isPinned && item.type == .file
    case .favorites: item.isPinned
    case .groups: false
    }
}
