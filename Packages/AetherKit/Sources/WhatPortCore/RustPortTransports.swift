// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import CAetherCore

enum RustPortTransports {
    static func plan(ports: [PortState], hpm: [HPMPortInput], usb: [USB3TransportInput],
                     dp: [DPTransportInput], cio: [CIOTransportInput]) -> [AetherTransportRow] {
        guard !ports.isEmpty else { return [] }
        let ports = ports.map { AetherTransportPort(id: Int64($0.id), tb_link: $0.thunderboltLink == nil ? 0 : 1) }
        let hpm = hpm.map { AetherTransportSource(id: Int64($0.portNumber), active: $0.isMagSafe ? 0 : 1, restricted: 0) }
        let usb = usb.map { AetherTransportSource(id: Int64($0.portNumber), active: $0.active ? 1 : 0, restricted: $0.transportRestricted ? 1 : 0) }
        let dp = dp.map { AetherTransportSource(id: Int64($0.portNumber), active: $0.active ? 1 : 0, restricted: 0) }
        let cio = cio.map { AetherTransportSource(id: Int64($0.portNumber), active: $0.active ? 1 : 0, restricted: 0) }
        var rows = [AetherTransportRow](repeating: .init(), count: ports.count)
        let count = ports.withUnsafeBufferPointer { p in hpm.withUnsafeBufferPointer { h in
            usb.withUnsafeBufferPointer { u in dp.withUnsafeBufferPointer { d in cio.withUnsafeBufferPointer { c in
                rows.withUnsafeMutableBufferPointer { out in
                    aether_port_transports(p.baseAddress,p.count,h.baseAddress,h.count,u.baseAddress,u.count,
                        d.baseAddress,d.count,c.baseAddress,c.count,out.baseAddress,out.count)
                }
            } } }
        } }
        precondition(count == rows.count)
        return rows
    }
    static func live(
        row: AetherTransportRow,
        usb: [USB3TransportInput],
        dp: [DPTransportInput],
        cio: [CIOTransportInput]
    ) -> [LiveTransport] {
        var transports: [LiveTransport] = []

        // Include a restricted link even when it is not active: macOS has
        // negotiated a speed but blocked data, and we want to show that
        // rather than silently dropping the port as idle.
        if row.usb >= 0 {
            let usb3 = usb[Int(row.usb)]
            transports.append(LiveTransport(
                kind: .usb,
                dataRate: usb3.dataRate,
                generation: usb3.generation,
                tunneled: usb3.tunneled,
                restricted: usb3.transportRestricted
            ))
        }

        if row.dp >= 0 {
            let dp = dp[Int(row.dp)]
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

        if row.live_cio >= 0 {
            let cio = cio[Int(row.live_cio)]
            transports.append(LiveTransport(
                kind: .thunderbolt,
                dataRate: cio.dataRate,
                tunneled: cio.tunneled
            ))
        }

        return transports
    }

}
