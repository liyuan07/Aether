// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import WhatPortCore

private func same(_ a: (portID: Int, contract: SMCPortContractInput)?, _ b: (portID: Int, contract: SMCPortContractInput)?) -> Bool {
    guard let a, let b else { return a == nil && b == nil }
    return a.portID == b.portID && a.contract.channel == b.contract.channel && a.contract.uuid == b.contract.uuid
        && a.contract.powerMW == b.contract.powerMW && a.contract.voltageMV == b.contract.voltageMV
        && a.contract.currentMA == b.contract.currentMA && a.contract.label == b.contract.label
}
@Test func rustSMCAttributionMatchesOriginalAcrossJoinsDuplicatesAndGates() {
    var seed: UInt64 = 847
    func next() -> UInt64 { seed = seed &* 6364136223846793005 &+ 1; return seed >> 32 }
    let uuids = ["AAA-BB", "aaabb", "É", "E\u{301}", "", "synthetic\u{0000}key"]
    let labels = ["", "USB HOST", "synthetic usb host output", "USB-HOST", "ＵＳＢ HOST", "iİÉ"]
    let watts = [0.0, 0.5, 0.500001, -1, Double.nan, Double.infinity]
    var resolutions = 0
    for iteration in 0..<4000 {
        var ports: [PortState] = (0..<Int(next() % 9)).map { _ in
            let uuid = next() % 5 == 0 ? nil : uuids[Int(next() % UInt64(uuids.count))]
            var port = PortState(id: Int(next() % 4) - 1, uuid: uuid, portType: .usbC, ccConnected: next() % 2 == 0)
            if next() % 3 == 0 { port.portType = .magSafe }
            if next() % 4 == 0 {
                port.power = PortPower(watts: 10, current: 1, voltage: 1, configuredVoltage: 0, configuredCurrent: 0, vconnCurrent: 0,
                    direction: next() % 2 == 0 ? .incoming : .outgoing)
            }
            return port
        }
        var contracts: [SMCPortContractInput] = (0..<Int(next() % 7)).map { i in
            let uuid = uuids[Int(next() % UInt64(uuids.count))]
            return .init(channel: i, uuid: next() % 2 == 0 ? uuid : OriginalAttribution.normalisedUUID(uuid),
                powerMW: next() % 3 == 0 ? 100 : 10000, voltageMV: next() % 5 == 0 ? 4499 : 5000,
                currentMA: next() % 5 == 0 ? 0 : 2000, label: labels[Int(next() % UInt64(labels.count))])
        }
        var nodes: [ChargerInput] = (0..<Int(next() % 5)).map { _ in .init(portType: next() % 2 == 0 ? "USB-C" : "MagSafe 3",
            portNumber: Int(next() % 4) - 1, hasWinningContract: next() % 3 == 0) }
        var outputs: [SMCPortPowerInput] = (0..<Int(next() % 5)).map { _ in .init(present: next() % 2 == 0,
            volts: watts[Int(next() % UInt64(watts.count))], amps: 1, uuid: uuids[Int(next() % UInt64(uuids.count))]) }
        var enabled = next() % 2 == 0, external = next() % 2 == 0
        if iteration % 7 == 0 {
            ports = [.init(id: 1, uuid: "AAA-BB", portType: .usbC, ccConnected: true)]
            contracts = [.init(channel: 4, uuid: "aaabb", powerMW: 10000, voltageMV: 5000, currentMA: 2000)]
            nodes = []; outputs = []; enabled = true; external = true
        }
        let expected = OriginalAttribution.resolve(contracts: contracts, ports: ports, chargerNodes: nodes,
            externalConnected: external, powerOut: outputs, enabled: enabled)
        let actual = SMCContractAttribution.resolve(contracts: contracts, ports: ports, chargerNodes: nodes,
            externalConnected: external, powerOut: outputs, enabled: enabled)
        #expect(same(actual, expected))
        if actual != nil { resolutions += 1 }
        #expect(SMCContractAttribution.hasUSBCContractCandidate(contracts: contracts, ports: ports, powerOut: outputs)
            == OriginalAttribution.hasUSBCContractCandidate(contracts: contracts, ports: ports, powerOut: outputs))
        #expect(SMCContractAttribution.macOSDescribesCharging(chargerNodes: nodes) == OriginalAttribution.macOSDescribesCharging(chargerNodes: nodes))
    }
    #expect(resolutions >= 500)
}
@Test func rustSMCNumericBoundariesMatchOriginal() {
    let integers = [Int.min, -1, 0, 1, 4499, 4500, 5000, 10000, Int.max]
    let outs: [SMCPortPowerInput?] = [nil] + [-1,0,0.5,0.500001,Double.nan,Double.infinity].map {
        SMCPortPowerInput(present: false, volts: $0, amps: 1, uuid: "synthetic")
    }
    for power in integers { for voltage in integers { for current in integers {
        let c = SMCPortContractInput(channel: 1, uuid: "synthetic", powerMW: power, voltageMV: voltage, currentMA: current)
        #expect(SMCContractAttribution.isInternallyConsistent(c) == OriginalAttribution.isInternallyConsistent(c))
        for out in outs {
            #expect(SMCContractAttribution.isPlausibleIncomingContract(c, powerOut: out) == OriginalAttribution.isPlausibleIncomingContract(c, powerOut: out))
            #expect(SMCContractAttribution.isSourcingPowerOut(out) == OriginalAttribution.isSourcingPowerOut(out))
        }
    } } }
}

