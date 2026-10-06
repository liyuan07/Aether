// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CAetherCore
import WhatPortCore

struct PortPowerPoint: Identifiable {
    let id = UUID()
    let timestamp: Date
    let watts: Double
    let segment: Int
    var coreToken: UInt64 = 0
}

/// Rust owns sampling/segmentation/history; Swift keeps incremental chart projections.
struct PortHistory {
    private final class Storage {
        let handle: UnsafeMutableRawPointer?
        init() { handle = aether_port_history_create() }
        init(copying source: Storage) { handle = aether_port_history_clone(source.handle) }
        deinit { aether_port_history_destroy(handle) }
    }
    private var storage = Storage()
    private(set) var points: [Int: [PortPowerPoint]] = [:]
    private mutating func makeUnique() {
        if !isKnownUniquelyReferenced(&storage) { storage = Storage(copying: storage) }
    }
    mutating func breakSession() { makeUnique(); aether_port_history_break(storage.handle) }
    mutating func append(ports: [PortState], at now: Date) {
        makeUnique()
        let readings = ports.map { port in
            AetherPortReading(port_id: Int64(port.id), watts: port.power?.watts ?? 0,
                has_power: port.power == nil ? 0 : 1, direction: port.power?.direction == .incoming ? 0 : 1)
        }
        readings.withUnsafeBufferPointer { rows in
            aether_port_history_append(storage.handle, rows.baseAddress, rows.count, now.timeIntervalSinceReferenceDate)
        }
        applyEvents()
    }
    mutating func prune(at now: Date) {
        makeUnique()
        aether_port_history_prune(storage.handle, now.timeIntervalSinceReferenceDate)
        applyEvents()
    }
    private mutating func applyEvents() {
        let count = aether_port_history_events(storage.handle, nil, 0)
        if count == 0 { return }
        var events = [AetherPortHistoryEvent](repeating: .init(), count: count)
        events.withUnsafeMutableBufferPointer { rows in
            _ = aether_port_history_events(storage.handle, rows.baseAddress, rows.count)
        }
        // Batch expired-token removal once per affected port, preserving IDs of retained points.
        var removed: [Int: Set<UInt64>] = [:]
        for event in events where event.removed != 0 { removed[Int(event.port_id), default: []].insert(event.token) }
        for (id, tokens) in removed {
            points[id]?.removeAll { tokens.contains($0.coreToken) }
            if points[id]?.isEmpty == true { points[id] = nil }
        }
        for event in events where event.removed == 0 {
            var point = PortPowerPoint(timestamp: Date(timeIntervalSinceReferenceDate: event.timestamp),
                watts: event.watts, segment: Int(event.segment))
            point.coreToken = event.token
            points[Int(event.port_id), default: []].append(point)
        }
    }
}
