// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import RustCore
@testable import ClipboardFeature

final class RustSearchParityTests: XCTestCase {
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
