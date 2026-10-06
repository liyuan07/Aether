// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import Testing
@testable import WhatPortCore

@Test func rustPortDecodeMatchesOriginalAcrossSixThousandSnapshots() {
    var seed: UInt64 = 194
    func next() -> UInt64 { seed = seed &* 6364136223846793005 &+ 1; return seed >> 32 }
    let values = [Int.min,-1,0,1,2,3,4,8,15,20000,Int.max]
    func value() -> Int { values[Int(next() % UInt64(values.count))] }
    let strings = ["","CIO","cio","DisplayPort","USB3","on","ON","off","É","E\u{301}","CIO\0USB3","on\0","ＵＳＢ３","synthetic"]
    func string() -> String { strings[Int(next() % UInt64(strings.count))] }
    for _ in 0..<6000 {
        let id = value(), active = next() % 2 == 0
        let phy: PhyInput? = next() % 4 == 0 ? nil : .init(phyID:0,lane0Transport:string(),lane0PowerLevel:string(),lane0Client:string(),lane1Transport:string(),lane1PowerLevel:string(),lane1Client:string(),usb2Transport:string(),dpLinkRate:string(),dpTunnel:string())
        let tb: ThunderboltInput? = next() % 4 == 0 ? nil : .init(socketID:1,currentLinkWidth:value(),currentLinkSpeed:value())
        let power: PowerInput? = next() % 4 == 0 ? nil : .init(portIndex:1,watts:value(),current:value(),adapterVoltage:value(),configuredVoltage:value(),configuredCurrent:value(),vconnCurrent:value(),vconnPower:value(),vconnMaxCurrent:value(),accumulatedPowerMJ:value(),accumulatorCount:value())
        let old = OriginalDecode.buildPortState(portID:id,phy:phy,tb:tb,power:power,ccActive:active)
        let rust = RustPortDecode.build(portID:id,phy:phy,tb:tb,power:power,ccActive:active)
        #expect(old.id == rust.id)
        #expect(old.lane0 == rust.lane0)
        #expect(old.lane1 == rust.lane1)
        #expect(old.usb2Active == rust.usb2Active)
        #expect(old.ccConnected == rust.ccConnected)
        #expect(old.thunderboltLink == rust.thunderboltLink)
        #expect(old.power == rust.power)
        #expect(old.energy == rust.energy)
        #expect(old.dpLinkRate == rust.dpLinkRate)
        #expect(old.dpTunnelLinkRate == rust.dpTunnelLinkRate)
    }
}

private enum OriginalDecode {
    static func buildPortState(
        portID: Int,
        phy: PhyInput?,
        tb: ThunderboltInput?,
        power: PowerInput?,
        ccActive: Bool
    ) -> PortState {
        let lane0 = parseLane(transport: phy?.lane0Transport, powerLevel: phy?.lane0PowerLevel, client: phy?.lane0Client)
        let lane1 = parseLane(transport: phy?.lane1Transport, powerLevel: phy?.lane1PowerLevel, client: phy?.lane1Client)
        let usb2Active = phy.map { !$0.usb2Transport.isEmpty } ?? false

        var tbLink: ThunderboltLinkState?
        if let tb, tb.currentLinkWidth > 0, tb.currentLinkSpeed > 0 {
            let gen = TBGeneration(speedCode: tb.currentLinkSpeed)
            let (tx, rx) = decodeLinkWidth(tb.currentLinkWidth)
            tbLink = ThunderboltLinkState(
                generation: gen,
                perLaneGbps: gen.perLaneGbps,
                txLanes: tx,
                rxLanes: rx
            )
        }

        var portPower: PortPower?
        if let pwr = power, pwr.watts > 0 {
            portPower = PortPower(
                watts: Double(pwr.watts) / 1000.0,
                current: pwr.current,
                voltage: pwr.adapterVoltage,
                configuredVoltage: pwr.configuredVoltage,
                configuredCurrent: pwr.configuredCurrent,
                vconnCurrent: pwr.vconnCurrent,
                vconnPower: pwr.vconnPower,
                vconnMaxCurrent: pwr.vconnMaxCurrent,
                direction: .outgoing,
                // Read straight from PowerOutDetails, macOS's own measurement.
                contractIsEstimated: false
            )
        }

        var state = PortState(
            id: portID,
            lane0: lane0,
            lane1: lane1,
            usb2Active: usb2Active,
            ccConnected: ccActive,
            thunderboltLink: tbLink,
            power: portPower
        )
        // Set independently of `portPower` above: the accumulator is the
        // session total, so it stays meaningful during a lull where the port
        // is attached but drawing nothing and `power` goes nil.
        // A negative accumulator is not a number we can show. The registry
        // value's true width is undocumented; if it is ever boxed as a signed
        // 32-bit int, a long high-power session would wrap past bit 31 and
        // sign-extend into a negative Int here. Nothing observed in the corpus
        // comes close (the largest is 216 million, and the 16-bit sample count
        // caps a session at 18.2 hours first), but showing no figure beats
        // showing a negative one.
        if let pwr = power, pwr.accumulatorCount > 0, pwr.accumulatedPowerMJ >= 0 {
            state.energy = PortEnergy(
                millijoules: pwr.accumulatedPowerMJ,
                sampleCount: pwr.accumulatorCount
            )
        }
        state.dpLinkRate = phy?.dpLinkRate ?? ""
        state.dpTunnelLinkRate = phy?.dpTunnel ?? ""
        return state
    }

    // Current Link Width is a bitmask, not a lane count.
    // From thunderbolt-fabric.md:
    //   0x1 = single lane (1 TX, 1 RX)
    //   0x2 = dual lane (2 TX, 2 RX)
    //   0x4 = asymmetric TX (3 TX, 1 RX) - TB5 only
    //   0x8 = asymmetric RX (1 TX, 3 RX) - TB5 only
    static func decodeLinkWidth(_ width: Int) -> (tx: Int, rx: Int) {
        switch width {
        case 0x1: return (1, 1)
        case 0x2: return (2, 2)
        case 0x4: return (3, 1)  // asymmetric TX
        case 0x8: return (1, 3)  // asymmetric RX
        default: return (1, 1)
        }
    }

    static func parseLane(transport: String?, powerLevel: String?, client: String?) -> LaneState {
        let t = transport ?? ""
        let laneTransport: LaneTransport
        switch t.lowercased() {
        case "cio": laneTransport = .thunderbolt
        case "displayport": laneTransport = .displayPort
        case "usb3": laneTransport = .usb
        default: laneTransport = .idle
        }

        let power: PowerLevel = (powerLevel ?? "").lowercased() == "on" ? .on : .off

        return LaneState(
            transport: laneTransport,
            powerLevel: power,
            client: (client ?? "").isEmpty ? nil : client
        )
    }
}
