// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CAetherCore

/// Owns an immutable Rust buffer. Concurrent scoring only borrows it; ARC frees
/// it after the last Swift borrower, so no Rust pointers escape this adapter.
public final class RustSearchSegment: @unchecked Sendable {
    fileprivate let handle: UnsafeMutableRawPointer?

    public init(normalizedText: String, numeric: Bool = false) {
        precondition(aether_core_abi_version() == 1, "Unsupported Rust core ABI")
        // ASCII has identical canonical form; borrow Swift's contiguous UTF-8
        // directly rather than building and copying an intermediate byte array.
        let isASCII = normalizedText.utf8.allSatisfy { $0 < 128 }
        let text = isASCII ? normalizedText : normalizedText.precomposedStringWithCanonicalMapping
        var boundaries: [Int] = []
        if !isASCII {
            boundaries = [0]
            for character in text { boundaries.append(boundaries.last! + character.utf8.count) }
        }
        func create(_ bytes: UnsafeBufferPointer<UInt8>) -> UnsafeMutableRawPointer? {
            boundaries.withUnsafeBufferPointer {
                aether_search_create(bytes.baseAddress, bytes.count, isASCII ? nil : $0.baseAddress, $0.count, numeric ? 1 : 0)
            }
        }
        if let result = text.utf8.withContiguousStorageIfAvailable(create) {
            handle = result
        } else {
            handle = Array(text.utf8).withUnsafeBufferPointer(create)
        }

    }

    deinit { aether_search_destroy(handle) }

    public func score(segment: RustSearchSegment) -> Int? {
        let score = aether_search_score(handle, segment.handle)
        return score < 0 ? nil : Int(score)
    }

    public func score(document: RustSearchDocument) -> Int? {
        guard !document.segments.isEmpty else { return nil }
        if document.segments.count == 1 { return score(segment: document.segments[0]) }
        let score = withExtendedLifetime(document) {
            document.handles.withUnsafeBufferPointer { aether_search_best_score(handle, $0.baseAddress, $0.count) }
        }
        return score < 0 ? nil : Int(score)
    }
}

/// Immutable bridge span, cached alongside normalized document segments.
public final class RustSearchDocument: @unchecked Sendable {
    fileprivate let segments: [RustSearchSegment]
    fileprivate let handles: [UnsafeRawPointer?]
    public init(segments: [RustSearchSegment]) {
        self.segments = segments
        handles = segments.map { $0.handle.map(UnsafeRawPointer.init) }
    }
}
