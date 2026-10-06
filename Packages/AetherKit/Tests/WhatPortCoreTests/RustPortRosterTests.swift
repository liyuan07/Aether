// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import Testing
@testable import WhatPortCore

private struct RosterRow: Equatable {
    let id: Int, hpm: Int?, phy: Int?, tb: Int?, power: Int?
    let active: Bool
}
private func originalPlan(hpm: [HPMPortInput], phy: [PhyInput], tb: [ThunderboltInput], power: [PowerInput], cc: [CCInput])
    -> (rows: [RosterRow], tier: PortDataTier, tbIndices: [Int]) {
    var bestTB: [Int:Int] = [:]
    for (i,t) in tb.enumerated() where t.socketID > 0 {
        if let old = bestTB[t.socketID] {
            if t.currentLinkWidth > tb[old].currentLinkWidth { bestTB[t.socketID] = i }
        } else { bestTB[t.socketID] = i }
    }
    let tbIndices = bestTB.keys.sorted().map { bestTB[$0]! }
    var phyIndices = Array(phy.indices)
    if phy.contains(where: { $0.portNumber > 0 }) {
        var best: [Int:Int] = [:]
        for (i,p) in phy.enumerated() {
            let key = p.portNumber > 0 ? p.portNumber : p.phyID
            if let old = best[key] {
                if (!p.lane0Transport.isEmpty || !p.lane1Transport.isEmpty)
                    && phy[old].lane0Transport.isEmpty && phy[old].lane1Transport.isEmpty { best[key] = i }
            } else { best[key] = i }
        }
        phyIndices = best.keys.sorted().map { best[$0]! }
    }
    let direct = phyIndices.contains { phy[$0].portNumber > 0 }
    func selectedPhy(_ id: Int, _ position: Int) -> Int? {
        if direct { return phyIndices.first { phy[$0].portNumber > 0 && phy[$0].portNumber == id } }
        return position < phyIndices.count ? phyIndices[position] : nil
    }
    func row(_ id: Int, _ h: Int?, _ p: Int?, _ t: Int?) -> RosterRow {
        .init(id: id, hpm: h, phy: p, tb: t, power: power.firstIndex { $0.portIndex == id },
            active: cc.first { $0.portType == "USB-C" && $0.portNumber == id }?.active ?? false)
    }
    let hpmIndices = hpm.indices.filter { !hpm[$0].isMagSafe }.sorted { hpm[$0].portNumber < hpm[$1].portNumber }
    if !hpmIndices.isEmpty {
        return (hpmIndices.enumerated().map { position,i in
            row(hpm[i].portNumber,i,selectedPhy(hpm[i].portNumber,position),bestTB[hpm[i].portNumber])
        },.full,tbIndices)
    }
    if !tbIndices.isEmpty {
        return (tbIndices.enumerated().map { position,i in row(tb[i].socketID,nil,selectedPhy(tb[i].socketID,position),i) },.thunderboltOnly,tbIndices)
    }
    return (phyIndices.map { i in row(phy[i].portNumber > 0 ? phy[i].portNumber : phy[i].phyID + 1,nil,i,nil) },
        phyIndices.isEmpty ? .none : .full,tbIndices)
}
@Test func rustRosterMatchesOriginalAcrossSixThousandSourceCombinations() {
    var seed: UInt64 = 417
    func next() -> UInt64 { seed = seed &* 6364136223846793005 &+ 1; return seed >> 32 }
    var tiers: Set<Int> = []
    for iteration in 0..<6000 {
        let hpm: [HPMPortInput] = (0..<Int(next() % 8)).map { _ in
            .init(uuid: "synthetic",portNumber: Int(next() % 8) - 2,portType: next() % 2 == 0 ? "USB-C" : "MagSafe 3")
        }
        let phy: [PhyInput] = (0..<Int(next() % 8)).map { _ in .init(phyID: Int(next() % 8) - 2,
            portNumber: iteration % 3 == 0 ? 0 : Int(next() % 8) - 2, lane0Transport: next() % 2 == 0 ? "USB" : "") }
        let tb: [ThunderboltInput] = (0..<Int(next() % 8)).map { _ in .init(socketID: Int(next() % 8) - 2,currentLinkWidth: Int(next() % 6) - 1) }
        let power: [PowerInput] = (0..<Int(next() % 8)).map { _ in .init(portIndex: Int(next() % 8) - 2) }
        let cc: [CCInput] = (0..<Int(next() % 8)).map { _ in .init(portNumber: Int(next() % 8) - 2,
            portType: next() % 3 == 0 ? "MagSafe 3" : "USB-C",active: next() % 2 == 0) }
        let expected = originalPlan(hpm:hpm,phy:phy,tb:tb,power:power,cc:cc)
        let result = RustPortRoster.plan(hpm:hpm,phy:phy,tb:tb,power:power,cc:cc)
        let rows = result.rows.map { r in RosterRow(id:Int(r.port_id),hpm:r.hpm < 0 ? nil : Int(r.hpm),
            phy:r.phy < 0 ? nil : Int(r.phy),tb:r.tb < 0 ? nil : Int(r.tb),power:r.power < 0 ? nil : Int(r.power),active:r.cc_active != 0) }
        #expect(rows == expected.rows)
        #expect(result.tier == expected.tier)
        #expect(result.tbIndices == expected.tbIndices)
        tiers.insert(result.tier.detailRank)
    }
    #expect(tiers == [0,1,2])
}
