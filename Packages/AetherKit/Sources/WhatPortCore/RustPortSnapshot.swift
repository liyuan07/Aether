// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CAetherCore

/// PortManager serializes all calls on its executor, like the other port cores.
final class RustPortSnapshot {
    private let core = aether_port_snapshot_create()
    deinit { aether_port_snapshot_destroy(core) }
    func apply(_ ports: [PortState], at timestamp: Date) -> AetherPortSnapshotSummary {
        let rows = ports.map { port in
            AetherPortSnapshotReading(id: Int64(port.id), watts: port.power?.watts ?? 0,
                active: port.isActive ? 1 : 0, has_power: port.power == nil ? 0 : 1,
                incoming: port.power?.direction == .incoming ? 1 : 0)
        }
        return rows.withUnsafeBufferPointer {
            aether_port_snapshot_apply(core, $0.baseAddress, $0.count, timestamp.timeIntervalSinceReferenceDate)
        }
    }
    func samples() -> [Int: [PowerSample]] {
        let count = aether_port_snapshot_samples(core, nil, 0)
        var rows = [AetherPortSnapshotSample](repeating: .init(), count: count)
        rows.withUnsafeMutableBufferPointer { _ = aether_port_snapshot_samples(core, $0.baseAddress, $0.count) }
        var result: [Int: [PowerSample]] = [:]
        for row in rows {
            result[Int(row.id), default: []].append(PowerSample(timestamp: Date(timeIntervalSinceReferenceDate: row.timestamp), watts: row.watts))
        }
        return result
    }
}
