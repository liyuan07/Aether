// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import RustCore
@testable import ClipboardFeature

final class RustSearchParityTests: XCTestCase {
    func testSharedTypeVocabularyPreservesEverySegmentScoreAndReleasesWrappers() async {
        var vocabulary: ClipboardSearchVocabulary? = ClipboardSearchVocabulary()
        var documents: [(ClipboardItem, RustSearchDocument)] = []
        let bodies = ["", "文本", "图片", "CAFÉ 中文", "👨‍👩‍👦", "a\u{0000}b", "clip board manager"]
        for type in ClipboardItemType.allCases {
            let first = vocabulary!.segment(for: type)
            XCTAssertTrue(first === vocabulary!.segment(for: type))
            for body in bodies {
                let item = ClipboardItem(stringData: body, type: type)
                documents.append((item, ClipboardIndexedDocument(item: item, typeSegment: first).core))
            }
        }
        let files = ClipboardItem(fileURLs:["file:///tmp/文本/CAF%C3%89.txt", "file:///tmp/中文/name"])
        documents.append((files, ClipboardIndexedDocument(item: files, typeSegment: vocabulary!.segment(for: .file)).core))
        weak var witness = vocabulary!.segment(for: .text)
        vocabulary = nil
        XCTAssertNil(witness, "Documents must retain Rust segments without retaining Swift vocabulary wrappers")
        for raw in bodies + ClipboardItemType.allCases.map(\.displayName) + ["文本", "café", "clipman", "name", "missing"] {
            let normalized = normalizedClipboardSearchText(raw)
            let query = RustSearchSegment(normalizedText: normalized, numeric: normalized.allSatisfy(\.isNumber))
            for (item, document) in documents {
                let expected = item.searchableSegments.compactMap {
                    referenceClipboardSearchScore(query: ReferenceClipboardNormalizedQuery(raw), segment: ReferenceClipboardIndexedSegment($0))
                }.max()
                XCTAssertEqual(query.score(document: document), expected)
            }
        }
        let document = documents.first { $0.0.type == .text }!.1
        let query = RustSearchSegment(normalizedText: normalizedClipboardSearchText("文本"))
        let expected = query.score(document: document)
        await withTaskGroup(of: Int?.self) { group in
            for _ in 0..<128 { group.addTask { query.score(document: document) } }
            for await score in group { XCTAssertEqual(score, expected) }
        }
    }

    func testRankingBenchmark() throws {
        guard ProcessInfo.processInfo.environment["AETHER_RUN_CORE_BENCHMARKS"] == "1" else { throw XCTSkip("Run explicitly for ranking comparison") }
        let items = (0..<10_000).map { ClipboardItem(stringData: "Synthetic ranking item \($0)", type: .text, timestamp: Date(timeIntervalSinceReferenceDate: Double(($0 * 7919) % 10000))) }
        func original() -> [ClipboardItem] {
            var candidates: [(item: ClipboardItem, score: Int)] = items.enumerated().map { pair in
                (item: pair.element, score: pair.offset % 7)
            }
            candidates.sort { a,b in
                a.score == b.score ? a.item.timestamp > b.item.timestamp : a.score > b.score
            }
            return candidates.map(\.item)
        }
        func migrated() -> [ClipboardItem] {
            var ranked = ClipboardRankedSources(capacity: items.count)
            for (index,item) in items.enumerated() { ranked.append(index,score: index % 7,timestamp: item.timestamp) }
            return ranked.orderedSources.map { items[$0] }
        }
        XCTAssertEqual(original().map(\.id), migrated().map(\.id))
        var oldChecksum = 0, newChecksum = 0
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<20 { let ranked = original(); oldChecksum &+= ranked.count + Int(ranked[0].timestamp.timeIntervalSinceReferenceDate) }
        let oldNS = DispatchTime.now().uptimeNanoseconds - start
        let migratedStart = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<20 { let ranked = migrated(); newChecksum &+= ranked.count + Int(ranked[0].timestamp.timeIntervalSinceReferenceDate) }
        let newNS = DispatchTime.now().uptimeNanoseconds - migratedStart
        XCTAssertEqual(oldChecksum,newChecksum)
        print("AETHER_RANKING_BENCHMARK items=10000 iterations=20 native_ns=\(oldNS) rust_ns=\(newNS) native_candidate_stride=\(MemoryLayout<(ClipboardItem,Int)>.stride) rust_entry_stride=\(MemoryLayout<RustSearchRank>.stride)")
    }

