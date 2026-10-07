// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import ClipboardFeature

final class RustSearchSnapshotTests: XCTestCase {
    func testClassificationMatchesOriginalAcrossTypesAndPinMembership() {
        for count in 0..<100 {
            let items = (0..<count).map { index -> ClipboardItem in
                var item = ClipboardItem(stringData: "Synthetic bucket \(index)", type: ClipboardItemType.allCases[index % 6])
                item.isPinned = index.isMultiple(of: 3)
                return item
            }
            let pinnedIDs = Set(items.enumerated().filter { $0.offset.isMultiple(of: 7) }.map { $0.element.id })
            let snapshot = ClipboardSearchSnapshot(rankedItems: items, pinnedIDs: pinnedIDs, rankedGroups: [])
            var original: [ClipboardTab: [UUID]] = [:]
            for item in items {
                if pinnedIDs.contains(item.id) { original[.favorites,default:[]].append(item.id); continue }
                original[.all,default:[]].append(item.id)
                switch item.type {
                case .text,.url,.rtf,.unknown: original[.text,default:[]].append(item.id)
                case .image: original[.images,default:[]].append(item.id)
                case .file: original[.files,default:[]].append(item.id)
                }
            }
            for tab in ClipboardTab.allCases { XCTAssertEqual(snapshot.items(for:tab).map(\.id),original[tab] ?? []) }
        }
    }

    func testFullBucketsShareNativeArrayAndSnapshotSurvivesSourceMutation() async {
        var source = (0..<10_000).map { ClipboardItem(stringData: "Synthetic shared array \($0)",type:.text) }
        let originalID = source[0].id
        var optional: ClipboardSearchSnapshot? = ClipboardSearchSnapshot(history: source,pinnedItems:[],groups:[])
        let snapshot = optional!
        optional = nil
        let all = snapshot.items(for:.all), text = snapshot.items(for:.text)
        source.withUnsafeBufferPointer { original in
            all.withUnsafeBufferPointer { XCTAssertEqual(original.baseAddress,$0.baseAddress) }
            text.withUnsafeBufferPointer { XCTAssertEqual(original.baseAddress,$0.baseAddress) }
        }
        source[0] = ClipboardItem(stringData:"Synthetic replacement",type:.file)
        XCTAssertEqual(snapshot.items(for:.all).first?.id,originalID)
        await withTaskGroup(of: UUID?.self) { group in
            for _ in 0..<128 { group.addTask { snapshot.items(for:.text).first?.id } }
            for await id in group { XCTAssertEqual(id,originalID) }
        }
    }

    func testSelectionUsesCurrentPositionsAndCopiedStateKeepsOriginalValues() {
        let a = ClipboardItem(stringData:"Synthetic A",type:.text), b = ClipboardItem(stringData:"Synthetic B",type:.text)
        let group = ClipboardGroup(items:[a,b])
        func state(_ items: [ClipboardItem]) -> ClipboardPanelViewModel.State {
            .init(selectedTab:.all,query:"",items:items,groups:[group],
                itemIndexByID:Dictionary(uniqueKeysWithValues:items.enumerated().map {($0.element.id,$0.offset)}),
                groupIndexByID:[group.id:0],pinnedIDs:[],itemIDs:items.map(\.id),groupIDs:[group.id],isSearching:false,resultRevision:1)
        }
        let before = state([a,b]), reordered = state([b,a]), removed = state([b])
        XCTAssertEqual(before.item(withID:a.id)?.id,a.id)
        XCTAssertEqual(reordered.item(withID:a.id)?.id,a.id)
        XCTAssertNil(removed.item(withID:a.id))
        XCTAssertEqual(before.item(withID:a.id)?.stringData,"Synthetic A")
        XCTAssertEqual(before.group(withID:group.id)?.items.map(\.id),[a.id,b.id])
        XCTAssertNil(before.group(withID:UUID()))
    }
}