// Independent original policy, used only with explicit isolated inputs.
private enum OriginalAttribution {

    // A single switch. Turning this off returns every affected port to the
    // no-data state it had before this existed:
    //
    //   defaults write app.whatport.whatport SMCContractDisabled -bool YES
    //
    // This is the one power path that can turn a fail-closed bug into a
    // fail-open one: everything else here either shows nothing or shows a
    // measurement, whereas this puts a negotiated figure against a port we
    // inferred. If a machine in the wild disagrees with it, the recovery is
    // flipping this, not unpicking the correlation, and a defaults key means
    // support can do that without shipping a build.
    //
    // Read-only, so it stays concurrency-safe. `resolve` takes the value as a
    // parameter defaulting to this rather than reading it directly: WhatCable's
    // version read a mutable global, and the test that flipped it off raced
    // every other test in its suite, which looked exactly like a logic bug.
    static var isEnabled: Bool {
        !UserDefaults.standard.bool(forKey: "SMCContractDisabled")
    }

    // The label the SMC uses for a channel that is SOURCING power to a
    // peripheral rather than receiving it. A contract on such a channel is the
    // Mac's own output and must never be shown as an incoming charge.
    private static let outgoingLabel = "usb host"

    // USB-C's lowest rail is 5 V, but the SMC does not always report it as
    // exactly 5000: six machines in the probe corpus report a real 5 V contract
    // as 4750 mV, which is inside USB-PD's 5% tolerance. A 5000 floor rejected
    // all six, so a Mac charging slowly from a weak source (a phone charger, a
    // bus-powered hub, a display's low-power port) showed no power at all.
    //
    // 4500 clears the tolerance band while staying far above anything a partial
    // read produces: the corpus holds nothing at all between 0 and 4750.
    private static let minimumContractVoltageMV = 4_500

    // How far DxMV x DxMI may stray from DxMP before the channel is treated as
    // half-read.
    //
    // Every one of the 463 contracts in the probe corpus agrees exactly, to
    // 0.000%, which says DxMP is the firmware's own product rather than a third
    // measurement. So this is not a rounding allowance and the check is not
    // three readings corroborating each other, as a first version of this
    // comment claimed. What it catches is one of the three keys failing to read
    // or coming back stale, which breaks the identity: three separate kernel
    // round trips are made per channel and nothing makes them a snapshot.
    //
    // The band is for that case, not for rounding. Kept small because nothing
    // real sits near it, and a mid-renegotiation tick where the keys are
    // sampled a syscall apart is meant to decline for one poll rather than
    // publish a figure assembled from two different contracts.
    private static let contractConsistencyTolerance = 0.02

    // Power out on the same channel, above which the channel is the Mac
    // sourcing to a peripheral rather than being fed.
    //
    // Small but not zero: an idle channel can report a few milliwatts of noise.
    private static let outgoingPowerFloorWatts = 0.5