    func testItemAndGroupRankingMatchesIndependentOriginalScorer() async throws {
        let phrases = ["shared", "shared more", "x shared", "clip board manager", "中文 shared", "shared cafe\u{301}"]
        let items = (0..<240).map { index in
            ClipboardItem(stringData: phrases[index % phrases.count], type: .text,
                timestamp: Date(timeIntervalSinceReferenceDate: Double(index % 5)))
        }
        let groups = (0..<30).map { index in
            ClipboardGroup(timestamp: Date(timeIntervalSinceReferenceDate: Double(index % 3)), items: [items[index], items[index + 60]])
        }
        func originalOrder(_ segments: [[String]], dates: [Date], raw: String) -> [Int] {
            let query = ReferenceClipboardNormalizedQuery(raw)
            return segments.enumerated().compactMap { index, segments -> (Int, Int)? in
                guard let score = segments.compactMap({ referenceClipboardSearchScore(query: query, segment: ReferenceClipboardIndexedSegment($0)) }).max() else { return nil }
                return (index, score)
            }.sorted { a, b in a.1 == b.1 ? dates[a.0] > dates[b.0] : a.1 > b.1 }.map(\.0)
        }
        let pinned = Array(items.suffix(20))
        let pinnedIDs = Set(pinned.map(\.id))
        for raw in ["shared", "clipman", "中文", "missing", "文本"] {
            let expectedItems = originalOrder(items.map(\.searchableSegments), dates: items.map(\.timestamp), raw: raw).map { items[$0] }
            let expectedGroups = originalOrder(groups.map { [$0.title] + $0.items.flatMap(\.searchableSegments) }, dates: groups.map(\.timestamp), raw: raw).map { groups[$0].id }
            XCTAssertEqual(matchedClipboardItems(query: raw, items: items).map(\.id), expectedItems.map(\.id))
            XCTAssertEqual(matchedClipboardGroups(query: raw, groups: groups).map(\.id), expectedGroups)
            let snapshot = try await ClipboardSearchIndex().search(query: raw, history: Array(items.dropLast(20)), pinnedItems: pinned, groups: groups)
            XCTAssertEqual(snapshot.items(for: .all).map(\.id), expectedItems.filter { !pinnedIDs.contains($0.id) }.map(\.id))
            XCTAssertEqual(snapshot.items(for: .favorites).map(\.id), expectedItems.filter { pinnedIDs.contains($0.id) }.map(\.id))
            XCTAssertEqual(snapshot.groups.map(\.id), expectedGroups)
        }
    }

    func testStableRankingMatchesOriginalNativeComparator() {
        func check(_ entries: [RustSearchRank]) {
            let expected = entries.indices.sorted { a, b in
                entries[a].score == entries[b].score
                    ? Date(timeIntervalSinceReferenceDate: entries[a].timestamp) > Date(timeIntervalSinceReferenceDate: entries[b].timestamp)
                    : entries[a].score > entries[b].score
            }
            XCTAssertEqual(RustSearchRanking.order(entries), expected)
        }
        check([])
        for timestamp in [Double.nan, .infinity, -.infinity, -0.0, 0.0, .leastNonzeroMagnitude, .greatestFiniteMagnitude] {
            check([.init(score: .min, timestamp: timestamp), .init(score: .max, timestamp: timestamp), .init(score: .max, timestamp: timestamp), .init(score: .max, timestamp: 1)])
        }
        var seed: UInt64 = 987654321
        for iteration in 0..<1_000 {
            let entries = (0..<(iteration % 257)).map { _ -> RustSearchRank in
                seed = seed &* 6364136223846793005 &+ 1
                return .init(score: Int(seed % 7) - 3, timestamp: Double((seed >> 32) % 11) / 4 - 1)
            }
            check(entries)
        }
    }

