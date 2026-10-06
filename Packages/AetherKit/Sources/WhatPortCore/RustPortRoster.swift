// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import CAetherCore

enum RustPortRoster {
    static func plan(hpm: [HPMPortInput], phy: [PhyInput], tb: [ThunderboltInput], power: [PowerInput], cc: [CCInput])
        -> (rows: [AetherRosterRow], tier: PortDataTier, tbIndices: [Int]) {
        let h = hpm.map { AetherRosterHPM(id: Int64($0.portNumber), magsafe: $0.isMagSafe ? 1 : 0) }
        let p = phy.map { AetherPortPhy(port: Int64($0.portNumber), id: Int64($0.phyID),
            active: !$0.lane0Transport.isEmpty || !$0.lane1Transport.isEmpty ? 1 : 0) }
        let t = tb.map { AetherPortTB(socket: Int64($0.socketID), width: Int64($0.currentLinkWidth)) }
        let w = power.map { Int64($0.portIndex) }
        let c = cc.map { AetherRosterCC(id: Int64($0.portNumber), usb: $0.portType == "USB-C" ? 1 : 0, active: $0.active ? 1 : 0) }
        var rows = [AetherRosterRow](repeating: .init(), count: hpm.count + phy.count + tb.count)
        var tbIndices = [Int](repeating: 0, count: tb.count)
        let result = h.withUnsafeBufferPointer { h in p.withUnsafeBufferPointer { p in t.withUnsafeBufferPointer { t in
            w.withUnsafeBufferPointer { w in c.withUnsafeBufferPointer { c in rows.withUnsafeMutableBufferPointer { out in
                tbIndices.withUnsafeMutableBufferPointer { tbOut in
                    aether_port_roster(h.baseAddress,h.count,p.baseAddress,p.count,t.baseAddress,t.count,
                        w.baseAddress,w.count,c.baseAddress,c.count,out.baseAddress,out.count,tbOut.baseAddress,tbOut.count)
                }
            } } }
        } } }
        return (Array(rows.prefix(result.count)), RustPortPolicy.tier(result.tier), Array(tbIndices.prefix(result.tb_count)))
    }
}
