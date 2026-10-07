// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import ClipboardFeature

final class RustClipboardGroupTests: XCTestCase {
    private func same(_ left: [ClipboardItem], _ right: [ClipboardItem]) -> Bool {
        left.count == right.count && zip(left,right).allSatisfy { a,b in
            a.type == b.type && a.stringData == b.stringData && a.imageFileName == b.imageFileName
                && a.fileURLs == b.fileURLs && a.rtfFileName == b.rtfFileName
        }
    }
    private func unique(_ items: [ClipboardItem]) -> [ClipboardItem] {
        var seen = Set<UUID>()
        return items.filter { seen.insert($0.id).inserted }
    }
    private func encoded(_ groups: [ClipboardGroup]) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return try encoder.encode(groups)
    }

    func testSequenceMatchesIndependentOriginalGroupLifecycle() throws {
        let bodies = ["cafe\u{301}","café","中文", "a\u{0000}b", "👨‍👩‍👦", "Synthetic"]
        let items = (0..<36).map { ClipboardItem(stringData:bodies[$0 % 6],type:ClipboardItemType.allCases[$0 % 6], timestamp:Date(timeIntervalSinceReferenceDate:Double($0))) }
        var actual: [ClipboardGroup] = [], expected: [ClipboardGroup] = []
        var seed: UInt64 = 78654321
        for step in 0..<1_000 {
            seed = seed &* 6364136223846793005 &+ 1
            let action = [ClipboardGroupAction.create,.promote,.remove,.clear][Int(seed >> 32) % 4]
            var chosen = [items[step % items.count],items[(step + 7) % items.count]]
            if step.isMultiple(of: 5) { chosen = [chosen[0],chosen[0]] }
            if step.isMultiple(of: 11) { chosen = [] }
            let id = step.isMultiple(of: 2) ? (expected.last?.id ?? UUID()) : UUID()
            let transition = rustClipboardGroupTransition(actual,action:action,candidateID:id,items:chosen)
            var selected: ClipboardGroup?, accepted = true, changed = true
            switch action {
            case .create:
                let values = unique(chosen)
                if values.count < 2 { accepted = false; changed = false }
                else if let index = expected.firstIndex(where: { same($0.items,values) }) {
                    selected = expected.remove(at:index); expected.insert(selected!,at:0)
                } else {
                    let fresh = try XCTUnwrap(transition.selected)
                    XCTAssertFalse(expected.contains { $0.id == fresh.id })
                    XCTAssertEqual(fresh.items.map(\.id),values.map(\.id))
                    selected = fresh; expected.insert(fresh,at:0)
                }
            case .promote:
                if let index = expected.firstIndex(where: { $0.id == id }) {
                    selected = expected.remove(at:index); expected.insert(selected!,at:0)
                } else { changed = false }
            case .remove: expected.removeAll { $0.id == id }
            case .clear: expected.removeAll()
            }
            XCTAssertEqual(transition.accepted,accepted)
            XCTAssertEqual(transition.changed,changed)
            XCTAssertEqual(transition.selected?.id,selected?.id)
            XCTAssertEqual(transition.selected?.timestamp,selected?.timestamp)
            XCTAssertEqual(try encoded(transition.groups),try encoded(expected))
            actual = transition.groups
        }
    }

    func testAlreadyFirstAndNoOpPlansShareNativeArrayStorage() {
        let items = [ClipboardItem(stringData:"Synthetic A",type:.text),ClipboardItem(stringData:"Synthetic B",type:.url)]
        let group = ClipboardGroup(items:items)
        let source = [group]
        let transitions = [
            rustClipboardGroupTransition(source,action:.create,items:items),
            rustClipboardGroupTransition(source,action:.promote,candidateID:group.id),
            rustClipboardGroupTransition(source,action:.promote,candidateID:UUID()),
            rustClipboardGroupTransition(source,action:.remove,candidateID:UUID()),
            rustClipboardGroupTransition(source,action:.create,items:[items[0]])
        ]
        for transition in transitions {
            source.withUnsafeBufferPointer { original in
                transition.groups.withUnsafeBufferPointer { XCTAssertEqual(original.baseAddress,$0.baseAddress) }
            }
        }
    }

    func testFirstContentMatchKeepsIdentityAndRemovalDeletesAllMatchingIDs() throws {
        let a = ClipboardItem(stringData:"cafe\u{301}",type:.text), b = ClipboardItem(stringData:"中文",type:.url)
        let first = ClipboardGroup(timestamp:Date(timeIntervalSinceReferenceDate:1),items:[a,b])
        let second = ClipboardGroup(timestamp:Date(timeIntervalSinceReferenceDate:2),items:[a,b])
        let other = ClipboardGroup(items:[b,a])
        let equivalent = ClipboardItem(stringData:"café",type:.text)
        let original = [other,first,second]
        let originalBytes = try encoded(original)
        let reused = rustClipboardGroupTransition(original,action:.create,items:[equivalent,b,equivalent])
        XCTAssertEqual(reused.groups.map(\.id),[first.id,other.id,second.id])
        XCTAssertEqual(reused.selected?.timestamp,first.timestamp)
        XCTAssertEqual(reused.selected?.items.map(\.id),first.items.map(\.id))
        let repeated = ClipboardGroup(id:first.id,items:[b,a])
        let removed = rustClipboardGroupTransition([first,other,repeated],action:.remove,candidateID:first.id)
        XCTAssertEqual(removed.groups.map(\.id),[other.id])
        XCTAssertEqual(try encoded(original),originalBytes)
    }
}
