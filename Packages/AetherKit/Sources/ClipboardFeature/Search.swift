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
    private let rankedItems: [ClipboardItem]
    private let buckets: RustClipboardSearchBuckets
    let groups: [ClipboardGroup]

    init(
        history: [ClipboardItem],
        pinnedItems: [ClipboardItem],
        groups: [ClipboardGroup]
    ) {
        self.init(rankedItems: pinnedItems.isEmpty ? history : history + pinnedItems,
            pinnedIDs: Set(pinnedItems.map(\.id)), rankedGroups: groups)
    }

    init(
        rankedItems: [ClipboardItem],
        pinnedIDs: Set<UUID>,
        rankedGroups: [ClipboardGroup]
    ) {
        self.rankedItems = rankedItems
        buckets = RustClipboardSearchBuckets(entries: rankedItems.map {
            RustSearchBucketEntry(kind: $0.type.rustKind, pinned: pinnedIDs.contains($0.id) ? 1 : 0)
        })
        groups = rankedGroups
    }

    func items(for tab: ClipboardTab) -> [ClipboardItem] {
        buckets.values(from: rankedItems, tab: tab.rustTab)
    }
}

actor ClipboardSearchIndex {
    static let shared = ClipboardSearchIndex()

    private let itemDocuments = RustSearchDocumentCache()
    private var vocabulary = ClipboardSearchVocabulary()

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
        itemDocuments.beginSourceUpdate()
        for item in allItems { itemDocuments.retainSource(item.id) }
        for group in groups { for item in group.items { itemDocuments.retainSource(item.id) } }
        itemDocuments.finishSourceUpdate()

        var rankedItems = ClipboardRankedSources(capacity: allItems.count)
        for (offset, item) in allItems.enumerated() {
            if offset.isMultiple(of: 32) {
                try Task.checkCancellation()
            }
            let cached = itemDocuments.score(query: query.core, for: item.id)
            let score = cached.found ? cached.score : query.core.score(document: indexedDocument(for: item).core)
            if let score { rankedItems.append(offset, score: score, timestamp: item.timestamp) }
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
        if let cached = itemDocuments.document(for: item.id) {
            return ClipboardIndexedDocument(core: cached)
        }
        let document = ClipboardIndexedDocument(item: item, typeSegment: vocabulary.segment(for: item.type))
        itemDocuments.insert(document.core, for: item.id)
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
        let itemIndexByID: [UUID: Int]
        let groupIndexByID: [UUID: Int]
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
            itemIndexByID: [:],
            groupIndexByID: [:],
            pinnedIDs: [],
            itemIDs: [],
            groupIDs: [],
            isSearching: false,
            resultRevision: 0
        )
        func item(withID id: UUID) -> ClipboardItem? {
            itemIndexByID[id].map { items[$0] }
        }
        func group(withID id: UUID) -> ClipboardGroup? {
            groupIndexByID[id].map { groups[$0] }
        }
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
            itemIndexByID: Dictionary(
                uniqueKeysWithValues: items.enumerated().map { ($0.element.id, $0.offset) }
            ),
            groupIndexByID: Dictionary(
                uniqueKeysWithValues: groups.enumerated().map { ($0.element.id, $0.offset) }
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
    var vocabulary = ClipboardSearchVocabulary()
    for (index, item) in items.enumerated() {
        let document = ClipboardIndexedDocument(item: item, typeSegment: vocabulary.segment(for: item.type))
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
    var vocabulary = ClipboardSearchVocabulary()
    for (index, group) in groups.enumerated() {
        let documents = [RustSearchDocument(segments: [ClipboardIndexedSegment(group.title).core])]
            + group.items.map { ClipboardIndexedDocument(item: $0, typeSegment: vocabulary.segment(for: $0.type)).core }
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

/// Only the finite platform type labels are cached; arbitrary user text is never interned here.
struct ClipboardSearchVocabulary {
    private var labels: [ClipboardItemType: RustSearchSegment] = [:]
    mutating func segment(for type: ClipboardItemType) -> RustSearchSegment {
        if let cached = labels[type] { return cached }
        let segment = RustSearchSegment(normalizedText: normalizedClipboardSearchText(type.displayName))
        labels[type] = segment
        return segment
    }
}

struct ClipboardIndexedDocument {
    let core: RustSearchDocument
    init(core: RustSearchDocument) { self.core = core }
    init(item: ClipboardItem, typeSegment: RustSearchSegment) {
        core = RustSearchDocument(segments: item.searchableSegments.map {
            $0 == item.type.displayName ? typeSegment : ClipboardIndexedSegment($0).core
        })
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
