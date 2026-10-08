// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CAetherCore

/// Immutable core-owned identity table. Swift ARC keeps it alive across display snapshot copies.
public final class RustIdentityIndex: @unchecked Sendable {
    private let handle: UnsafeMutableRawPointer?
    public init(_ ids: [UUID], requiringUnique: Bool = false) {
        handle = ids.map { AetherUUID(bytes: $0.uuid) }.withUnsafeBufferPointer {
            aether_identity_index_create($0.baseAddress, $0.count)
        }
        precondition(handle != nil, "Unable to create identity index")
        if requiringUnique { precondition(aether_identity_index_unique(handle) != 0, "Duplicate identity in display snapshot") }
    }
    deinit { aether_identity_index_destroy(handle) }
    public subscript(_ id: UUID) -> Int? {
        let position = aether_identity_index_find(handle, .init(bytes: id.uuid))
        return position < 0 ? nil : position
    }
    public func contains(_ id: UUID) -> Bool { self[id] != nil }
}
