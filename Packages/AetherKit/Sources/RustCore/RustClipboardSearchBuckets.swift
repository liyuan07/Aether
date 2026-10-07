// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import CAetherCore

public typealias RustSearchBucketEntry = AetherSearchBucketEntry

/// Owns classification indices only; native values remain in one source array.
public final class RustClipboardSearchBuckets: @unchecked Sendable {
    private let handle: UnsafeMutableRawPointer?
    private let sourceCount: Int
    public init(entries: [RustSearchBucketEntry]) {
        sourceCount = entries.count
        handle = entries.withUnsafeBufferPointer { aether_clipboard_search_buckets_create($0.baseAddress, $0.count) }
        precondition(handle != nil, "Unable to create clipboard search buckets")
    }
    deinit { aether_clipboard_search_buckets_destroy(handle) }

    public func values<Value>(from source: [Value], tab: UInt8) -> [Value] {
        precondition(source.count == sourceCount, "Clipboard bucket source count changed")
        return withExtendedLifetime(self) {
            let view = aether_clipboard_search_buckets_view(handle, tab)
            if view.identity != 0 { return source }
            return UnsafeBufferPointer(start: view.indices, count: view.count).map { source[$0] }
        }
    }
}
