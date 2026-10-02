import Foundation
import WhatPortCore

struct PortPowerPoint: Identifiable {
    let id = UUID()
    let timestamp: Date
    let watts: Double
    let segment: Int
}

/// Timestamp windows rather than sample counts: notifications may burst.
struct PortHistory {
    private(set) var points: [Int: [PortPowerPoint]] = [:]
    private var segments: [Int: Int] = [:]
    private var directions: [Int: PowerDirection] = [:]
    private var lastReading: [Int: Date] = [:]

    mutating func breakSession() { lastReading.removeAll() }

    mutating func append(ports: [PortState], at now: Date) {
        prune(at: now)
        let readable = Set(ports.filter { $0.power != nil }.map(\.id))
        for id in Array(lastReading.keys) where !readable.contains(id) { lastReading[id] = nil }
        for port in ports {
            guard let power = port.power, power.watts.isFinite, power.watts >= 0 else {
                lastReading[port.id] = nil
                continue
            }
            if let last = lastReading[port.id], now <= last { continue }
            let continuous = lastReading[port.id].map { now.timeIntervalSince($0) <= 2.5 && directions[port.id] == power.direction } ?? false
            if !continuous { segments[port.id, default: 0] += 1 }
            // Keep at most one point per 100ms even under notification bursts.
            if let last = lastReading[port.id], now.timeIntervalSince(last) < 0.1 { continue }
            points[port.id, default: []].append(PortPowerPoint(timestamp: now, watts: power.watts, segment: segments[port.id, default: 0]))
            lastReading[port.id] = now
            directions[port.id] = power.direction
        }
    }

    mutating func prune(at now: Date) {
        for id in Array(points.keys) {
            points[id]?.removeAll { now.timeIntervalSince($0.timestamp) > 60 }
            if points[id]?.isEmpty == true { points[id] = nil }
        }
    }
}
