// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import WhatPortCore
@testable import PortsFeature

private func reading(_ id: Int, _ watts: Double?, incoming: Bool) -> PortState {
    var port = PortState(id: id, portType: .usbC)
    if let watts {
        port.power = PortPower(watts: watts, current: 0, voltage: 0, configuredVoltage: 0, configuredCurrent: 0, vconnCurrent: 0)
        port.power?.direction = incoming ? .incoming : .outgoing
    }
    return port
}
private func equal(_ first: [Int: [PortPowerPoint]], _ second: [Int: [PortPowerPoint]]) -> Bool {
    guard Set(first.keys) == Set(second.keys) else { return false }
    return first.allSatisfy { id, rows in
        let other = second[id]!
        return rows.count == other.count && zip(rows, other).allSatisfy {
            $0.timestamp == $1.timestamp && $0.watts == $1.watts && $0.segment == $1.segment
        }
    }
}
@Test func rustHistoryMatchesOriginalBurstsDirectionsAndSessions() {
    var rust = PortHistory(), original = OriginalHistory()
    var seed: UInt64 = 123
    func next() -> UInt64 { seed = seed &* 6364136223846793005 &+ 1; return seed >> 32 }
    var now = 1000.0
    let steps = [0.0, 0.01, 0.099999, 0.1, 2.5, 2.500001, 60.0, 60.000001, -100.0]
    let powers: [Double?] = [nil, 0, -1, .nan, .infinity, 7.2]
    for _ in 0..<10000 {
        now += steps[Int(next() % UInt64(steps.count))]
        let date = Date(timeIntervalSinceReferenceDate: now)
        switch next() % 12 {
        case 0: rust.breakSession(); original.breakSession()
        case 1: rust.prune(at: date); original.prune(at: date)
        default:
            let ports = (0..<Int(next() % 7)).map { _ in
                reading(Int(next() % 5) - 2, powers[Int(next() % UInt64(powers.count))], incoming: next() % 2 == 0)
            }
            rust.append(ports: ports, at: date); original.append(ports: ports, at: date)
        }
        #expect(equal(rust.points, original.points))
    }
}
@Test func rustHistoryCopiesAndChartIdentityRemainStable() {
    var first = PortHistory()
    let port = reading(Int.max, 5, incoming: false)
    let date = Date(timeIntervalSinceReferenceDate: 100)
    first.append(ports: [port], at: date)
    let id = first.points[Int.max]!.first!.id
    var copy = first
    copy.breakSession(); copy.append(ports: [port], at: date.addingTimeInterval(0.01))
    #expect(first.points[Int.max]?.count == 1)
    #expect(copy.points[Int.max]?.count == 2)
    #expect(copy.points[Int.max]?.first?.id == id)
    copy.prune(at: date.addingTimeInterval(60.005))
    #expect(copy.points[Int.max]?.count == 1)
    #expect(first.points[Int.max]?.first?.id == id)
    first.append(ports: [port], at: date.addingTimeInterval(1))
    #expect(first.points[Int.max]?.first?.id == id)
}

// Independent migration baseline, kept out of production.
private struct OriginalHistory {
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
