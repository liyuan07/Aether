import XCTest
import Combine
@testable import ClipboardFeature

final class SearchTests: XCTestCase {
    @MainActor
    func testSearchWaitsForTypingToPause() async throws {
        let search = ClipboardSearchModel(delayNanoseconds: 30_000_000)
        let applied = expectation(description: "Debounced query published")
        let subscription = search.$query.filter { $0 == "17" }.first().sink { _ in applied.fulfill() }
        defer { subscription.cancel() }

        search.text = "1"
        try await Task.sleep(nanoseconds: 5_000_000)
        search.text = "17"

        XCTAssertEqual(search.query, "")
        await fulfillment(of: [applied], timeout: 2)
        XCTAssertEqual(search.query, "17")
    }

    @MainActor
    func testClearingSearchAppliesImmediately() async throws {
        let search = ClipboardSearchModel(delayNanoseconds: 5_000_000)
        let applied = expectation(description: "Query published before clearing")
        let subscription = search.$query.filter { $0 == "17" }.first().sink { _ in applied.fulfill() }
        defer { subscription.cancel() }
        search.text = "17"
        await fulfillment(of: [applied], timeout: 2)
        XCTAssertEqual(search.query, "17")

        search.text = ""

        XCTAssertEqual(search.query, "")
    }

    @MainActor
    func testDisabledDebounceAppliesSearchImmediately() {
        let search = ClipboardSearchModel(
            delayNanoseconds: 1_000_000_000,
            debounceEnabled: false
        )

        search.text = "立即搜索"

        XCTAssertEqual(search.query, "立即搜索")
    }

    @MainActor
    func testSearchReadsDebouncePreferences() {
        let suiteName = "ClipboardTests.Search.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        PreferenceKeys.registerDefaults(in: defaults)

        XCTAssertTrue(ClipboardSearchDebounce.isEnabled(in: defaults))
        XCTAssertEqual(
            ClipboardSearchDebounce.milliseconds(in: defaults),
            150
        )

        defaults.set(false, forKey: PreferenceKeys.searchDebounceEnabled)
        defaults.set(350, forKey: PreferenceKeys.searchDebounceMilliseconds)
        let search = ClipboardSearchModel(defaults: defaults)
        search.text = "偏好设置"

        XCTAssertEqual(search.query, "偏好设置")
        XCTAssertFalse(ClipboardSearchDebounce.isEnabled(in: defaults))
        XCTAssertEqual(
            ClipboardSearchDebounce.milliseconds(in: defaults),
            350
        )
    }

    func testSearchDebouncePreferenceClampsUnsupportedValues() {
        XCTAssertEqual(ClipboardSearchDebounce.clamped(-1), 50)
        XCTAssertEqual(ClipboardSearchDebounce.clamped(2_000), 1_000)
    }

    func testPanelTabLockDefaultsToUnlockedAndPersistsEveryTab() {
        let suiteName = "ClipboardTests.PanelTabLock.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        PreferenceKeys.registerDefaults(in: defaults)

        XCTAssertNil(ClipboardPanelTabLock.tab(in: defaults))

        for tab in ClipboardTab.allCases {
            ClipboardPanelTabLock.set(tab, in: defaults)
            XCTAssertEqual(ClipboardPanelTabLock.tab(in: defaults), tab)
        }

        ClipboardPanelTabLock.set(nil, in: defaults)
        XCTAssertNil(ClipboardPanelTabLock.tab(in: defaults))
    }

    func testPanelTabLockIgnoresUnknownPersistedTab() {
        let suiteName = "ClipboardTests.PanelTabLock.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set("unknown", forKey: PreferenceKeys.lockedPanelTab)

        XCTAssertNil(ClipboardPanelTabLock.tab(in: defaults))
    }

    func testTextAndFileUseClearlyDifferentIcons() {
        XCTAssertEqual(ClipboardItemType.text.icon, "text.alignleft")
        XCTAssertEqual(ClipboardItemType.file.icon, "doc.fill")
        XCTAssertNotEqual(
            ClipboardItemType.text.icon,
            ClipboardItemType.file.icon
        )
    }

    func testLongNumericQueryRequiresContiguousMatch() {
        let cookie = ClipboardItem(
            stringData: "enter_pc_once=1; token=132xx312xx373xx635xx624",
            type: .text
        )
        let query = "1323123736356245278473736245256477687959595625431"

        XCTAssertTrue(
            matchedClipboardItems(query: query, items: [cookie]).isEmpty
        )
    }

    func testNumericSubstringStillMatches() {
        let item = ClipboardItem(
            stringData: "订单号：AB-1323123736-CN",
            type: .text
        )

        XCTAssertEqual(
            matchedClipboardItems(query: "1323123736", items: [item]).count,
            1
        )
    }

