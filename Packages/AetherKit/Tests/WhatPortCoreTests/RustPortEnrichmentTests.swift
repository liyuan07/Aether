// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import WhatPortCore

final class RustPortEnrichmentTests: XCTestCase {
    func testMetadataAndDeviceGroupsMatchOriginalAcrossSixThousandSnapshots() {
        var seed: UInt64 = 993
        func next() -> UInt64 { seed = seed &* 6364136223846793005 &+ 1; return seed >> 32 }
        func id() -> Int { let value = next(); return value % 20 == 0 ? Int.max : value % 20 == 1 ? Int.min : Int(value % 8) - 2 }
        for _ in 0..<6_000 {
            let ports = (0..<Int(next() % 8)).map { _ in next() % 3 == 0 ? PortState(id: 100 + Int(next() % 8) - 2, portType: .magSafe) : PortState(id: id()) }
            let displays = (0..<Int(next() % 12)).map { DisplayInput(portNumber: id(), productName: "synthetic-\($0)") }
            let stats = (0..<Int(next() % 12)).map { PortStatsInput(portNumber: id(), connectCount: $0) }
            let cc = (0..<Int(next() % 12)).map { index in CCInput(portNumber: id(), portType: next() % 3 == 0 ? "MagSafe 3" : "USB-C", active: false, cableProductType: next() % 2 == 0 ? "" : "synthetic-\(index)") }
            let hpm = (0..<Int(next() % 12)).map { HPMPortInput(uuid: "synthetic-\($0)", portNumber: id(), portType: next() % 2 == 0 ? "MagSafe 3" : "USB-C") }
            let devices = (0..<Int(next() % 24)).map { DeviceInput(portNumber: id(), productName: "synthetic-\($0)", locationID: Int(next() % 4)) }
            let plan = RustPortEnrichment.plan(ports: ports, displays: displays, stats: stats, cc: cc, hpm: hpm, devices: devices)
            XCTAssertEqual(plan.rows.count, ports.count)
            for (port, row) in zip(ports, plan.rows) {
                XCTAssertEqual(Int(row.display), displays.firstIndex { $0.portNumber == port.id } ?? -1)
                XCTAssertEqual(Int(row.stats), stats.firstIndex { $0.portNumber == port.id } ?? -1)
                let cable = cc.firstIndex { $0.portNumber == port.id && $0.portType == "USB-C" }
                XCTAssertEqual(Int(row.cable), cable.flatMap { cc[$0].cableProductType.isEmpty ? nil : $0 } ?? -1)
                let mag = port.portType == .magSafe ? hpm.firstIndex { $0.isMagSafe && $0.portNumber == port.id - 100 } : nil
                XCTAssertEqual(Int(row.hpm), mag ?? -1)
                XCTAssertEqual(Array(plan.devices[row.device_start..<(row.device_start + row.device_count)]), devices.indices.filter { devices[$0].portNumber == port.id })
            }
        }
    }

    func testDeviceSelectionCacheTracksMutationAndIndependentValueCopies() {
        let classes: [USBDeviceClass?] = [nil, .hub, .audio, .massStorage]
        var state = PortState(id: 1)
        func check(_ state: PortState) {
            let original = state.usbDevices.first { $0.deviceClass != .hub } ?? state.usbDevices.first
            XCTAssertEqual(state.usbDevice, original)
            XCTAssertEqual(state.additionalDeviceCount, max(0, state.usbDevices.filter { $0.deviceClass != .hub }.count - 1))
        }
        for count in 0..<80 {
            state.usbDevices = (0..<count).map { USBDeviceInfo(productName: "synthetic-\($0)", vendorName: "", deviceClass: classes[($0 + count) % classes.count]) }
            check(state)
            var copied = state
            copied.usbDevices.append(USBDeviceInfo(productName: "appended", vendorName: "", deviceClass: .hub))
            check(state); check(copied)
            copied.usbDevices[0].deviceClass = .massStorage
            check(state); check(copied)
            copied.usbDevices.removeAll()
            check(state); check(copied)
            state.usbDevices.reverse()
            check(state)
        }
        let map: [Int: USBDeviceClass] = [9: .hub, 1: .audio, 14: .video, 8: .massStorage, 11: .smartCard, 17: .billboard, 224: .wireless, 239: .miscellaneous, 255: .vendorSpecific]
        for code in Array(0...65_535) + [Int.min, Int.max, -1] { XCTAssertEqual(USBDeviceClass(code: code), map[code]) }
    }

    func testEnrichmentKeepsFirstEmptyCableAndActualDisplayStatisticsAndMagSafeHealth() {
        let manager = PortManager()
        manager.applySnapshot(PortManagerSnapshot(
            hpmPorts: [HPMPortInput(uuid: "usb", portNumber: 1, portType: "USB-C"), HPMPortInput(uuid: "mag", portNumber: 1, portType: "MagSafe 3", overcurrentCount: 7)],
            ccData: [CCInput(portNumber: 1, active: true), CCInput(portNumber: 1, active: true, cableProductType: "later"), CCInput(portNumber: 1, portType: "MagSafe 3", active: true)],
            deviceData: [DeviceInput(portNumber: 1, productName: "hub", deviceClass: 9), DeviceInput(portNumber: 1, productName: "storage", deviceClass: 8)],
            displayData: [DisplayInput(portNumber: 1, productName: "first display", maxWidth: 1920, maxHeight: 1080), DisplayInput(portNumber: 1, productName: "later")],
            portStatsData: [PortStatsInput(portNumber: 1, connectCount: 17), PortStatsInput(portNumber: 1, connectCount: 99)]))
        let usb = manager.ports.first { $0.id == 1 }
        XCTAssertEqual(usb?.deviceName, "first display")
        XCTAssertEqual(usb?.displayWidth, 1920)
        XCTAssertEqual(usb?.usbDevice?.productName, "storage")
        XCTAssertEqual(usb?.additionalDeviceCount, 0)
        XCTAssertNil(usb?.cable)
        XCTAssertEqual(usb?.portStats?.connectCount, 17)
        let mag = manager.ports.first { $0.id == 101 }
        XCTAssertEqual(mag?.uuid, "mag")
        XCTAssertEqual(mag?.health?.overcurrentCount, 7)
        XCTAssertTrue(mag?.usbDevices.isEmpty == true)
    }

    func testCachedSelectionBenchmark() throws {
        guard ProcessInfo.processInfo.environment["AETHER_RUN_CORE_BENCHMARKS"] == "1" else { throw XCTSkip("Run explicitly with synthetic devices") }
        var port = PortState(id: 1)
        port.usbDevices = (0..<1_000).map { USBDeviceInfo(productName: "synthetic-\($0)", vendorName: "", deviceClass: $0 % 3 == 0 ? .hub : .massStorage) }
        var old = 0, cached = 0
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<20_000 {
            if (port.usbDevices.first { $0.deviceClass != .hub } ?? port.usbDevices.first) != nil {
                old += max(0, port.usbDevices.filter { $0.deviceClass != .hub }.count - 1)
            }
        }
        let oldNS = DispatchTime.now().uptimeNanoseconds - start
        let cachedStart = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<20_000 { if port.usbDevice != nil { cached += port.additionalDeviceCount } }
        let cachedNS = DispatchTime.now().uptimeNanoseconds - cachedStart
        XCTAssertEqual(old, cached)
        print("AETHER_DEVICE_SELECTION_BENCHMARK devices=1000 reads=20000 old_ns=\(oldNS) cached_ns=\(cachedNS)")
    }
}
