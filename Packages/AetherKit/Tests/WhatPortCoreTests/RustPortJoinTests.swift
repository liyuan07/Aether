// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import Testing
@testable import WhatPortCore

private struct EntrySignature: Equatable { let offset: Int; let attach: Int }
private func offsets(_ data: [Int:PDReliabilityInput]) -> [Int:EntrySignature] { data.mapValues { EntrySignature(offset: $0.entryOffset, attach: $0.attachCount) } }
@Test func rustPortJoinsMatchOriginalAcrossSixThousandAmbiguousCombinations() {
    var seed: UInt64 = 145
    func next() -> UInt64 { seed = seed &* 6364136223846793005 &+ 1; return seed >> 32 }
    let keys = ["", "AAA-BB", "aaabb", "É", "E\u{301}", "synthetic", "--"]
    for iteration in 0..<6000 {
        var hpm: [HPMPortInput] = (0..<Int(next() % 7)).map { _ in
            .init(uuid: keys[Int(next() % UInt64(keys.count))],portNumber: Int(next() % 5) - 1,portType: next() % 3 == 0 ? "MagSafe 3" : "USB-C")
        }
        var channels: [SMCPortPowerInput] = (0..<Int(next() % 7)).map { _ in
            .init(present: false,volts: 0,amps: 0,uuid: keys[Int(next() % UInt64(keys.count))],channel: Int(next() % 6) - 1)
        }
        if iteration % 10 == 0 {
            hpm = [.init(uuid:"AAA-BB",portNumber:1,portType:"USB-C"),.init(uuid:"",portNumber:2,portType:"USB-C")]
            channels = [.init(present:false,volts:0,amps:0,uuid:"aaabb",channel:1),.init(present:false,volts:0,amps:0,uuid:"synthetic",channel:2)]
        }
        let expectedHPM = OriginalJoins.joinUnidentifiedPortByElimination(hpmPorts:hpm,smcChannels:channels)
        let recovered = PortManager.joinUnidentifiedPortByElimination(hpmPorts:hpm,smcChannels:channels)
        #expect(recovered.map(\.uuid) == expectedHPM.map(\.uuid))
        #expect(recovered.map(\.portNumber) == hpm.map(\.portNumber))
        #expect(recovered.map(\.portType) == hpm.map(\.portType))
        let ids = (0..<Int(next() % 7)).map { _ in Int(next() % 5) - 1 }
        let entries = (0..<Int(next() % 8)).map { index in PDReliabilityInput(entryOffset:Int(next() % 7) - 1,attachCount:index + 1) }
        let original = OriginalJoins.joinPDReliabilityOrdinally(entries,usbCPortIDs:ids)
        let ordinal = RustPortJoin.ordinal(entries,ids:ids)
        #expect(offsets(original) == offsets(ordinal))
        let ports = hpm.map { PortState(id:$0.portNumber,uuid:$0.uuid,portType:$0.isMagSafe ? .magSafe : .usbC) }
        let cross = OriginalJoins.crossCheckPDJoin(ordinal:original,usbCPortIDs:ids,smcChannels:channels,usbCPorts:ports)
        let disagreement = RustPortJoin.cross(ordinal:ordinal,ids:ids,channels:channels,ports:ports)
        #expect(cross.disagreement == disagreement)
        #expect(offsets(cross.result) == offsets(disagreement == nil ? ordinal : [:]))
    }
}

@Test func rustPortJoinReportsAllDisagreementsInOffsetOrder() {
    let entries = [PDReliabilityInput(entryOffset:0,attachCount:10), PDReliabilityInput(entryOffset:1,attachCount:20)]
    let ids = [1,2]
    let channels = [SMCPortPowerInput(present:false,volts:0,amps:0,uuid:"two",channel:1),
                    SMCPortPowerInput(present:false,volts:0,amps:0,uuid:"one",channel:2)]
    let ports = [PortState(id:1,uuid:"one",portType:.usbC), PortState(id:2,uuid:"two",portType:.usbC)]
    let disagreement = RustPortJoin.cross(ordinal:RustPortJoin.ordinal(entries,ids:ids),ids:ids,channels:channels,ports:ports)
    #expect(disagreement == "offset 0 D1: keyed=port 2 ordinal=port 1; offset 1 D2: keyed=port 1 ordinal=port 2")
}

