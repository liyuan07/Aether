import SharedSupport
/*
 * Clipboard
 * Copyright (C) 2026 Li Yuan
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import RustCore
import Combine
import Foundation

let clipboardSearchDebounceNanoseconds = ClipboardSearchDebounce.nanoseconds(
    for: ClipboardSearchDebounce.defaultMilliseconds
)

@MainActor
final class ClipboardSearchModel: ObservableObject {
    @Published var text = "" {
        didSet {
            scheduleSearch()
        }
    }
    @Published private(set) var query = ""

    private let delayNanoseconds: UInt64
    private let debounceEnabled: Bool
    private var pendingSearch: Task<Void, Never>?

    convenience init(defaults: UserDefaults = AppEnvironment.clipboardDefaults) {
        self.init(
            delayNanoseconds: ClipboardSearchDebounce.nanoseconds(
                for: ClipboardSearchDebounce.milliseconds(in: defaults)
            ),
            debounceEnabled: ClipboardSearchDebounce.isEnabled(in: defaults)
        )
    }

    init(
        delayNanoseconds: UInt64,
        debounceEnabled: Bool = true
    ) {
        self.delayNanoseconds = delayNanoseconds
        self.debounceEnabled = debounceEnabled
    }

    deinit {
        pendingSearch?.cancel()
    }

    private func scheduleSearch() {
        pendingSearch?.cancel()
        let pendingText = text
        guard !pendingText.isEmpty else {
            query = ""
            return
        }
        guard debounceEnabled else {
            query = pendingText
            return
        }
        let delayNanoseconds = self.delayNanoseconds

        pendingSearch = Task { [weak self, delayNanoseconds] in
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  let self,
                  text == pendingText else {
                return
            }
            query = pendingText
        }
    }
}

struct ClipboardSearchSnapshot: Sendable {
    private let itemsByTab: [ClipboardTab: [ClipboardItem]]
    let groups: [ClipboardGroup]

    init(
        history: [ClipboardItem],
        pinnedItems: [ClipboardItem],
        groups: [ClipboardGroup]
    ) {
        itemsByTab = Self.makeItemBuckets(
            rankedItems: history + pinnedItems,
            pinnedIDs: Set(pinnedItems.map(\.id))
        )
        self.groups = groups
    }

    init(
        rankedItems: [ClipboardItem],
        pinnedIDs: Set<UUID>,
        rankedGroups: [ClipboardGroup]
    ) {
        itemsByTab = Self.makeItemBuckets(
            rankedItems: rankedItems,
            pinnedIDs: pinnedIDs
        )
        groups = rankedGroups
    }

    func items(for tab: ClipboardTab) -> [ClipboardItem] {
        itemsByTab[tab] ?? []
    }

    private static func makeItemBuckets(
        rankedItems: [ClipboardItem],
        pinnedIDs: Set<UUID>
    ) -> [ClipboardTab: [ClipboardItem]] {
        var buckets: [ClipboardTab: [ClipboardItem]] = Dictionary(
            uniqueKeysWithValues: ClipboardTab.allCases.map { ($0, []) }
        )
        for item in rankedItems {
            if pinnedIDs.contains(item.id) {
                buckets[.favorites, default: []].append(item)
                continue
            }
            buckets[.all, default: []].append(item)
            switch item.type {
            case .text, .url, .rtf, .unknown:
                buckets[.text, default: []].append(item)
            case .image:
                buckets[.images, default: []].append(item)
            case .file:
                buckets[.files, default: []].append(item)
            }
        }
        return buckets
    }
}

actor ClipboardSearchIndex {
    static let shared = ClipboardSearchIndex()

    private var itemDocuments: [UUID: ClipboardIndexedDocument] = [:]

    func search(
        query rawQuery: String,
        history: [ClipboardItem],
        pinnedItems: [ClipboardItem],
        groups: [ClipboardGroup]
    ) throws -> ClipboardSearchSnapshot {
        let query = ClipboardNormalizedQuery(rawQuery)
        guard !query.text.isEmpty else {
            return ClipboardSearchSnapshot(
                history: history,
                pinnedItems: pinnedItems,
                groups: groups
            )
        }

        let allItems = history + pinnedItems
        let groupItems = groups.flatMap(\.items)
        let activeIDs = Set((allItems + groupItems).map(\.id))
        itemDocuments = itemDocuments.filter { activeIDs.contains($0.key) }

        var rankedItems = ClipboardRankedSources(capacity: allItems.count)
        for (offset, item) in allItems.enumerated() {
            if offset.isMultiple(of: 32) {
                try Task.checkCancellation()
            }
            let document = indexedDocument(for: item)
            if let score = query.core.score(document: document.core) {
                rankedItems.append(offset, score: score, timestamp: item.timestamp)
            }
        }
        var rankedGroups = ClipboardRankedSources(capacity: groups.count)
        for (offset, group) in groups.enumerated() {
            if offset.isMultiple(of: 16) {
                try Task.checkCancellation()
            }
            let documents = [RustSearchDocument(segments: [ClipboardIndexedSegment(group.title).core])]
                + group.items.map { indexedDocument(for: $0).core }
            if let score = bestClipboardScore(
                query: query,
                documents: documents
            ) {
                rankedGroups.append(offset, score: score, timestamp: group.timestamp)
            }
        }
        try Task.checkCancellation()

        return ClipboardSearchSnapshot(
            rankedItems: rankedItems.orderedSources.map { allItems[$0] },
            pinnedIDs: Set(pinnedItems.map(\.id)),
            rankedGroups: rankedGroups.orderedSources.map { groups[$0] }
        )
    }

    private func indexedDocument(
        for item: ClipboardItem
    ) -> ClipboardIndexedDocument {
        if let cached = itemDocuments[item.id] {
            return cached
        }
        let document = ClipboardIndexedDocument(item: item)
        itemDocuments[item.id] = document
        return document
    }
}

@MainActor
final class ClipboardPanelViewModel: ObservableObject {
    struct State {
        let selectedTab: ClipboardTab
        let query: String
        let items: [ClipboardItem]
        let groups: [ClipboardGroup]
        let itemByID: [UUID: ClipboardItem]
        let groupByID: [UUID: ClipboardGroup]
        let itemIndexByID: [UUID: Int]
        let pinnedIDs: Set<UUID>
        let itemIDs: [UUID]
        let groupIDs: [UUID]
        let isSearching: Bool
        let resultRevision: UInt64

        static let empty = State(
            selectedTab: .all,
            query: "",
            items: [],
            groups: [],
            itemByID: [:],
            groupByID: [:],
            itemIndexByID: [:],
            pinnedIDs: [],
            itemIDs: [],
            groupIDs: [],
            isSearching: false,
            resultRevision: 0
        )
    }

    @Published private(set) var state = State.empty

    private let searchIndex: ClipboardSearchIndex
    private var snapshot = ClipboardSearchSnapshot(
        history: [],
        pinnedItems: [],
        groups: []
    )
    private var history: [ClipboardItem] = []
    private var pinnedItems: [ClipboardItem] = []
    private var groups: [ClipboardGroup] = []
    private var subscriptions = Set<AnyCancellable>()
    private var searchTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    convenience init() {
        self.init(
            store: ClipboardStore.shared,
            searchIndex: ClipboardSearchIndex.shared
        )
    }

    init(
        store: ClipboardStore,
        searchIndex: ClipboardSearchIndex
    ) {
        self.searchIndex = searchIndex

        store.$history
            .combineLatest(store.$pinnedItems, store.$groups)
            .sink { [weak self] history, pinnedItems, groups in
                self?.updateSources(
                    history: history,
                    pinnedItems: pinnedItems,
                    groups: groups
                )
            }
            .store(in: &subscriptions)
    }

    deinit {
        searchTask?.cancel()
    }

    func updateQuery(_ query: String) {
        guard query != state.query else { return }
        scheduleSearch(query: query)
    }

    func selectTab(_ tab: ClipboardTab) {
        guard tab != state.selectedTab else { return }
        publish(
            snapshot: snapshot,
            selectedTab: tab,
            query: state.query,
            isSearching: state.isSearching,
            incrementsResultRevision: true
        )
    }

    func hasContent(in tab: ClipboardTab) -> Bool {
        switch tab {
        case .favorites:
            return !pinnedItems.isEmpty
        case .groups:
            return !groups.isEmpty
        default:
            return history.contains { tab.includes($0) }
        }
    }

    private func updateSources(
        history: [ClipboardItem],
        pinnedItems: [ClipboardItem],
        groups: [ClipboardGroup]
    ) {
        self.history = history
        self.pinnedItems = pinnedItems
        self.groups = groups
        scheduleSearch(query: state.query)
    }

    private func scheduleSearch(query: String) {
        searchTask?.cancel()
        generation &+= 1
        let pendingGeneration = generation
        let history = self.history
        let pinnedItems = self.pinnedItems
        let groups = self.groups

        guard !query.isEmpty else {
            snapshot = ClipboardSearchSnapshot(
                history: history,
                pinnedItems: pinnedItems,
                groups: groups
            )
            publish(
                snapshot: snapshot,
                selectedTab: state.selectedTab,
                query: "",
                isSearching: false,
                incrementsResultRevision: true
            )
            return
        }

        publish(
            snapshot: snapshot,
            selectedTab: state.selectedTab,
            query: query,
            isSearching: true,
            incrementsResultRevision: false
        )
        searchTask = Task { [weak self, searchIndex] in
            do {
                let result = try await searchIndex.search(
                    query: query,
                    history: history,
                    pinnedItems: pinnedItems,
                    groups: groups
                )
                guard !Task.isCancelled,
                      let self,
                      pendingGeneration == generation else {
                    return
                }
                snapshot = result
                publish(
                    snapshot: result,
                    selectedTab: state.selectedTab,
                    query: query,
                    isSearching: false,
                    incrementsResultRevision: true
                )
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      pendingGeneration == generation else {
                    return
                }
                publish(
                    snapshot: snapshot,
                    selectedTab: state.selectedTab,
                    query: query,
                    isSearching: false,
                    incrementsResultRevision: false
                )
            }
        }
    }

    private func publish(
        snapshot: ClipboardSearchSnapshot,
        selectedTab: ClipboardTab,
        query: String,
        isSearching: Bool,
        incrementsResultRevision: Bool
    ) {
        let items = snapshot.items(for: selectedTab)
        let groups = selectedTab == .groups ? snapshot.groups : []
        state = State(
            selectedTab: selectedTab,
            query: query,
            items: items,
            groups: groups,
            itemByID: Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) }),
            groupByID: Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) }),
            itemIndexByID: Dictionary(
                uniqueKeysWithValues: items.enumerated().map { ($0.element.id, $0.offset) }
            ),
            pinnedIDs: Set(pinnedItems.map(\.id)),
            itemIDs: items.map(\.id),
            groupIDs: groups.map(\.id),
            isSearching: isSearching,
            resultRevision: incrementsResultRevision
                ? state.resultRevision &+ 1
                : state.resultRevision
        )
    }
}

func normalizedClipboardSearchText(_ text: String) -> String {
    text.folding(
        options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
        locale: .current
    )
    .lowercased()
    .trimmingCharacters(in: .whitespacesAndNewlines)
}

func clipboardSearchScore(query: String, segment: String) -> Int? {
    clipboardSearchScore(
        query: ClipboardNormalizedQuery(query),
        segment: ClipboardIndexedSegment(segment)
    )
}

func matchedClipboardItems(
    query: String,
    items: [ClipboardItem]
) -> [ClipboardItem] {
    let query = ClipboardNormalizedQuery(query)
    guard !query.text.isEmpty else { return items }

    var ranked = ClipboardRankedSources(capacity: items.count)
    for (index, item) in items.enumerated() {
        let document = ClipboardIndexedDocument(item: item)
        if let score = query.core.score(document: document.core) {
            ranked.append(index, score: score, timestamp: item.timestamp)
        }
    }
    return ranked.orderedSources.map { items[$0] }
}

func matchedClipboardGroups(
    query: String,
    groups: [ClipboardGroup]
) -> [ClipboardGroup] {
    let query = ClipboardNormalizedQuery(query)
    guard !query.text.isEmpty else { return groups }

    var ranked = ClipboardRankedSources(capacity: groups.count)
    for (index, group) in groups.enumerated() {
        let documents = [RustSearchDocument(segments: [ClipboardIndexedSegment(group.title).core])]
            + group.items.map { ClipboardIndexedDocument(item: $0).core }
        if let score = bestClipboardScore(
            query: query,
            documents: documents
        ) {
            ranked.append(index, score: score, timestamp: group.timestamp)
        }
    }
    return ranked.orderedSources.map { groups[$0] }
}

private struct ClipboardNormalizedQuery {
    let text: String
    let core: RustSearchSegment
    init(_ text: String) {
        let normalized = normalizedClipboardSearchText(text)
        self.text = normalized
        core = RustSearchSegment(normalizedText: normalized, numeric: normalized.allSatisfy(\.isNumber))
    }
}

private struct ClipboardIndexedDocument {
    let core: RustSearchDocument
    init(item: ClipboardItem) {
        core = RustSearchDocument(segments: item.searchableSegments.map { ClipboardIndexedSegment($0).core })
    }
}

private struct ClipboardIndexedSegment {
    let core: RustSearchSegment
    init(_ text: String) {
        core = RustSearchSegment(normalizedText: normalizedClipboardSearchText(text))
    }
}

private func clipboardSearchScore(query: ClipboardNormalizedQuery, segment: ClipboardIndexedSegment) -> Int? {
    query.core.score(segment: segment.core)
}

private func bestClipboardScore(
    query: ClipboardNormalizedQuery,
    documents: [RustSearchDocument]
) -> Int? {
    query.core.score(document: RustSearchDocument(documents: documents))
}

struct ClipboardRankedSources {
    private var sources: [Int] = []
    private var entries: [RustSearchRank] = []
    init(capacity: Int) {
        sources.reserveCapacity(capacity)
        entries.reserveCapacity(capacity)
    }
    mutating func append(_ source: Int, score: Int, timestamp: Date) {
        sources.append(source)
        entries.append(RustSearchRank(score: score, timestamp: timestamp.timeIntervalSinceReferenceDate))
    }
    var orderedSources: [Int] {
        RustSearchRanking.order(entries).map { sources[$0] }
    }
}