    func testOwnedDocumentReleasesSwiftWrappersAndRetainsMergedScoring() async {
        let raw = "clip board manager 中文"
        let query = RustSearchSegment(normalizedText: "clipman")
        let expected = referenceClipboardSearchScore(query: ReferenceClipboardNormalizedQuery("clipman"), segment: ReferenceClipboardIndexedSegment(raw))
        var segment: RustSearchSegment? = RustSearchSegment(normalizedText: raw)
        weak var segmentWitness = segment
        var document: RustSearchDocument? = RustSearchDocument(segments: [segment!, segment!])
        segment = nil
        XCTAssertNil(segmentWitness, "Rust ownership must not keep a Swift segment wrapper alive")
        let merged = RustSearchDocument(documents: [document!, RustSearchDocument(segments: [])])
        weak var documentWitness = document
        document = nil
        XCTAssertNil(documentWitness, "Merged documents own their segments independently")
        XCTAssertEqual(query.score(document: merged), expected)
        await withTaskGroup(of: Int?.self) { group in
            for _ in 0..<256 { group.addTask { query.score(document: merged) } }
            for await score in group { XCTAssertEqual(score, expected) }
        }
        XCTAssertNil(query.score(document: RustSearchDocument(documents: [])))
    }

    func testBoundaryCompressionPreservesNativeSearchAcrossOffsetWidths() {
        for length in [240, 255, 256, 65_520, 65_535, 65_536] {
            let segment = String(repeating: "a", count: length) + "中文\r\n👨‍👩‍👦 cafe\u{301}"
            let reference = ReferenceClipboardIndexedSegment(segment)
            for raw in ["中文", "a中文", "👨", "👨‍👩‍👦", "café", "missing"] {
                XCTAssertEqual(clipboardSearchScore(query: raw, segment: segment),
                    referenceClipboardSearchScore(query: ReferenceClipboardNormalizedQuery(raw), segment: reference))
            }
        }
    }

    func testDocumentAggregationMatchesIndividualScoring() {
        let corpus = ["", "123456789", "cafe\u{301}", "中文剪贴板", "👨‍👩‍👦 family", "clip board manager", "a\u{0000}b", String(repeating: "x", count: 1_025)]
        for raw in corpus + ["123", "café", "family", "剪板", "clipman", "missing"] {
            let text = normalizedClipboardSearchText(raw)
            let query = RustSearchSegment(normalizedText: text, numeric: text.allSatisfy(\.isNumber))
            for count in 0..<80 {
                let segments = (0..<count).map { RustSearchSegment(normalizedText: normalizedClipboardSearchText(corpus[($0 + count) % corpus.count])) }
                XCTAssertEqual(query.score(document: RustSearchDocument(segments: segments)), segments.compactMap { query.score(segment: $0) }.max())
            }
        }
    }

    func testDocumentAggregationBenchmark() throws {
        guard ProcessInfo.processInfo.environment["AETHER_RUN_CORE_BENCHMARKS"] == "1" else { throw XCTSkip("Run explicitly for bridge comparison") }
        let query = RustSearchSegment(normalizedText: "clipman")
        for count in [1, 8, 64] {
            let segments = (0..<count).map { RustSearchSegment(normalizedText: "clipboard manager synthetic item \($0)") }
            let document = RustSearchDocument(segments: segments)
            var original = 0, batch = 0
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<20_000 {
                var best: Int?
                for segment in segments {
                    if let score = query.score(segment: segment) { best = max(best ?? score, score) }
                }
                original &+= best ?? -1
            }
            let originalNS = DispatchTime.now().uptimeNanoseconds - start
            let batchStart = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<20_000 { batch &+= query.score(document: document) ?? -1 }
            let batchNS = DispatchTime.now().uptimeNanoseconds - batchStart
            XCTAssertEqual(original, batch)
            print("AETHER_DOCUMENT_BRIDGE_BENCHMARK segments=\(count) iterations=20000 individual_ns=\(originalNS) batch_ns=\(batchNS)")
        }
    }
    func testCachedScorerBenchmark() throws {
        guard ProcessInfo.processInfo.environment["AETHER_RUN_CORE_BENCHMARKS"] == "1" else {
            throw XCTSkip("Run explicitly for Release Rust/Swift comparison")
        }
        let texts = (0..<20_000).map { index in
            normalizedClipboardSearchText(String(repeating: "clipboard manager item \(index) content ", count: 6))
        }
        let reference = texts.map(ReferenceClipboardIndexedSegment.init)
        let rust = texts.map { RustSearchSegment(normalizedText: $0) }
        let queries = ["clipman", "item", "999", "missing", "content", "manager"]
        var referenceTotal = 0, rustTotal = 0
        let referenceStart = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<5 {
            for raw in queries {
                let query = ReferenceClipboardNormalizedQuery(raw)
                for segment in reference { referenceTotal &+= referenceClipboardSearchScore(query: query, segment: segment) ?? -1 }
            }
        }
        let referenceNs = DispatchTime.now().uptimeNanoseconds - referenceStart
        let rustStart = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<5 {
            for raw in queries {
                let query = RustSearchSegment(normalizedText: raw, numeric: raw.allSatisfy(\.isNumber))
                for segment in rust { rustTotal &+= query.score(segment: segment) ?? -1 }
            }
        }
        let rustNs = DispatchTime.now().uptimeNanoseconds - rustStart
        XCTAssertEqual(rustTotal, referenceTotal)
        print("AETHER_CACHED_SCORER_BENCHMARK evaluations=600000 swift_ns=\(referenceNs) rust_ns=\(rustNs)")
    }