    // Resolve this tick's SMC contracts to at most one port.
    //
    // - Parameters:
    //   - contracts: the SMC contract channels read this tick.
    //   - ports: every port built so far, USB-C and MagSafe, with any power
    //     already attributed by the readers that outrank this one.
    //   - chargerNodes: every IOPortFeaturePowerSource macOS published,
    //     including bare nodes carrying no PDO.
    //   - externalConnected: whether the Mac reports external power.
    // - Returns: the port id and the contract to show on it, or nil when any
    //   gate fails. Naming the wrong port is worse than naming none, so every
    //   gate declines rather than guessing.
    static func resolve(
        contracts: [SMCPortContractInput],
        ports: [PortState],
        chargerNodes: [ChargerInput],
        externalConnected: Bool,
        powerOut: [SMCPortPowerInput] = [],
        enabled: Bool = isEnabled
    ) -> (portID: Int, contract: SMCPortContractInput)? {
        guard enabled else { return nil }

        // GATE 1: nothing is charging, so there is no contract to describe.
        guard externalConnected else { return nil }

        // GATE 2: macOS has already answered somewhere, so stay quiet. This is
        // cross-port on purpose: without it, an M1 Pro charging on MagSafe with
        // a dock on USB-C would show the dock's contract as though the Mac were
        // charging from it. Three halves, and each covers a case the others
        // miss.
        //
        // A port already showing incoming power is the obvious one. A winning
        // USB-PD contract anywhere covers a port whose power has not been
        // attributed yet.
        //
        // The third exists because the first two leave a hole: `externalConnected`
        // is system-wide, and a MagSafe port only receives an incoming reading
        // while the battery is actively charging. Sit at 100% on MagSafe, or let
        // optimised charging pause at 80%, and neither of the first two fires,
        // so a USB-C peripheral's contract could become the sole candidate and
        // be presented as the Mac's charge.
        //
        // That case is caught by the incoming-power check itself, because the
        // non-USB-C ports are built and attributed BEFORE this runs: a MagSafe
        // port that is genuinely the one delivering already carries incoming
        // power by now, whatever the battery is doing.
        //
        // This deliberately no longer declines merely because a MagSafe port is
        // connected. It did, briefly, and that was too blunt in a common setup:
        // an M1 Pro charging through a USB-C dock with a MagSafe cable also
        // plugged into the wall left BOTH cards blank, silently disabling the
        // one path that machine has. A connected MagSafe that is not delivering
        // is just a cable.
        //
        // What makes that safe is the SMC's own behaviour: `DxMP` is only
        // populated for power coming IN. Across 449 corpus contract channels,
        // none was simultaneously sourcing power outward, so a channel carrying
        // a contract is a port being fed, not a peripheral being powered.
        let anyIncomingPower = ports.contains { $0.power?.direction == .incoming }
        guard !anyIncomingPower,
              !macOSDescribesCharging(chargerNodes: chargerNodes)
        else { return nil }

        // Ports macOS published a node for, bare or not. A bare node means
        // macOS is describing that port and simply has not settled on a
        // contract yet, which is mid-negotiation rather than this bug.
        let portsWithNode = Set(
            chargerNodes.filter { $0.portType == "USB-C" }.map(\.portNumber)
        )

        // The same channels' power-OUT readings, keyed by the join this file
        // already trusts, so a contract can be checked against its own channel.
        let powerOutByUUID = Dictionary(
            powerOut.map { ($0.uuid, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let candidates = contracts.compactMap { contract -> (portID: Int, contract: SMCPortContractInput)? in
            // GATES 3 and 4: a plausible charging contract, and not the Mac's
            // own output. See `isPlausibleIncomingContract`, which every caller
            // asking this question shares.
            guard isPlausibleIncomingContract(
                contract,
                powerOut: powerOutByUUID[contract.uuid]
            ) else { return nil }

            // GATE 5: the channel resolves to a port through the UUID join. No
            // guessing by channel index: the SMC D-index is not the physical
            // port number (verified on M5: D3 = USB-C@4, D4 = MagSafe@1).
            guard let port = ports.first(where: {
                guard let uuid = $0.uuid else { return false }
                return normalisedUUID(uuid) == contract.uuid
            }) else { return nil }

            // GATE 6: the port must be a connected USB-C port with nothing
            // already on it and no node of its own.
            guard port.portType == .usbC, port.ccConnected, port.power == nil else { return nil }
            guard !portsWithNode.contains(port.id) else { return nil }

            return (port.id, contract)
        }

        // Exactly one, or stay silent. Two candidates means the join is
        // ambiguous, and that is the misattribution this whole path is written
        // to avoid.
        guard candidates.count == 1 else { return nil }
        return candidates.first
    }

    // True when macOS has already published a negotiated contract of its own,
    // anywhere on the machine.
    //
    // Split out so the IOKit layer can ask the same question BEFORE paying for
    // the SMC read, rather than reading data this layer is certain to discard.
    // One function, not two matching conditions: the first version of the read
    // gate restated this and immediately disagreed with it.
    //
    // Deliberately only the node-based half of gate 2. The connected-MagSafe
    // half needs live port state the reader does not have, and a read gate must
    // never skip a read the attribution might have used, so it stays the
    // narrower of the two. Reading occasionally more than strictly needed costs
    // a few kernel calls; reading less would cost the reading itself.
    static func macOSDescribesCharging(chargerNodes: [ChargerInput]) -> Bool {
        chargerNodes.contains { $0.hasWinningContract }
    }

    // True when an SMC contract channel resolves to a connected USB-C port.
    //
    // This is evidence that USB-C is the connector taking power IN, and it is
    // needed even when the gates above decline to put a figure on that port.
    // On M1 Pro / Max / Ultra there is no USB-C node to look at, so without
    // this the only reading of "no USB-C contract anywhere" is "USB-C is not
    // charging", and a MagSafe cable that happens to be plugged in would claim
    // the machine's whole power-in figure while USB-C actually carried it.
    //
    // Deliberately not gated on `isEnabled`: the rollback switch exists to stop
    // this path PUTTING A FIGURE on a card, not to make the rest of the app
    // forget what the SMC plainly says about which port is fed.
    // A channel that looks like a real charge coming in: positive power, a
    // voltage at or above the floor, three figures that describe one contract,
    // and no sign the channel is the Mac sourcing power outward.
    //
    // Shared so every caller asking "is this channel evidence of a port being
    // fed" applies the same rules.
    //
    // `powerOut` is the same channel's DxJV / DxJI reading, when the caller has
    // it. Direction is the one thing worth being sure of here, and a label is
    // thin evidence for it: only 1 of 463 corpus contracts carries the "usb
    // host" label, so an outgoing channel is far more likely to be unlabelled
    // than labelled. A measured outgoing draw is not thin evidence. Nothing in
    // the corpus has both (0 of 463 contract channels report any power out), so
    // this rejects nothing real and closes the case the label cannot.
    static func isPlausibleIncomingContract(
        _ contract: SMCPortContractInput,
        powerOut: SMCPortPowerInput? = nil
    ) -> Bool {
        guard contract.powerMW > 0, contract.voltageMV >= minimumContractVoltageMV else { return false }
        guard isInternallyConsistent(contract) else { return false }
        guard !contract.label.lowercased().contains(outgoingLabel) else { return false }
        guard !isSourcingPowerOut(powerOut) else { return false }
        return true
    }

    // Whether the channel is measurably feeding a peripheral.
    static func isSourcingPowerOut(_ powerOut: SMCPortPowerInput?) -> Bool {
        guard let powerOut else { return false }
        return powerOut.watts > outgoingPowerFloorWatts
    }

    // Whether DxMV x DxMI reproduces DxMP, which is what catches a channel
    // where one of the three keys failed to read or came back stale. See the
    // tolerance above for why this is not a rounding allowance.
    //
    // Self-guarding rather than relying on the caller's checks, so a direct
    // caller cannot divide by a zero wattage.
    static func isInternallyConsistent(_ contract: SMCPortContractInput) -> Bool {
        guard contract.powerMW > 0, contract.currentMA > 0 else { return false }
        let product = Double(contract.voltageMV) * Double(contract.currentMA) / 1000.0
        let stated = Double(contract.powerMW)
        return abs(product - stated) / stated <= contractConsistencyTolerance
    }

    static func hasUSBCContractCandidate(
        contracts: [SMCPortContractInput],
        ports: [PortState],
        powerOut: [SMCPortPowerInput] = []
    ) -> Bool {
        let powerOutByUUID = Dictionary(
            powerOut.map { ($0.uuid, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return contracts.contains { contract in
            guard isPlausibleIncomingContract(
                contract,
                powerOut: powerOutByUUID[contract.uuid]
            ) else { return false }
            return ports.contains { port in
                guard let uuid = port.uuid else { return false }
                return normalisedUUID(uuid) == contract.uuid
                    && port.portType == .usbC
                    && port.ccConnected
            }
        }
    }

    // Normalise an HPM UUID to the SMC DxUI form: dashes stripped, lowercase
    // (e.g. "6230AF2D-EE59-..." -> "6230af2dee59...").
    static func normalisedUUID(_ uuid: String) -> String {
        uuid.replacingOccurrences(of: "-", with: "").lowercased()
    }
}