private enum OriginalJoins {
    struct PDReliabilityCrossCheckResult {
        let result: [Int: PDReliabilityInput]
        let disagreement: String?
    }
    static func joinPDReliabilityOrdinally(
        _ pdReliabilityData: [PDReliabilityInput],
        usbCPortIDs: [Int]
    ) -> [Int: PDReliabilityInput] {
        guard !pdReliabilityData.isEmpty, !usbCPortIDs.isEmpty else { return [:] }

        let usbCCount = usbCPortIDs.count
        guard pdReliabilityData.count == usbCCount || pdReliabilityData.count == usbCCount + 1 else {
            return [:]
        }

        let byOffset = Dictionary(
            pdReliabilityData.map { ($0.entryOffset, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var result: [Int: PDReliabilityInput] = [:]
        for (index, portID) in usbCPortIDs.enumerated() {
            guard let entry = byOffset[index] else { continue }
            result[portID] = entry
        }
        return result
    }
    static func crossCheckPDJoin(
        ordinal: [Int: PDReliabilityInput],
        usbCPortIDs: [Int],
        smcChannels: [SMCPortPowerInput],
        usbCPorts: [PortState]
    ) -> PDReliabilityCrossCheckResult {
        guard !ordinal.isEmpty, !smcChannels.isEmpty else {
            return PDReliabilityCrossCheckResult(result: ordinal, disagreement: nil)
        }

        // Normalised HPM UUID -> port IDs, USB-C ports only, so a MagSafe
        // port's UUID (or a USB-C port outside the ordinal roster) can never
        // satisfy a match. Kept as an array per UUID so two ports sharing a
        // UUID reads as ambiguous rather than silently picking one.
        var portIDsByUUID: [String: [Int]] = [:]
        for port in usbCPorts where port.portType == .usbC {
            guard let uuid = port.uuid else { continue }
            portIDsByUUID[SMCContractAttribution.normalisedUUID(uuid), default: []].append(port.id)
        }

        // Grouped by D-channel index rather than first-wins uniqued: the real
        // reader (the D1...D4 loop) can never publish two channels at the
        // same index, but defensively, an index with more than one entry is
        // treated as unresolved for that offset, never resolved by picking
        // whichever happened to win the uniquing.
        let channelsByIndex = Dictionary(grouping: smcChannels, by: \.channel)
            .compactMapValues { channels in channels.count == 1 ? channels[0] : nil }

        var disagreements: [String] = []
        for (offset, ordinalPortID) in usbCPortIDs.enumerated() {
            // The ordinal join produced nothing for this offset (e.g. a
            // missing PD reliability entry): there is no attribution to
            // cross-check, so a keyed match here can never count as a
            // disagreement about it.
            guard ordinal[ordinalPortID] != nil else { continue }
            let channelIndex = offset + 1
            guard let channel = channelsByIndex[channelIndex] else { continue }   // unresolved: no channel, or a duplicate index
            guard let matches = portIDsByUUID[channel.uuid], matches.count == 1 else { continue }   // unresolved: no/ambiguous match
            let keyedPortID = matches[0]
            guard keyedPortID != ordinalPortID else { continue }   // agrees
            disagreements.append("offset \(offset) D\(channelIndex): keyed=port \(keyedPortID) ordinal=port \(ordinalPortID)")
        }

        guard disagreements.isEmpty else {
            return PDReliabilityCrossCheckResult(result: [:], disagreement: disagreements.joined(separator: "; "))
        }
        return PDReliabilityCrossCheckResult(result: ordinal, disagreement: nil)
    }
    static func joinUnidentifiedPortByElimination(
        hpmPorts: [HPMPortInput],
        smcChannels: [SMCPortPowerInput]
    ) -> [HPMPortInput] {
        let unidentified = hpmPorts.indices.filter { !hpmPorts[$0].isMagSafe && hpmPorts[$0].uuid.isEmpty }
        guard unidentified.count == 1, let index = unidentified.first else { return hpmPorts }

        // Every UUID the roster already accounts for, MagSafe included: a
        // channel matching a MagSafe port is matched, not spare.
        let claimed = Set(
            hpmPorts.filter { !$0.uuid.isEmpty }.map { SMCContractAttribution.normalisedUUID($0.uuid) }
        )
        let spare = smcChannels.filter { !$0.uuid.isEmpty && !claimed.contains($0.uuid) }
        guard spare.count == 1, let recovered = spare.first else { return hpmPorts }

        // The two sides have to account for each other. Where there are more
        // channels than ports, or fewer, some port is present on one side and
        // absent from the other, and the spare channel is as likely to be that
        // port's as this one's.
        guard smcChannels.count == hpmPorts.count else { return hpmPorts }

        // The check the counts cannot make on their own: a port missing from
        // the roster leaves its channel spare while the counts still line up.
        // The SMC publishes its channels in USB-C port order, D-channel j + 1
        // for USB-C offset j, the same relation crossCheckPDJoin leans on, so
        // the spare channel has to be the one this port's own offset predicts.
        // If that assumption is ever wrong the join simply refuses, which is
        // the port keeping no identity, never a wrong one.
        let usbCPorts = hpmPorts.filter { !$0.isMagSafe }.sorted { $0.portNumber < $1.portNumber }
        guard let offset = usbCPorts.firstIndex(where: { $0.uuid.isEmpty }),
              recovered.channel == offset + 1 else { return hpmPorts }

        var joined = hpmPorts
        let port = hpmPorts[index]
        joined[index] = HPMPortInput(
            uuid: recovered.uuid,
            portNumber: port.portNumber,
            portType: port.portType,
            overcurrentCount: port.overcurrentCount,
            plugEventCount: port.plugEventCount,
            connectionCount: port.connectionCount,
            authorizationStatus: port.authorizationStatus,
            ldcmStatus: port.ldcmStatus,
            provisionedTransports: port.provisionedTransports,
            unauthorizedTransports: port.unauthorizedTransports,
            liquidDetected: port.liquidDetected,
            mitigationsActive: port.mitigationsActive
        )
        return joined
    }
}
