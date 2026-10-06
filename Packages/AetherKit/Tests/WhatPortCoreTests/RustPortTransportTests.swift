// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import Testing
@testable import WhatPortCore

@Test func rustPortTransportsMatchOriginalAcrossFiveThousandSnapshots() {
    var seed: UInt64 = 176
    func next() -> UInt64 { seed = seed &* 6364136223846793005 &+ 1; return seed >> 32 }
    func id() -> Int { let n = next(); return n % 20 == 0 ? Int.max : n % 20 == 1 ? Int.min : Int(n % 6) - 1 }
    for _ in 0..<5000 {
        let ports = (0..<Int(next() % 8)).map { _ in PortState(id:id(), thunderboltLink: next() % 2 == 0 ? nil : ThunderboltLinkState(generation:.tb4,perLaneGbps:20,txLanes:2,rxLanes:2)) }
        let hpm = (0..<Int(next() % 12)).map { index in HPMPortInput(uuid:"synthetic-\(index)",portNumber:id(),portType:next() % 3 == 0 ? "MagSafe 3" : "USB-C",provisionedTransports:["source-\(index)"]) }
        let usb = (0..<Int(next() % 12)).map { index in USB3TransportInput(portNumber:id(),active:next() % 2 == 0,dataRate:"rate-\(index)",generation:"generation-\(index)",tunneled:next() % 2 == 0,transportRestricted:next() % 2 == 0) }
        let dp = (0..<Int(next() % 12)).map { index in DPTransportInput(portNumber:id(),active:next() % 2 == 0,linkRate:"dp-\(index)",laneCount:Int(next() % 4),maxLaneCount:4,tunneled:next() % 2 == 0,sinkCount:index,branchDevice:"branch-\(index)",dfpType:"type-\(index)") }
        let cio = (0..<Int(next() % 12)).map { index in CIOTransportInput(portNumber:id(),active:next() % 2 == 0,dataRate:"cio-\(index)",tunneled:next() % 2 == 0,tunnelProvisioned:["provisioned-\(index)"],tunnelSupported:["supported-\(index)"],deviceModel:"model-\(index)",deviceVendor:"vendor-\(index)") }
        let rows = RustPortTransports.plan(ports:ports,hpm:hpm,usb:usb,dp:dp,cio:cio)
        #expect(rows.count == ports.count)
        for (port,row) in zip(ports,rows) {
            #expect(Int(row.hpm) == (hpm.firstIndex { !$0.isMagSafe && $0.portNumber == port.id } ?? -1))
            let firstCIO = cio.firstIndex { $0.portNumber == port.id }
            #expect(Int(row.cio) == (firstCIO ?? -1))
            let identity = firstCIO.flatMap { cio[$0].active && port.thunderboltLink != nil ? $0 : nil }
            #expect(Int(row.identity_cio) == (identity ?? -1))
            #expect(RustPortTransports.live(row:row,usb:usb,dp:dp,cio:cio) == originalLiveTransports(portID:port.id,usb3Transport:usb,dpTransport:dp,cioTransport:cio))
        }
    }
}

@Test func rustPortTransportsKeepInactiveFirstIdentitySeparateFromActiveLink() {
    let ports = [PortState(id:1,thunderboltLink:ThunderboltLinkState(generation:.tb4,perLaneGbps:20,txLanes:2,rxLanes:2))]
    let usb = [USB3TransportInput(portNumber:1,active:false), USB3TransportInput(portNumber:1,transportRestricted:true), USB3TransportInput(portNumber:1,active:true)]
    let cio = [CIOTransportInput(portNumber:1,active:false,tunnelProvisioned:["old"],deviceModel:"old"), CIOTransportInput(portNumber:1,active:true,dataRate:"40 Gbps",deviceModel:"new")]
    let row = RustPortTransports.plan(ports:ports,hpm:[],usb:usb,dp:[],cio:cio)[0]
    #expect(row.usb == 1)
    #expect(row.cio == 0)
    #expect(row.live_cio == 1)
    #expect(row.identity_cio == -1)
    let links = RustPortTransports.live(row:row,usb:usb,dp:[],cio:cio)
    #expect(links.count == 2)
    #expect(links[0].restricted)
    #expect(links[1].dataRate == "40 Gbps")
}

@Test func portManagerKeepsTransportIdentityAndLiveSelectionDistinct() {
    let manager = PortManager()
    manager.applySnapshot(PortManagerSnapshot(
        hpmPorts:[HPMPortInput(uuid:"synthetic",portNumber:1,portType:"USB-C",unauthorizedTransports:["USB3"])],
        phyData:[PhyInput(phyID:0,portNumber:1)],
        tbData:[ThunderboltInput(socketID:1,currentLinkWidth:2,currentLinkSpeed:4)],
        usb3Transport:[USB3TransportInput(portNumber:1,active:false,dataRate:"5 Gbps",transportRestricted:true)],
        cioTransport:[CIOTransportInput(portNumber:1,active:false,tunnelProvisioned:["old"],deviceModel:"old"),
                      CIOTransportInput(portNumber:1,active:true,dataRate:"40 Gbps",deviceModel:"new")]
    ))
    let port = manager.ports.first { $0.id == 1 }
    #expect(port?.thunderboltLink?.deviceName == nil)
    #expect(port?.transports?.unauthorized == ["USB3"])
    #expect(port?.transports?.tunnelProvisioned == ["old"])
    #expect(port?.liveTransports.map(\.dataRate) == ["5 Gbps","40 Gbps"])
    #expect(port?.liveTransports.first?.restricted == true)
}

    private func originalLiveTransports(
        portID: Int,
        usb3Transport: [USB3TransportInput],
        dpTransport: [DPTransportInput],
        cioTransport: [CIOTransportInput]
    ) -> [LiveTransport] {
        var transports: [LiveTransport] = []

        // Include a restricted link even when it is not active: macOS has
        // negotiated a speed but blocked data, and we want to show that
        // rather than silently dropping the port as idle.
        if let usb3 = usb3Transport.first(where: {
            $0.portNumber == portID && ($0.active || $0.transportRestricted)
        }) {
            transports.append(LiveTransport(
                kind: .usb,
                dataRate: usb3.dataRate,
                generation: usb3.generation,
                tunneled: usb3.tunneled,
                restricted: usb3.transportRestricted
            ))
        }

        if let dp = dpTransport.first(where: { $0.portNumber == portID && $0.active }) {
            transports.append(LiveTransport(
                kind: .displayPort,
                dataRate: dp.linkRate,
                laneCount: dp.laneCount,
                maxLaneCount: dp.maxLaneCount,
                tunneled: dp.tunneled,
                sinkCount: dp.sinkCount,
                branchDevice: dp.branchDevice,
                dfpType: dp.dfpType
            ))
        }

        if let cio = cioTransport.first(where: { $0.portNumber == portID && $0.active }) {
            transports.append(LiveTransport(
                kind: .thunderbolt,
                dataRate: cio.dataRate,
                tunneled: cio.tunneled
            ))
        }

        return transports
    }

