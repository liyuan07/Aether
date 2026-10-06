// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import Testing
import CAetherCore
@testable import WhatPortCore

private func nativeTB(_ rows: [ThunderboltInput]) -> [Int] {
    var best: [Int: Int] = [:]
    for (i,row) in rows.enumerated() where row.socketID > 0 {
        if let existing = best[row.socketID] {
            if row.currentLinkWidth > rows[existing].currentLinkWidth { best[row.socketID] = i }
        } else { best[row.socketID] = i }
    }
    return best.keys.sorted().map { best[$0]! }
}
private func nativePhy(_ rows: [PhyInput]) -> [Int] {
    guard rows.contains(where: { $0.portNumber > 0 }) else { return Array(rows.indices) }
    var best: [Int: Int] = [:]
    for (i,row) in rows.enumerated() {
        let key = row.portNumber > 0 ? row.portNumber : row.phyID
        if let existing = best[key] {
            let active = !row.lane0Transport.isEmpty || !row.lane1Transport.isEmpty
            let previous = !rows[existing].lane0Transport.isEmpty || !rows[existing].lane1Transport.isEmpty
            if active && !previous { best[key] = i }
        } else { best[key] = i }
    }
    return best.keys.sorted().map { best[$0]! }
}
@Test func rustRepresentativesMatchOriginalWithDuplicatesAndUnavailableMappings() {
    var seed: UInt64 = 427
    func next() -> UInt64 { seed = seed &* 6364136223846793005 &+ 1; return seed >> 32 }
    for _ in 0..<1000 {
        let rows: [ThunderboltInput] = (0..<Int(next() % 80)).map { _ in
            .init(socketID: Int(next() % 10) - 2, currentLinkWidth: Int(next() % 6) - 1)
        }
        let absent = next() % 4 == 0
        let phy: [PhyInput] = (0..<Int(next() % 80)).map { _ in
            .init(phyID: Int(next() % 10) - 2, portNumber: absent ? 0 : Int(next() % 10) - 2,
                lane0Transport: next() % 3 == 0 ? "USB" : "", lane1Transport: next() % 3 == 0 ? "CIO" : "")
        }
        #expect(RustPortPolicy.tbIndices(rows) == nativeTB(rows))
        #expect(RustPortPolicy.phyIndices(phy) == nativePhy(phy))
    }
    let extremes = [Int.min, 0, Int.max].map { ThunderboltInput(socketID: $0, currentLinkWidth: $0) }
    #expect(RustPortPolicy.tbIndices(extremes) == nativeTB(extremes))
}
@Test func rustTierConfirmationMatchesOriginalAcrossTwentyThousandSnapshots() {
    var confirmed: PortDataTier = .unknown, pending: PortDataTier?
    var core = AetherPortTier(confirmed: 3, pending: 4)
    let tiers: [PortDataTier] = [.unknown,.full,.thunderboltOnly,.none]
    var seed: UInt64 = 77
    for _ in 0..<20000 {
        seed = seed &* 6364136223846793005 &+ 1
        let resolved = tiers[Int((seed >> 32) % 4)]
        if resolved.detailRank <= confirmed.detailRank { pending = nil; confirmed = resolved }
        else if pending == resolved { pending = nil; confirmed = resolved }
        else { pending = resolved }
        core = aether_port_tier_step(core, UInt8(resolved.detailRank))
        #expect(RustPortPolicy.tier(core.confirmed) == confirmed)
        #expect(core.pending == pending.map { UInt8($0.detailRank) } ?? 4)
    }
}
