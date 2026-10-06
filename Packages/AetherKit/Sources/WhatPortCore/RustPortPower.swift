// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import CAetherCore

enum RustPortPower {
    private static func ports(_ ports: [PortState], key: ((String) -> UInt64)? = nil) -> [AetherPowerPort] {
        ports.map { port in
            let p = port.power
            return .init(id: Int64(port.id), key: key.flatMap { mapping in port.uuid.map { mapping(SMCContractAttribution.normalisedUUID($0)) } } ?? 0,
                connected: port.ccConnected ? 1 : 0, has_power: p == nil ? 0 : 1,
                power: .init(watts: p?.watts ?? 0, current: Int64(p?.current ?? 0), voltage: Int64(p?.voltage ?? 0),
                    configured_voltage: Int64(p?.configuredVoltage ?? 0), configured_current: Int64(p?.configuredCurrent ?? 0),
                    vconn_current: Int64(p?.vconnCurrent ?? 0), vconn_power: Int64(p?.vconnPower ?? 0),
                    vconn_max_current: Int64(p?.vconnMaxCurrent ?? 0), incoming: p?.direction == .incoming ? 1 : 0,
                    estimated: p?.contractIsEstimated == true ? 1 : 0))
        }
    }
    private static func telemetry(_ t: ChargingPowerInput?) -> AetherPowerTelemetry {
        .init(present: t == nil ? 0 : 1, power: Int64(t?.systemPowerIn ?? 0), current: Int64(t?.systemCurrentIn ?? 0), voltage: Int64(t?.systemVoltageIn ?? 0))
    }
    private static func apply(_ patches: [AetherPowerPatch], count: Int, to ports: inout [PortState]) {
        for patch in patches.prefix(count) {
            let p = patch.power
            // Native checked Double-to-Int conversion preserves the existing platform conversion contract.
            ports[patch.index].power = .init(watts: p.watts,
                current: patch.convert_raw != 0 ? Int(patch.raw_current) : Int(p.current),
                voltage: patch.convert_raw != 0 ? Int(patch.raw_voltage) : Int(p.voltage),
                configuredVoltage: Int(p.configured_voltage), configuredCurrent: Int(p.configured_current),
                vconnCurrent: Int(p.vconn_current), vconnPower: Int(p.vconn_power), vconnMaxCurrent: Int(p.vconn_max_current),
                direction: p.incoming != 0 ? .incoming : .outgoing, contractIsEstimated: p.estimated != 0)
        }
    }
    static func charger(_ nodes: [ChargerInput], telemetry t: ChargingPowerInput?, to result: inout [PortState]) {
        if nodes.isEmpty || result.isEmpty { return }
        let input = ports(result)
        let nodes = nodes.map { AetherPowerCharger(id: Int64($0.portNumber), max_watts: Int64($0.maxWatts),
            voltage: Int64($0.voltage), current: Int64($0.maxCurrent), usb: $0.portType == "USB-C" ? 1 : 0, winning: $0.hasWinningContract ? 1 : 0) }
        var patches = [AetherPowerPatch](repeating: .init(), count: result.count)
        let count = input.withUnsafeBufferPointer { p in nodes.withUnsafeBufferPointer { n in patches.withUnsafeMutableBufferPointer { out in
            aether_port_charger_power(p.baseAddress, p.count, n.baseAddress, n.count, telemetry(t), out.baseAddress, out.count)
        } } }
        apply(patches, count: count, to: &result)
    }
    static func contract(_ contract: SMCPortContractInput, portID: Int, telemetry t: ChargingPowerInput?, to result: inout [PortState]) {
        let input = ports(result)
        var patches = [AetherPowerPatch](repeating: .init(), count: result.count)
        let count = input.withUnsafeBufferPointer { p in patches.withUnsafeMutableBufferPointer { out in
            aether_port_contract_power(p.baseAddress, p.count, Int64(portID), Int64(contract.voltageMV), Int64(contract.currentMA), telemetry(t), out.baseAddress, out.count)
        } }
        apply(patches, count: count, to: &result)
    }
    static func output(_ channels: [SMCPortPowerInput], to result: inout [PortState]) {
        if channels.isEmpty || result.isEmpty { return }
        var keys: [String: UInt64] = [:]
        func key(_ s: String) -> UInt64 {
            if let existing = keys[s] { return existing }
            let value = UInt64(keys.count + 1); keys[s] = value; return value
        }
        let input = ports(result, key: key)
        let channels = channels.map { AetherPowerOutput(key: key($0.uuid), volts: $0.volts, amps: $0.amps) }
        var patches = [AetherPowerPatch](repeating: .init(), count: result.count)
        let count = input.withUnsafeBufferPointer { p in channels.withUnsafeBufferPointer { c in patches.withUnsafeMutableBufferPointer { out in
            aether_port_output_power(p.baseAddress, p.count, c.baseAddress, c.count, out.baseAddress, out.count)
        } } }
        apply(patches, count: count, to: &result)
    }
    static func connectors(_ entries: [CCInput], chargers: [ChargerInput], telemetry t: ChargingPowerInput?,
                           usbNode: Bool, usbSMC: Bool, smcPorts: Set<Int>) -> [PortState] {
        var result = entries.map { PortState(id: 100 + $0.portNumber,
            portType: $0.portType.lowercased().contains("magsafe") ? .magSafe : .usbC, ccConnected: $0.active) }
        guard !entries.isEmpty else { return result }
        let entries = entries.map { AetherPowerConnector(id: Int64($0.portNumber), active: $0.active ? 1 : 0) }
        let chargers = chargers.map { AetherPowerCharger(id: Int64($0.portNumber), max_watts: Int64($0.maxWatts),
            voltage: Int64($0.voltage), current: Int64($0.maxCurrent), usb: $0.portType == "USB-C" ? 1 : 0, winning: $0.hasWinningContract ? 1 : 0) }
        let smcPorts = smcPorts.map(Int64.init)
        var patches = [AetherPowerPatch](repeating: .init(), count: result.count)
        let count = entries.withUnsafeBufferPointer { e in chargers.withUnsafeBufferPointer { c in
            smcPorts.withUnsafeBufferPointer { s in patches.withUnsafeMutableBufferPointer { out in
                aether_port_connector_power(e.baseAddress,e.count,c.baseAddress,c.count,s.baseAddress,s.count,
                    telemetry(t),usbNode ? 1 : 0,usbSMC ? 1 : 0,out.baseAddress,out.count)
            } }
        } }
        apply(patches, count: count, to: &result)
        return result
    }

}
