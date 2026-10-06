// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import WhatPortCore

@Test func rustPowerApplicationMatchesOriginalAcrossFiveThousandSnapshots() {
    var seed: UInt64 = 791
    func next() -> UInt64 { seed = seed &* 6364136223846793005 &+ 1; return seed >> 32 }
    let keys = ["AAA-BB", "aaabb", "É", "E\u{301}", "", "synthetic"]
    for _ in 0..<5000 {
        var old: [PortState] = (0..<Int(next() % 10)).map { _ in
            var port = PortState(id: Int(next() % 5) - 1, uuid: next() % 4 == 0 ? nil : keys[Int(next() % 6)],
                portType: next() % 2 == 0 ? .usbC : .magSafe, ccConnected: next() % 2 == 0)
            if next() % 3 == 0 {
                port.power = .init(watts: 5, current: 100, voltage: 200, configuredVoltage: 300,
                    configuredCurrent: 400, vconnCurrent: 500, vconnPower: 600, vconnMaxCurrent: 700,
                    direction: next() % 2 == 0 ? .incoming : .outgoing, contractIsEstimated: next() % 2 == 0)
            }
            return port
        }
        var rust = old
        let nodes: [ChargerInput] = (0..<Int(next() % 8)).map { _ in .init(portType: next() % 2 == 0 ? "USB-C" : "MagSafe 3",
            portNumber: Int(next() % 5) - 1, maxWatts: next() % 3 == 0 ? 0 : 100000, voltage: Int(next() % 20000),
            maxCurrent: Int(next() % 5000), hasWinningContract: next() % 2 == 0) }
        let t: ChargingPowerInput? = next() % 3 == 0 ? nil : .init(systemPowerIn: Int(next() % 100000),
            systemVoltageIn: Int(next() % 20000), systemCurrentIn: Int(next() % 5000))
        OriginalPower.applyChargerPower(to: &old, chargerData: nodes, chargingPower: t)
        RustPortPower.charger(nodes, telemetry: t, to: &rust)
        #expect(old.map(\.power) == rust.map(\.power))
        let channels: [SMCPortPowerInput] = (0..<Int(next() % 8)).map { _ in .init(present: next() % 2 == 0,
            volts: Double(Int(next() % 10000) - 1000) / 1000, amps: Double(Int(next() % 10000) - 1000) / 1000,
            uuid: keys[Int(next() % 6)]) }
        OriginalPower.applySMCPower(to: &old, smcPortPower: channels)
        RustPortPower.output(channels, to: &rust)
        #expect(old.map(\.power) == rust.map(\.power))
        let id = Int(next() % 5) - 1
        let c = SMCPortContractInput(channel: 1, uuid: "synthetic", powerMW: 10000, voltageMV: 5000, currentMA: 2000)
        OriginalPower.contract(to: &old, resolved: (id,c), chargingPower: t)
        RustPortPower.contract(c, portID: id, telemetry: t, to: &rust)
        #expect(old.map(\.power) == rust.map(\.power))
    }
}
@Test func rustTelemetryIntegerExtremesRemainExact() {
    var ports = [PortState(id: 1, portType: .usbC, ccConnected: true)]
    let t = ChargingPowerInput(systemPowerIn: Int.max, systemVoltageIn: Int.max, systemCurrentIn: Int.min)
    RustPortPower.charger([.init(portType: "USB-C", portNumber: 1, maxWatts: 1, voltage: Int.min, maxCurrent: Int.max)], telemetry: t, to: &ports)
    #expect(ports[0].power?.current == Int.min)
    #expect(ports[0].power?.voltage == Int.max)
    #expect(ports[0].power?.configuredVoltage == Int.min)
    #expect(ports[0].power?.configuredCurrent == Int.max)
}

@Test func rustOutputRoundingAndNonpositiveChannelsMatchOriginal() {
    for volts in [-5.0005, -0.0005, 0, 0.0005, 5.0005, Double.nan] {
        for amps in [-2.0005, -0.0005, 0, 0.0005, 2.0005] {
            var old = [PortState(id: 1, uuid: "AA-BB", portType: .usbC, ccConnected: true)]
            var rust = old
            let channels = [SMCPortPowerInput(present: false, volts: volts, amps: amps, uuid: "aabb")]
            OriginalPower.applySMCPower(to: &old, smcPortPower: channels)
            RustPortPower.output(channels, to: &rust)
            #expect(old.map(\.power) == rust.map(\.power))
        }
    }
}

