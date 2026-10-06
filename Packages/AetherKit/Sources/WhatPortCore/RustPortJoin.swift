// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import CAetherCore

enum RustPortJoin {
    private final class Keys {
        var values: [String: UInt64] = [:]
        func key(_ string: String) -> UInt64 {
            if let token = values[string] { return token }
            let token = UInt64(values.count + 1); values[string] = token; return token
        }
    }
    private static func channels(_ channels: [SMCPortPowerInput], keys: Keys) -> [AetherJoinChannel] {
        channels.map { .init(key: keys.key($0.uuid), channel: Int64($0.channel), empty: $0.uuid.isEmpty ? 1 : 0) }
    }
    static func recover(hpm: [HPMPortInput], channels: [SMCPortPowerInput]) -> (hpm: Int, channel: Int)? {
        let keys = Keys()
        let ports = hpm.map { AetherJoinHPM(id: Int64($0.portNumber), key: keys.key(SMCContractAttribution.normalisedUUID($0.uuid)),
            empty: $0.uuid.isEmpty ? 1 : 0, magsafe: $0.isMagSafe ? 1 : 0) }
        let channels = self.channels(channels, keys: keys)
        let result = ports.withUnsafeBufferPointer { p in channels.withUnsafeBufferPointer { c in
            aether_port_identity_recover(p.baseAddress,p.count,c.baseAddress,c.count)
        } }
        guard result.hpm >= 0, result.channel >= 0 else { return nil }
        return (Int(result.hpm),Int(result.channel))
    }
    static func ordinal(_ entries: [PDReliabilityInput], ids: [Int]) -> [Int:PDReliabilityInput] {
        if entries.isEmpty || ids.isEmpty { return [:] }
        let offsets = entries.map { Int64($0.entryOffset) }
        let ids = ids.map(Int64.init)
        var rows = [AetherJoinPair](repeating: .init(), count: ids.count)
        let count = offsets.withUnsafeBufferPointer { p in ids.withUnsafeBufferPointer { ids in rows.withUnsafeMutableBufferPointer { out in
            aether_port_pd_ordinal(p.baseAddress,p.count,ids.baseAddress,ids.count,out.baseAddress,out.count)
        } } }
        return Dictionary(uniqueKeysWithValues: rows.prefix(count).map { (Int($0.port_id),entries[$0.index]) })
    }
    static func cross(ordinal: [Int:PDReliabilityInput], ids: [Int], channels: [SMCPortPowerInput], ports: [PortState]) -> String? {
        if ordinal.isEmpty || channels.isEmpty { return nil }
        let keys = Keys()
        let ports = ports.map { port in AetherJoinPort(id: Int64(port.id),
            key: port.uuid.map { keys.key(SMCContractAttribution.normalisedUUID($0)) } ?? 0, usb: port.portType == .usbC ? 1 : 0) }
        let channels = self.channels(channels, keys: keys)
        let attributed = ordinal.keys.map(Int64.init)
        let ids = ids.map(Int64.init)
        var rows = [AetherJoinDisagreement](repeating: .init(), count: ids.count)
        let count = attributed.withUnsafeBufferPointer { o in ids.withUnsafeBufferPointer { ids in channels.withUnsafeBufferPointer { c in
            ports.withUnsafeBufferPointer { p in rows.withUnsafeMutableBufferPointer { out in
                aether_port_pd_cross(o.baseAddress,o.count,ids.baseAddress,ids.count,c.baseAddress,c.count,p.baseAddress,p.count,out.baseAddress,out.count)
            } }
        } } }
        if count == 0 { return nil }
        return rows.prefix(count).map { "offset \($0.offset) D\($0.channel): keyed=port \($0.keyed) ordinal=port \($0.ordinal)" }.joined(separator: "; ")
    }
}
