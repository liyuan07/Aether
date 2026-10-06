// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import WhatPortCore

private struct PlanRow: Equatable { let index: Int; let depth: Int; let parent: Int? }
private func originalPlan(_ devices: [DeviceInput]) -> [PlanRow] {
    let ids = Set(devices.map(\.locationID))
    let indexed = Array(devices.enumerated())
    var emitted = Set<Int>(), result: [PlanRow] = []
    func visit(_ i: Int, _ device: DeviceInput) {
        guard emitted.insert(i).inserted else { return }
        let parent = OriginalTree.parentLocationID(device.locationID).flatMap { id in devices.firstIndex { $0.locationID == id } }
        result.append(.init(index: i, depth: OriginalTree.hubDepth(of: device, in: devices), parent: parent))
        for (j, child) in indexed where OriginalTree.parentLocationID(child.locationID) == device.locationID { visit(j, child) }
    }
    for (i, device) in indexed {
        if let parent = OriginalTree.parentLocationID(device.locationID), ids.contains(parent) { continue }
        visit(i, device)
    }
    return result
}
private func rustPlan(_ devices: [DeviceInput]) -> [PlanRow] {
    DeviceTree.plan(devices).map { .init(index: $0.index, depth: $0.depth, parent: $0.parent_index >= 0 && $0.parent_index < devices.count ? $0.parent_index : nil) }
}
private func fixture(_ count: Int, seed: inout UInt64) -> [DeviceInput] {
    func next() -> UInt64 { seed = seed &* 6364136223846793005 &+ 1; return seed >> 32 }
    let special = [Int.min, -1, 0, Int.max, Int(UInt32.max) + 1, 0x08201000]
    return (0..<count).map { i in
        var id = Int(next() % 4) << 24
        let depth = Int(next() % 6) + 1
        for hop in 0..<depth { id |= Int(next() % 3 + 1) << (20 - hop * 4) }
        if next() % 8 == 0 { id = special[Int(next() % UInt64(special.count))] }
        return DeviceInput(portNumber: i % 4, productName: "synthetic-\(i)", locationID: id)
    }
}
@Test func rustTopologyMatchesOriginalAcrossMissingDuplicateAndMalformedLocations() {
    var seed: UInt64 = 987
    for count in 0..<120 {
        let devices = fixture(count, seed: &seed)
        #expect(rustPlan(devices) == originalPlan(devices))
        for device in devices {
            #expect(DeviceTree.parentLocationID(device.locationID) == OriginalTree.parentLocationID(device.locationID))
            #expect(DeviceTree.hubDepth(of: device, in: devices) == OriginalTree.hubDepth(of: device, in: devices))
            #expect(DeviceTree.viaName(of: device, in: devices) == OriginalTree.viaName(of: device, in: devices))
        }
    }
    // Duplicate hubs each render once; their descendants belong to the first DFS visit.
    let devices = [0x08200000,0x08200000,0x08210000,0x08210000,0x08211000].enumerated().map {
        DeviceInput(portNumber: 1, productName: "synthetic-\($0.offset)", locationID: $0.element)
    }
    #expect(rustPlan(devices) == originalPlan(devices))
}
@Test(.enabled(if: ProcessInfo.processInfo.environment["AETHER_RUN_CORE_BENCHMARKS"] == "1"))
func rustTopologyBatchBenchmark() {
    var seed: UInt64 = 42
    let devices = fixture(3000, seed: &seed)
    let expected = originalPlan(devices)
    var native: [Double] = [], rust: [Double] = []
    for _ in 0..<7 {
        var start = DispatchTime.now().uptimeNanoseconds
        let old = originalPlan(devices)
        native.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        start = DispatchTime.now().uptimeNanoseconds
        let new = rustPlan(devices)
        rust.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        #expect(old == expected && new == expected)
    }
    print("synthetic USB topology 3000 records median ms Swift=\(native.sorted()[3]) Rust=\(rust.sorted()[3])")
}

private enum OriginalTree {
    // Number of hub-path nibbles a locationID can carry. Bounds the walk in
    // hubDepth(of:in:) so malformed input cannot loop.
    private static let maxPathNibbles = 6

    // USB locationID encodes the topology path: the top byte is the
    // bus/controller, and each following nibble is a hub port hop.
    // Stripping the lowest-order non-zero nibble yields the parent's
    // locationID. Returns nil when the device is directly attached
    // (exactly one non-zero path nibble) or the locationID is malformed.
    static func parentLocationID(_ locationID: Int) -> Int? {
        guard locationID > 0, locationID <= Int(UInt32.max) else { return nil }

        let hubPath = locationID & 0x00FF_FFFF
        guard hubPath != 0 else { return nil }

        // A valid path fills nibbles contiguously from the highest position
        // down. An internal zero nibble (e.g. 0x08201000, path 2-0-1) is not
        // a topology the encoding can produce; stripping the lowest nibble of
        // one would fabricate a parent that may collide with a real, wrong
        // hub. Treat it as malformed instead.
        var seenZero = false
        for shift in stride(from: (maxPathNibbles - 1) * 4, through: 0, by: -4) {
            let nibble = (hubPath >> shift) & 0xF
            if nibble == 0 {
                seenZero = true
            } else if seenZero {
                return nil
            }
        }

        for shift in stride(from: 0, to: maxPathNibbles * 4, by: 4) {
            guard (hubPath >> shift) & 0xF != 0 else { continue }
            let cleared = locationID & ~(0xF << shift)
            // Clearing the only non-zero nibble leaves an empty path: the
            // device was directly attached, so there is no parent.
            return (cleared & 0x00FF_FFFF) == 0 ? nil : cleared
        }
        return nil
    }

    // Number of resolvable ancestor hops for `device` within `all`
    // (0 = directly attached). Walks parentLocationID repeatedly and stops
    // as soon as no device in `all` matches, so an unplugged-mid-poll or
    // filtered-out ancestor cannot loop or overcount. Bounded by the 6
    // path nibbles a locationID can carry.
    static func hubDepth(of device: DeviceInput, in all: [DeviceInput]) -> Int {
        let byLocationID = firstByLocationID(all)

        var depth = 0
        var current = device.locationID
        for _ in 0..<maxPathNibbles {
            guard let parentID = parentLocationID(current), byLocationID[parentID] != nil else {
                break
            }
            depth += 1
            current = parentID
        }
        return depth
    }

    // Product name of the device's immediate parent (the enclosing hub or
    // dock), if that parent is present in `all`. Nil for directly attached
    // devices, or when the parent's locationID is not in the list; the walk
    // never skips past a missing parent to a grandparent.
    static func viaName(of device: DeviceInput, in all: [DeviceInput]) -> String? {
        guard let parentID = parentLocationID(device.locationID) else { return nil }
        return firstByLocationID(all)[parentID]?.productName
    }

    // Duplicate locationIDs in `all` are resolved deterministically: the
    // first occurrence wins.
    private static func firstByLocationID(_ devices: [DeviceInput]) -> [Int: DeviceInput] {
        Dictionary(devices.map { ($0.locationID, $0) }, uniquingKeysWith: { first, _ in first })
    }
}
