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
        let score = withExtendedLifetime(document) {
            aether_search_document_score(handle, document.handle)
        }
        return score < 0 ? nil : Int(score)
    }
}

/// Rust owns the immutable segment collection. No Swift segment array or
/// borrowed pointer span remains after initialization.
public final class RustSearchDocument: @unchecked Sendable {
    fileprivate let handle: UnsafeMutableRawPointer?
    fileprivate init(taking handle: UnsafeMutableRawPointer) { self.handle = handle }
    public init(segments: [RustSearchSegment]) {
        handle = withExtendedLifetime(segments) {
            segments.map { $0.handle.map(UnsafeRawPointer.init) }.withUnsafeBufferPointer {
                aether_search_document_create($0.baseAddress, $0.count)
            }
        }
    }
    public init(documents: [RustSearchDocument]) {
        handle = withExtendedLifetime(documents) {
            documents.map { $0.handle.map(UnsafeRawPointer.init) }.withUnsafeBufferPointer {
                aether_search_document_merge($0.baseAddress, $0.count)
            }
        }
    }
    deinit { aether_search_document_destroy(handle) }
}

/// Confine this mutable cache to one actor/executor. Returned documents are immutable and
/// independently owned; removing a cache entry never invalidates a reader.
public final class RustSearchDocumentCache {
    private let handle = aether_search_cache_create()
    public init() {}
    deinit { aether_search_cache_destroy(handle) }
    public func beginSourceUpdate() { aether_search_cache_begin(handle) }
    public func retainSource(_ id: UUID) { aether_search_cache_mark(handle, .init(bytes: id.uuid)) }
    public func finishSourceUpdate() { aether_search_cache_prune(handle) }
    public func document(for id: UUID) -> RustSearchDocument? {
        guard let document = aether_search_cache_get(handle, .init(bytes: id.uuid)) else { return nil }
        return RustSearchDocument(taking: document)
    }
    public func score(query: RustSearchSegment, for id: UUID) -> (found: Bool, score: Int?) {
        let result = withExtendedLifetime(query) { aether_search_cache_score(handle, .init(bytes: id.uuid), query.handle) }
        return (result.found != 0, result.score < 0 ? nil : Int(result.score))
    }
    public func insert(_ document: RustSearchDocument, for id: UUID) {
        withExtendedLifetime(document) { aether_search_cache_insert(handle, .init(bytes: id.uuid), document.handle) }
    }
}