    func testFileQueryCannotSpanDifferentFileNames() {
        let item = ClipboardItem(fileURLs: [
            "file:///tmp/123.txt",
            "file:///tmp/456.txt"
        ])

        XCTAssertTrue(
            matchedClipboardItems(query: "2345", items: [item]).isEmpty
        )
    }

    func testFileShowsItsParentDirectoryBelowTheFileName() {
        let item = ClipboardItem(fileURLs: [
            "file:///tmp/My%20Folder/report.pdf"
        ])

        XCTAssertEqual(item.displayPreview, "report.pdf")
        XCTAssertEqual(item.filePathPreview, "/tmp/My Folder")
    }

    func testFilesFromDifferentDirectoriesSummarizeExtraLocations() {
        let item = ClipboardItem(fileURLs: [
            "file:///tmp/First/report.pdf",
            "file:///tmp/Second/notes.txt",
            "file:///tmp/Second/image.png"
        ])

        XCTAssertEqual(
            item.filePathPreview,
            "/tmp/First · 另有 1 个位置"
        )
    }

    func testFileDirectoryCanBeSearched() {
        let item = ClipboardItem(fileURLs: [
            "file:///tmp/Project%20Documents/report.pdf"
        ])

        let matches = matchedClipboardItems(
            query: "Project Documents",
            items: [item]
        )
        XCTAssertEqual(matches.map(\.id), [item.id])
    }