private enum OriginalPower {
    static func applyChargerPower(
        to results: inout [PortState],
        chargerData: [ChargerInput],
        chargingPower: ChargingPowerInput?
    ) {
        // maxWatts > 0 is what makes this a contract rather than a bare node.
        // ChargerReader reports nodes carrying no PDO too, so that the SMC
        // fallback below can tell "macOS published nothing here" apart from
        // "macOS published a node that has not settled yet"; those bare entries
        // must never reach the attribution here.
        let usbcChargers = Dictionary(
            chargerData
                .filter { $0.portType == "USB-C" && $0.portNumber > 0 && $0.maxWatts > 0 }
                .map { ($0.portNumber, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        guard !usbcChargers.isEmpty else { return }

        for i in results.indices {
            guard results[i].power == nil, results[i].ccConnected else { continue }
            guard let charger = usbcChargers[results[i].id] else { continue }

            results[i].power = PortPower(
                watts: Double(chargingPower?.systemPowerIn ?? 0) / 1000.0,
                current: chargingPower?.systemCurrentIn ?? 0,
                voltage: chargingPower?.systemVoltageIn ?? charger.voltage,
                configuredVoltage: charger.voltage,
                configuredCurrent: charger.maxCurrent,
                vconnCurrent: 0,
                vconnPower: 0,
                vconnMaxCurrent: 0,
                direction: .incoming,
                // A node without a winning contract is the highest-PDO
                // fallback (see buildNonUSBCPorts' comment): a capability the
                // charger offers, not the agreement the two of them reached.
                contractIsEstimated: !charger.hasWinningContract
            )
        }
    }
    static func applySMCPower(to results: inout [PortState], smcPortPower: [SMCPortPowerInput]) {
        guard !smcPortPower.isEmpty else { return }

        // SMC UUIDs arrive already normalised (lowercase, no dashes).
        let byUUID = Dictionary(
            smcPortPower.map { ($0.uuid, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        for i in results.indices {
            guard let uuid = results[i].uuid else { continue }
            // Keep incoming (charger) readings: the SMC only measures power OUT.
            if let existing = results[i].power, existing.direction == .incoming { continue }
            guard let channel = byUUID[uuid.replacingOccurrences(of: "-", with: "").lowercased()] else { continue }
            // Only surface a reading when the Mac is actually sourcing power.
            // A channel at 0 W means nothing is drawing; leave the existing
            // reading (or nil) so the UI shows the real state, not a stale 0 W.
            guard channel.watts > 0 else { continue }

            // Carry the PD contract over from the PowerOutDetails reading when we
            // have one; the SMC doesn't report it and it isn't frozen-sensitive.
            let existing = results[i].power
            results[i].power = PortPower(
                watts: channel.watts,
                current: Int((channel.amps * 1000).rounded()),
                voltage: Int((channel.volts * 1000).rounded()),
                configuredVoltage: existing?.configuredVoltage ?? 0,
                configuredCurrent: existing?.configuredCurrent ?? 0,
                vconnCurrent: existing?.vconnCurrent ?? 0,
                vconnPower: existing?.vconnPower ?? 0,
                vconnMaxCurrent: existing?.vconnMaxCurrent ?? 0,
                direction: .outgoing,
                contractIsEstimated: existing?.contractIsEstimated ?? false
            )
        }
    }
    static func contract(to results: inout [PortState], resolved: (portID: Int, contract: SMCPortContractInput), chargingPower: ChargingPowerInput?) {
        guard let index = results.firstIndex(where: { $0.id == resolved.portID }) else { return }

        results[index].power = PortPower(
            watts: Double(chargingPower?.systemPowerIn ?? 0) / 1000.0,
            current: chargingPower?.systemCurrentIn ?? 0,
            voltage: chargingPower?.systemVoltageIn ?? resolved.contract.voltageMV,
            configuredVoltage: resolved.contract.voltageMV,
            configuredCurrent: resolved.contract.currentMA,
            vconnCurrent: 0,
            vconnPower: 0,
            vconnMaxCurrent: 0,
            direction: .incoming,
            // This whole path only ever fires where macOS published no
            // USB-C power-source node of its own; the contract is always
            // synthesized from the SMC, never macOS-confirmed.
            contractIsEstimated: true
        )
    }
}