    func testRustScoresMatchOriginalSwiftForGeneratedUnicodeAndBoundaries() {
        let corpus = ["", "clipboard manager", "clip board manager", "123456789", "1x2x3", "Café", "ＡＢＣ", "中文剪贴板", "👨‍👩‍👦 family", "🇨🇳中文", "a\r\nb", "cafe\u{301}", "가 가나다", "a\u{20dd}abc", String(repeating: "x", count: 1_025)]
        let queries = corpus + ["clipman", "123", "abc", "family", "👨", "🇨", "cafe", "剪板", "가", "a", "b"]
        for segment in corpus {
            for query in queries {
                XCTAssertEqual(clipboardSearchScore(query: query, segment: segment),
                    referenceClipboardSearchScore(query: ReferenceClipboardNormalizedQuery(query), segment: ReferenceClipboardIndexedSegment(segment)),
                    "Rust search differed from the original Swift scorer")
            }
        }
        var seed: UInt64 = 12345
        let alphabet = Array("abcxyz 123中文")
        func generate(_ count: Int) -> String {
            String((0..<count).map { _ in
                seed = seed &* 6364136223846793005 &+ 1
                return alphabet[Int((seed >> 32) % UInt64(alphabet.count))]
            })
        }
        for _ in 0..<2_000 {
            let segment = generate(30)
            let query = generate(3)
            XCTAssertEqual(clipboardSearchScore(query: query, segment: segment),
                referenceClipboardSearchScore(query: ReferenceClipboardNormalizedQuery(query), segment: ReferenceClipboardIndexedSegment(segment)))
        }
    }
}

private struct ReferenceClipboardNormalizedQuery {
    let text: String
    let characters: [Character]
    let isNumeric: Bool
    let asciiMask: ReferenceClipboardASCIIMask

    init(_ text: String) {
        let normalized = normalizedClipboardSearchText(text)
        self.text = normalized
        characters = Array(normalized)
        isNumeric = normalized.allSatisfy(\.isNumber)
        asciiMask = ReferenceClipboardASCIIMask(normalized)
    }
}

private struct ReferenceClipboardIndexedDocument {
    let segments: [ReferenceClipboardIndexedSegment]

    init(item: ClipboardItem) {
        segments = item.searchableSegments.map(ReferenceClipboardIndexedSegment.init)
    }
}

private struct ReferenceClipboardIndexedSegment {
    let text: String
    let characterCount: Int
    let asciiMask: ReferenceClipboardASCIIMask

    init(_ text: String) {
        let normalized = normalizedClipboardSearchText(text)
        self.text = normalized
        characterCount = normalized.count
        asciiMask = ReferenceClipboardASCIIMask(normalized)
    }
}

private struct ReferenceClipboardASCIIMask {
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

    func contains(_ other: ReferenceClipboardASCIIMask) -> Bool {
        lower & other.lower == other.lower
            && upper & other.upper == other.upper
    }
}

private func referenceClipboardSearchScore(
    query: ReferenceClipboardNormalizedQuery,
    segment: ReferenceClipboardIndexedSegment
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