    func testImagePresentationSizeIsNotSearchable() throws {
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "type": "image",
          "timestamp": 0,
          "preview": "Image (17.9 MB)",
          "isPinned": false,
          "imageFileName": "clipboard_image_example.png"
        }
        """
        let item = try JSONDecoder().decode(
            ClipboardItem.self,
            from: Data(json.utf8)
        )

        XCTAssertTrue(
            matchedClipboardItems(query: "17", items: [item]).isEmpty
        )
    }

    func testShortTextStillSupportsBoundedFuzzySearch() {
        let item = ClipboardItem(
            stringData: "clipboard manager",
            type: .text
        )

        XCTAssertEqual(
            matchedClipboardItems(query: "clipman", items: [item]).count,
            1
        )
    }

    func testSearchNormalizationKeepsCaseDiacriticAndWidthMatching() {
        let items = [
            ClipboardItem(stringData: "Café", type: .text),
            ClipboardItem(stringData: "ＡＢＣ", type: .text)
        ]

        XCTAssertEqual(
            matchedClipboardItems(query: "CAFE", items: items).map(\.id),
            [items[0].id]
        )
        XCTAssertEqual(
            matchedClipboardItems(query: "abc", items: items).map(\.id),
            [items[1].id]
        )
    }

    func testFuzzySearchKeepsExistingBoundedSpanBehavior() {
        let nearby = ClipboardItem(
            stringData: "clip board manager",
            type: .text
        )
        let scattered = ClipboardItem(
            stringData: "c" + String(repeating: "x", count: 30) + "lipman",
            type: .text
        )

        XCTAssertEqual(
            matchedClipboardItems(
                query: "clipman",
                items: [nearby, scattered]
            ).map(\.id),
            [nearby.id]
        )
    }

    func testIndexedSearchBuildsEveryTabFromOneRankedResult() async throws {
        let text = ClipboardItem(stringData: "shared text", type: .text)
        let url = ClipboardItem(
            stringData: "https://example.com/shared",
            type: .url
        )
        let file = ClipboardItem(fileURLs: ["file:///tmp/shared-report.pdf"])
        let favorite = ClipboardItem(
            stringData: "shared favorite",
            type: .text
        )
        let group = ClipboardGroup(items: [text, file])

        let snapshot = try await ClipboardSearchIndex().search(
            query: "shared",
            history: [text, url, file],
            pinnedItems: [favorite],
            groups: [group]
        )

        XCTAssertEqual(snapshot.items(for: .all).count, 3)
        XCTAssertEqual(snapshot.items(for: .text).count, 2)
        XCTAssertEqual(snapshot.items(for: .files).map(\.id), [file.id])
        XCTAssertEqual(snapshot.items(for: .favorites).map(\.id), [favorite.id])
        XCTAssertEqual(snapshot.groups.map(\.id), [group.id])
    }

    func testIndexedSearchMatchesSynchronousReferenceOrder() async throws {
        let base = Date(timeIntervalSince1970: 1_000)
        let items = (0..<200).map { index in
            ClipboardItem(
                stringData: index.isMultiple(of: 3)
                    ? "clipboard manager \(index)"
                    : "unrelated value \(index)",
                type: .text,
                timestamp: base.addingTimeInterval(Double(index))
            )
        }
        let expected = matchedClipboardItems(query: "clipman", items: items)

        let snapshot = try await ClipboardSearchIndex().search(
            query: "clipman",
            history: items,
            pinnedItems: [],
            groups: []
        )

        XCTAssertEqual(snapshot.items(for: .all).map(\.id), expected.map(\.id))
    }

    func testIndexedSearchMatchesReferenceAcrossGeneratedData() async throws {
        let base = Date(timeIntervalSince1970: 1_000)
        let phrases = [
            "Clipboard Café project",
            "订单 1234567890",
            "普通中文内容",
            "ＡＢＣ full width",
            "unrelated notes"
        ]
        let history = (0..<500).map { index in
            let phrase = phrases[(index * 17 + 3) % phrases.count]
            if index.isMultiple(of: 7) {
                return ClipboardItem(
                    fileURLs: ["file:///tmp/folder-\(index)/\(phrase).txt"],
                    timestamp: base.addingTimeInterval(Double(index))
                )
            }
            let type: ClipboardItemType = index.isMultiple(of: 5) ? .url : .text
            return ClipboardItem(
                stringData: "\(phrase) item-\(index)",
                type: type,
                timestamp: base.addingTimeInterval(Double(index))
            )
        }
        let pinnedItems = Array(history.prefix(12))
        let searchableHistory = Array(history.dropFirst(12))
        let groups = stride(from: 20, to: 80, by: 10).map { index in
            ClipboardGroup(items: Array(history[index..<(index + 3)]))
        }
        let index = ClipboardSearchIndex()

        for query in ["clip", "CAFE", "123456", "abc", "普通", "folder-49"] {
            let snapshot = try await index.search(
                query: query,
                history: searchableHistory,
                pinnedItems: pinnedItems,
                groups: groups
            )
            XCTAssertEqual(
                snapshot.items(for: .all).map(\.id),
                matchedClipboardItems(
                    query: query,
                    items: searchableHistory
                ).map(\.id)
            )
            XCTAssertEqual(
                snapshot.items(for: .favorites).map(\.id),
                matchedClipboardItems(
                    query: query,
                    items: pinnedItems
                ).map(\.id)
            )
            XCTAssertEqual(
                snapshot.groups.map(\.id),
                matchedClipboardGroups(query: query, groups: groups).map(\.id)
            )
        }
    }

    func testCancelledIndexedSearchCannotPublishAResult() async throws {
        let items = (0..<20_000).map { index in
            ClipboardItem(
                stringData: String(repeating: "searchable value \(index) ", count: 8),
                type: .text
            )
        }
        let task = Task {
            try await ClipboardSearchIndex().search(
                query: "srchvl",
                history: items,
                pinnedItems: [],
                groups: []
            )
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Cancelled search unexpectedly returned a snapshot")
        } catch is CancellationError {
            // Expected: stale panel generations cannot receive a snapshot.
        }
    }

    func testSearchScaleBenchmark() async throws {
        guard ProcessInfo.processInfo.environment[
            "CLIPBOARD_RUN_SEARCH_BENCHMARKS"
        ] == "1" else {
            throw XCTSkip("Run explicitly for Release search benchmarks")
        }

        for count in [5_000, 10_500, 20_000] {
            let items = (0..<count).map { index in
                let marker = index.isMultiple(of: 17) ? "performance needle" : "notes"
                return ClipboardItem(
                    stringData: String(
                        repeating: "\(marker) item \(index) clipboard content ",
                        count: 6
                    ),
                    type: .text,
                    timestamp: Date(timeIntervalSince1970: Double(index))
                )
            }
            let index = ClipboardSearchIndex()
            let start = DispatchTime.now().uptimeNanoseconds
            let snapshot = try await index.search(
                query: "performance needle",
                history: items,
                pinnedItems: [],
                groups: []
            )
            let milliseconds = Double(
                DispatchTime.now().uptimeNanoseconds - start
            ) / 1_000_000
            XCTAssertFalse(snapshot.items(for: .all).isEmpty)
            print(
                "CLIPBOARD_SEARCH_BENCHMARK count=\(count) "
                    + "milliseconds=\(String(format: "%.2f", milliseconds))"
            )
        }
    }

    func testArchiveWithoutGroupsRemainsDecodable() throws {
        let archive = ClipboardArchive(
            history: [
                ClipboardItem(stringData: "hello", type: .text)
            ],
            pinnedItems: [],
            groups: nil
        )
        let encoded = try JSONEncoder().encode(archive)
        let decoded = try JSONDecoder().decode(
            ClipboardArchive.self,
            from: encoded
        )

        XCTAssertEqual(decoded.history.first?.stringData, "hello")
        XCTAssertNil(decoded.groups)
    }
}
