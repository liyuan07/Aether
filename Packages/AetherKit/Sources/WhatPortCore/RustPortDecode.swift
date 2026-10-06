// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import CAetherCore

enum RustPortDecode {
    static func build(
        portID: Int,
        phy: PhyInput?,
        tb: ThunderboltInput?,
        power: PowerInput?,
        ccActive: Bool
    ) -> PortState {
        let lane0 = parseLane(transport: phy?.lane0Transport, powerLevel: phy?.lane0PowerLevel, client: phy?.lane0Client)
        let lane1 = parseLane(transport: phy?.lane1Transport, powerLevel: phy?.lane1PowerLevel, client: phy?.lane1Client)
        let usb2Active = phy.map { !$0.usb2Transport.isEmpty } ?? false

        let decoded = aether_port_decode(tb == nil ? 0 : 1,Int64(tb?.currentLinkWidth ?? 0),Int64(tb?.currentLinkSpeed ?? 0),
            power == nil ? 0 : 1,Int64(power?.watts ?? 0),Int64(power?.accumulatorCount ?? 0),Int64(power?.accumulatedPowerMJ ?? 0))
        var tbLink: ThunderboltLinkState?
        if decoded.link != 0 {
            let gen: TBGeneration = decoded.generation == 5 ? .tb5 : decoded.generation == 3 ? .tb3 : .tb4
            tbLink = ThunderboltLinkState(
                generation: gen,
                perLaneGbps: Int(decoded.gbps),
                txLanes: Int(decoded.tx),
                rxLanes: Int(decoded.rx)
            )
        }

        var portPower: PortPower?
        if decoded.power != 0, let pwr = power {
            portPower = PortPower(
                watts: decoded.watts,
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
        if decoded.energy != 0, let pwr = power {
            state.energy = PortEnergy(
                millijoules: pwr.accumulatedPowerMJ,
                sampleCount: pwr.accumulatorCount
            )
        }
        state.dpLinkRate = phy?.dpLinkRate ?? ""
        state.dpTunnelLinkRate = phy?.dpTunnel ?? ""
        return state
    }

    private static func parseLane(transport: String?, powerLevel: String?, client: String?) -> LaneState {
        var transport = (transport ?? "").lowercased()
        var power = (powerLevel ?? "").lowercased()
        let decoded = transport.withUTF8 { t in power.withUTF8 { p in
            aether_port_lane(t.baseAddress,t.count,p.baseAddress,p.count)
        } }
        let kind: LaneTransport = decoded.transport == 1 ? .thunderbolt : decoded.transport == 2 ? .displayPort : decoded.transport == 3 ? .usb : .idle
        return LaneState(transport:kind,powerLevel:decoded.on != 0 ? .on : .off,client:(client ?? "").isEmpty ? nil : client)
    }
}
