// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CAetherCore

/// Rust executes fail-closed SMC contract attribution; native readers and String semantics stay native.
public enum SMCContractAttribution {
    public static var isEnabled: Bool { !UserDefaults.standard.bool(forKey: "SMCContractDisabled") }
    public static func normalisedUUID(_ uuid: String) -> String {
        uuid.replacingOccurrences(of: "-", with: "").lowercased()
    }
    private static func contract(_ c: SMCPortContractInput, key: UInt64 = 0) -> AetherSMCContract {
        .init(key: key, power: Int64(c.powerMW), voltage: Int64(c.voltageMV), current: Int64(c.currentMA),
            outgoing_label: c.label.lowercased().contains("usb host") ? 1 : 0)
    }
    private static func nodes(_ nodes: [ChargerInput]) -> [AetherSMCNode] {
        nodes.map { .init(id: Int64($0.portNumber), usb: $0.portType == "USB-C" ? 1 : 0, winning: $0.hasWinningContract ? 1 : 0) }
    }
    public static func macOSDescribesCharging(chargerNodes: [ChargerInput]) -> Bool {
        nodes(chargerNodes).withUnsafeBufferPointer { aether_smc_describes_charging($0.baseAddress, $0.count) != 0 }
    }
    static func isInternallyConsistent(_ c: SMCPortContractInput) -> Bool {
        aether_smc_contract_consistent(Int64(c.powerMW), Int64(c.voltageMV), Int64(c.currentMA)) != 0
    }
    static func isSourcingPowerOut(_ out: SMCPortPowerInput?) -> Bool {
        aether_smc_sourcing_power(out?.watts ?? 0, out == nil ? 0 : 1) != 0
    }
    public static func isPlausibleIncomingContract(_ c: SMCPortContractInput, powerOut: SMCPortPowerInput? = nil) -> Bool {
        var value = contract(c)
        return aether_smc_contract_plausible(&value, powerOut == nil ? 0 : 1, powerOut?.watts ?? 0) != 0
    }
    private static func select(contracts: [SMCPortContractInput], ports: [PortState], chargerNodes: [ChargerInput],
        powerOut: [SMCPortPowerInput], externalConnected: Bool, enabled: Bool, candidateOnly: Bool) -> AetherSMCResult {
        // Intern keys using Swift's canonical String equality. Rust receives only identity tokens, no UUID copies.
        var keys: [String: UInt64] = [:]
        func key(_ value: String) -> UInt64 {
            if let found = keys[value] { return found }
            let token = UInt64(keys.count + 1); keys[value] = token; return token
        }
        let c = contracts.map { contract($0, key: key($0.uuid)) }
        let p = ports.map { port in
            AetherSMCPort(key: port.uuid.map { key(normalisedUUID($0)) } ?? 0, id: Int64(port.id),
                usb: port.portType == .usbC ? 1 : 0, connected: port.ccConnected ? 1 : 0,
                has_power: port.power == nil ? 0 : 1, incoming: port.power?.direction == .incoming ? 1 : 0)
        }
        let n = nodes(chargerNodes)
        let o = powerOut.map { AetherSMCPowerOut(key: key($0.uuid), watts: $0.watts) }
        return c.withUnsafeBufferPointer { c in p.withUnsafeBufferPointer { p in n.withUnsafeBufferPointer { n in o.withUnsafeBufferPointer { o in
            aether_smc_contract_select(c.baseAddress, c.count, p.baseAddress, p.count, n.baseAddress, n.count,
                o.baseAddress, o.count, externalConnected ? 1 : 0, enabled ? 1 : 0, candidateOnly ? 1 : 0)
        } } } }
    }
    public static func resolve(contracts: [SMCPortContractInput], ports: [PortState], chargerNodes: [ChargerInput],
        externalConnected: Bool, powerOut: [SMCPortPowerInput] = [], enabled: Bool = isEnabled)
        -> (portID: Int, contract: SMCPortContractInput)? {
        // Preserve the original cheap inactive path before allocating bridge arrays or normalizing keys.
        guard aether_smc_resolution_enabled(enabled ? 1 : 0, externalConnected ? 1 : 0) != 0 else { return nil }
        let result = select(contracts: contracts, ports: ports, chargerNodes: chargerNodes, powerOut: powerOut,
            externalConnected: externalConnected, enabled: enabled, candidateOnly: false)
        guard result.index >= 0, result.index < contracts.count else { return nil }
        return (Int(result.port_id), contracts[Int(result.index)])
    }
    public static func hasUSBCContractCandidate(contracts: [SMCPortContractInput], ports: [PortState],
        powerOut: [SMCPortPowerInput] = []) -> Bool {
        select(contracts: contracts, ports: ports, chargerNodes: [], powerOut: powerOut,
            externalConnected: false, enabled: false, candidateOnly: true).index >= 0
    }
}
