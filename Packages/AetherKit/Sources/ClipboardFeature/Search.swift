/*
 * Clipboard
 * Copyright (C) 2026 Li Yuan
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

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

    convenience init(defaults: UserDefaults = .standard) {
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

        var rankedItems: [(item: ClipboardItem, score: Int)] = []
        rankedItems.reserveCapacity(allItems.count)
        for (offset, item) in allItems.enumerated() {
            if offset.isMultiple(of: 32) {
                try Task.checkCancellation()
            }
            let document = indexedDocument(for: item)
            if let score = bestClipboardScore(
                query: query,
                segments: document.segments
            ) {
                rankedItems.append((item, score))
            }
        }
        rankedItems.sort(by: clipboardItemRankPrecedes)

        var rankedGroups: [(group: ClipboardGroup, score: Int)] = []
        rankedGroups.reserveCapacity(groups.count)
        for (offset, group) in groups.enumerated() {
            if offset.isMultiple(of: 16) {
                try Task.checkCancellation()
            }
            let segments = [ClipboardIndexedSegment(group.title)]
                + group.items.flatMap { indexedDocument(for: $0).segments }
            if let score = bestClipboardScore(
                query: query,
                segments: segments
            ) {
                rankedGroups.append((group, score))
            }
        }
        rankedGroups.sort(by: clipboardGroupRankPrecedes)
        try Task.checkCancellation()

        return ClipboardSearchSnapshot(
            rankedItems: rankedItems.map(\.item),
            pinnedIDs: Set(pinnedItems.map(\.id)),
            rankedGroups: rankedGroups.map(\.group)
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

    return items.compactMap { item -> (ClipboardItem, Int)? in
        let document = ClipboardIndexedDocument(item: item)
        guard let score = bestClipboardScore(
            query: query,
            segments: document.segments
        ) else {
            return nil
        }
        return (item, score)
    }
    .sorted { left, right in
        clipboardItemRankPrecedes(
            (item: left.0, score: left.1),
            (item: right.0, score: right.1)
        )
    }
    .map(\.0)
}

func matchedClipboardGroups(
    query: String,
    groups: [ClipboardGroup]
) -> [ClipboardGroup] {
    let query = ClipboardNormalizedQuery(query)
    guard !query.text.isEmpty else { return groups }

    return groups.compactMap { group -> (ClipboardGroup, Int)? in
        let segments = [ClipboardIndexedSegment(group.title)]
            + group.items.flatMap { ClipboardIndexedDocument(item: $0).segments }
        guard let score = bestClipboardScore(
            query: query,
            segments: segments
        ) else {
            return nil
        }
        return (group, score)
    }
    .sorted { left, right in
        clipboardGroupRankPrecedes(
            (group: left.0, score: left.1),
            (group: right.0, score: right.1)
        )
    }
    .map(\.0)
}

private struct ClipboardNormalizedQuery {
    let text: String
    let characters: [Character]
    let isNumeric: Bool
    let asciiMask: ClipboardASCIIMask

    init(_ text: String) {
        let normalized = normalizedClipboardSearchText(text)
        self.text = normalized
        characters = Array(normalized)
        isNumeric = normalized.allSatisfy(\.isNumber)
        asciiMask = ClipboardASCIIMask(normalized)
    }
}

private struct ClipboardIndexedDocument {
    let segments: [ClipboardIndexedSegment]

    init(item: ClipboardItem) {
        segments = item.searchableSegments.map(ClipboardIndexedSegment.init)
    }
}

private struct ClipboardIndexedSegment {
    let text: String
    let characterCount: Int
    let asciiMask: ClipboardASCIIMask

    init(_ text: String) {
        let normalized = normalizedClipboardSearchText(text)
        self.text = normalized
        characterCount = normalized.count
        asciiMask = ClipboardASCIIMask(normalized)
    }
}

private struct ClipboardASCIIMask {
    private let lower: UInt64
    private let upper: UInt64

    init(_ text: String) {
        var lower: UInt64 = 0
        var upper: UInt64 = 0
        for byte in text.utf8 where byte < 128 {
            if byte < 64 {
                lower |= UInt64(1) << UInt64(byte)
            } else {
                upper |= UInt64(1) << UInt64(byte - 64)
            }
        }
        self.lower = lower
        self.upper = upper
    }

    func contains(_ other: ClipboardASCIIMask) -> Bool {
        lower & other.lower == other.lower
            && upper & other.upper == other.upper
    }
}

private func clipboardSearchScore(
    query: ClipboardNormalizedQuery,
    segment: ClipboardIndexedSegment
) -> Int? {
    guard !query.text.isEmpty, !segment.text.isEmpty else { return nil }

    if segment.text.hasPrefix(query.text) {
        return 20_000 - min(segment.characterCount, 5_000)
    }
    if let range = segment.text.range(of: query.text) {
        return 15_000 - min(
            segment.text.distance(
                from: segment.text.startIndex,
                to: range.lowerBound
            ),
            5_000
        )
    }

    guard !query.isNumeric,
          query.characters.count <= 16,
          segment.characterCount <= 1_024,
          segment.asciiMask.contains(query.asciiMask) else {
        return nil
    }

    var queryIndex = 0
    var firstMatch: Int?
    var lastMatch = 0
    var previousMatch: Int?
    var contiguousPairs = 0
    let maximumSpan = max(
        query.characters.count + 8,
        query.characters.count * 3
    )

    for (segmentIndex, character) in segment.text.enumerated() {
        if let firstMatch,
           segmentIndex - firstMatch + 1 > maximumSpan {
            return nil
        }
        guard character == query.characters[queryIndex] else { continue }
        if firstMatch == nil {
            firstMatch = segmentIndex
        }
        if let previousMatch, segmentIndex == previousMatch + 1 {
            contiguousPairs += 1
        }
        previousMatch = segmentIndex
        lastMatch = segmentIndex
        queryIndex += 1
        if queryIndex == query.characters.count {
            break
        }
    }

    guard queryIndex == query.characters.count,
          let firstMatch else {
        return nil
    }
    let span = lastMatch - firstMatch + 1
    return 1_000
        + query.characters.count * 40
        + contiguousPairs * 25
        - span
        - firstMatch
}

private func bestClipboardScore(
    query: ClipboardNormalizedQuery,
    segments: [ClipboardIndexedSegment]
) -> Int? {
    var bestScore: Int?
    for segment in segments {
        guard let score = clipboardSearchScore(
            query: query,
            segment: segment
        ) else {
            continue
        }
        bestScore = max(bestScore ?? score, score)
    }
    return bestScore
}

private func clipboardItemRankPrecedes(
    _ left: (item: ClipboardItem, score: Int),
    _ right: (item: ClipboardItem, score: Int)
) -> Bool {
    left.score == right.score
        ? left.item.timestamp > right.item.timestamp
        : left.score > right.score
}

private func clipboardGroupRankPrecedes(
    _ left: (group: ClipboardGroup, score: Int),
    _ right: (group: ClipboardGroup, score: Int)
) -> Bool {
    left.score == right.score
        ? left.group.timestamp > right.group.timestamp
        : left.score > right.score
}
