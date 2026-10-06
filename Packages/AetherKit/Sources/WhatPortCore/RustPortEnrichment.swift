// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import CAetherCore

enum RustPortEnrichment {
    struct Plan {
        let rows: [AetherEnrichmentRow]
        let devices: [Int]
    }
    static func plan(ports: [PortState], displays: [DisplayInput] = [], stats: [PortStatsInput] = [],
                     cc: [CCInput] = [], hpm: [HPMPortInput] = [], devices: [DeviceInput] = []) -> Plan {
        let ports = ports.map { AetherEnrichmentPort(id: Int64($0.id), magsafe: $0.portType == .magSafe ? 1 : 0) }
        let displays = displays.map { AetherEnrichmentSource(id: Int64($0.portNumber), flags: 1) }
        let stats = stats.map { AetherEnrichmentSource(id: Int64($0.portNumber), flags: 1) }
        let cables = cc.map { AetherEnrichmentSource(id: Int64($0.portNumber), flags: ($0.portType == "USB-C" ? 1 : 0) | ($0.cableProductType.isEmpty ? 0 : 2)) }
        let hpm = hpm.map { AetherEnrichmentSource(id: Int64($0.portNumber), flags: $0.isMagSafe ? 1 : 0) }
        let devices = devices.map { Int64($0.portNumber) }
        let owner = ports.withUnsafeBufferPointer { p in displays.withUnsafeBufferPointer { d in
            stats.withUnsafeBufferPointer { s in cables.withUnsafeBufferPointer { c in
                hpm.withUnsafeBufferPointer { h in devices.withUnsafeBufferPointer { u in
                    aether_port_enrichment_create(p.baseAddress,p.count,d.baseAddress,d.count,s.baseAddress,s.count,
                        c.baseAddress,c.count,h.baseAddress,h.count,u.baseAddress,u.count)
                } }
            } }
        } }
        precondition(owner != nil)
        defer { aether_port_enrichment_destroy(owner) }
        let view = aether_port_enrichment_view(owner)
        precondition(view.count == ports.count)
        return Plan(rows: view.count == 0 ? [] : Array(UnsafeBufferPointer(start: view.rows, count: view.count)),
                    devices: view.device_count == 0 ? [] : Array(UnsafeBufferPointer(start: view.devices, count: view.device_count)))
    }
    static func selection(_ devices: [USBDeviceInfo]) -> (index: Int?, additional: Int) {
        let flags: [UInt8] = devices.map { $0.deviceClass == .hub ? 1 : 0 }
        let result = flags.withUnsafeBufferPointer { aether_usb_device_selection($0.baseAddress, $0.count) }
        return (result.primary < 0 ? nil : Int(result.primary), result.additional)
    }
}
