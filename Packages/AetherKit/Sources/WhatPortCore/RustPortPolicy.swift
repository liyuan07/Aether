// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import CAetherCore

enum RustPortPolicy {
    static func tier(_ code: UInt8) -> PortDataTier {
        switch code { case 0: return .full; case 1: return .thunderboltOnly; case 2: return .none; default: return .unknown }
    }
    static func tbIndices(_ rows: [ThunderboltInput]) -> [Int] {
        let borrowed = rows.map { AetherPortTB(socket: Int64($0.socketID), width: Int64($0.currentLinkWidth)) }
        var indices = [Int](repeating: 0, count: rows.count)
        let count = borrowed.withUnsafeBufferPointer { input in
            indices.withUnsafeMutableBufferPointer { output in
                aether_port_tb_plan(input.baseAddress, input.count, output.baseAddress, output.count)
            }
        }
        return Array(indices.prefix(count))
    }
    static func phyIndices(_ rows: [PhyInput]) -> [Int] {
        let borrowed = rows.map { AetherPortPhy(port: Int64($0.portNumber), id: Int64($0.phyID),
            active: !$0.lane0Transport.isEmpty || !$0.lane1Transport.isEmpty ? 1 : 0) }
        var indices = [Int](repeating: 0, count: rows.count)
        let count = borrowed.withUnsafeBufferPointer { input in
            indices.withUnsafeMutableBufferPointer { output in
                aether_port_phy_plan(input.baseAddress, input.count, output.baseAddress, output.count)
            }
        }
        return Array(indices.prefix(count))
    }
}
