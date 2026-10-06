// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CAetherCore

// Domain-layer mirror of WhatPortIOKit's RawLifecycleSignal. WhatPortCore
// never imports WhatPortIOKit, so it carries its own copy of the same four
// signal kinds rather than referencing the IOKit layer's type.
public enum LifecycleSignalKind: Sendable, Equatable {
    case attach
    case negotiating
    case contractEstablished
    case transportReady
}

// Deliberately no .connected case: "connected" is just the absence of a
// tracked phase, plus the normal PortState rendering already carrying the
// real link data once one exists.
public enum PortLifecyclePhase: Sendable, Equatable {
    case detecting
    case negotiating
}

public struct PortLifecycleSignalInput: Sendable, Equatable {
    public let portID: Int
    public let signal: LifecycleSignalKind

    public init(portID: Int, signal: LifecycleSignalKind) {
        self.portID = portID
        self.signal = signal
    }
}

// Tracks per-port connection-lifecycle phase from IOAccessoryManager
// notification signals. Those codes are private, undocumented, and observed
// to be noisy: they repeat, and can arrive out of order. So this machine
// never treats them as a strict sequence, only as loose hints with timeout
// backstops to guarantee a phase never gets stuck.
//
// This is an implementation detail of PortManager (which owns the instance
// and the reconciliation clock via applySnapshot); it is public only so the
// test target can exercise it directly.
public struct PortLifecycleStateMachine: Sendable {
    public static let staleTimeout: TimeInterval = 3
    public static let maxPhaseDuration: TimeInterval = 6
    private final class Storage: @unchecked Sendable {
        let handle: UnsafeMutableRawPointer?
        init() { handle = aether_port_lifecycle_create() }
        init(copying source: Storage) { handle = aether_port_lifecycle_clone(source.handle) }
        deinit { aether_port_lifecycle_destroy(handle) }
    }
    private var storage = Storage()
    public init() {}
    // Copy-on-write preserves the original public struct's independent value semantics.
    private mutating func makeUnique() {
        if !isKnownUniquelyReferenced(&storage) { storage = Storage(copying: storage) }
    }
    public var phases: [Int: PortLifecyclePhase] {
        let count = aether_port_lifecycle_phases(storage.handle, nil, 0)
        var rows = [AetherPortPhase](repeating: .init(), count: count)
        rows.withUnsafeMutableBufferPointer { buffer in
            _ = aether_port_lifecycle_phases(storage.handle, buffer.baseAddress, buffer.count)
        }
        return Dictionary(uniqueKeysWithValues: rows.map { (Int($0.port_id), $0.phase == 0 ? .detecting : .negotiating) })
    }
    public mutating func handle(_ signal: LifecycleSignalKind, portID: Int, at now: Date) {
        makeUnique()
        let code: UInt8
        switch signal {
        case .attach: code = 0
        case .negotiating: code = 1
        case .contractEstablished: code = 2
        case .transportReady: code = 3
        }
        aether_port_lifecycle_handle(storage.handle, code, Int64(portID), now.timeIntervalSinceReferenceDate)
    }
    public mutating func reconcile(disconnectedPortIDs: Set<Int>, resolvedPortIDs: Set<Int>, now: Date) {
        makeUnique()
        let disconnected = disconnectedPortIDs.map(Int64.init)
        let resolved = resolvedPortIDs.map(Int64.init)
        disconnected.withUnsafeBufferPointer { d in
            resolved.withUnsafeBufferPointer { r in
                aether_port_lifecycle_reconcile(storage.handle, d.baseAddress, d.count, r.baseAddress, r.count,
                    now.timeIntervalSinceReferenceDate)
            }
        }
    }
}
