// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import WhatPortIOKit

private func powerFields(_ p: RawPowerData) -> [Int] {
    [p.portIndex,p.watts,p.current,p.adapterVoltage,p.configuredVoltage,p.configuredCurrent,p.pdPowerMW,p.filteredPower,p.vconnCurrent,p.vconnPower,p.vconnMaxCurrent,p.powerState,p.accumulatedPowerMJ,p.accumulatorCount]
}
private func chargingFields(_ p: RawChargingPower?) -> [Int]? {
    p.map { [$0.systemPowerIn,$0.systemVoltageIn,$0.systemCurrentIn,$0.isCharging ? 1 : 0,$0.fullyCharged ? 1 : 0,$0.notChargingReason] }
}

@Test func combinedBatterySnapshotPreservesAllOutputFieldsAndIndependentFailures() {
    let keys = ["PortIndex","Watts","Current","AdapterVoltage","ConfiguredVoltage","ConfiguredCurrent","PDPowermW","FilteredPower","VConnCurrent","VConnPower","VConnMaxCurrent","PowerState","AccumulatedPower","AccumulatorCount"]
    let entry = Dictionary(uniqueKeysWithValues: keys.enumerated().map { ($0.element, $0.offset + 1) })
    var snapshot = BatterySnapshot()
    snapshot.append(properties:nil,powerOut:[entry])
    #expect(snapshot.power.map(powerFields) == [Array(1...14)])
    #expect(snapshot.meteringAvailable)
    #expect(snapshot.charging == nil)
    #expect(snapshot.identity == nil)
    snapshot.append(properties:["ExternalConnected":true,"PowerTelemetryData":["SystemPowerIn":123,"SystemVoltageIn":456,"SystemCurrentIn":789],"AdapterDetails":["Name":"synthetic"]],powerOut:nil)
    #expect(chargingFields(snapshot.charging) == [123,456,789,0,0,0])
    #expect(snapshot.identity?.name == "synthetic")
    snapshot.append(properties:["ExternalConnected":false],powerOut:[entry])
    snapshot.append(properties:nil,powerOut:nil)
    #expect(snapshot.power.map(powerFields) == [Array(1...14),Array(1...14)])
    #expect(chargingFields(snapshot.charging) == [123,456,789,0,0,0])
    #expect(snapshot.identity?.name == "synthetic")
}

@Test func combinedBatteryAggregationMatchesOriginalIndependentWalkSemantics() {
    var seed: UInt64 = 225
    func next() -> UInt64 { seed = seed &* 6364136223846793005 &+ 1; return seed >> 32 }
    for _ in 0..<1000 {
        let services: [(properties:[String:Any]?,powerOut:Any?)] = (0..<Int(next() % 8)).map { index in
            let props: [String:Any]? = next() % 4 == 0 ? nil : ["ExternalConnected":next() % 2 == 0,"IsCharging":next() % 2 == 0,
                "FullyCharged":next() % 2 == 0,"PowerTelemetryData":["SystemPowerIn":index,"SystemVoltageIn":index + 2,"SystemCurrentIn":index + 3],
                "AdapterDetails":["Name":"synthetic-\(index)","Manufacturer":"合成","Watts":index,"UsbHvcMenu":[["MaxVoltage":index,"MaxCurrent":index + 1]]]]
            let power: Any? = next() % 3 == 0 ? nil : next() % 2 == 0 ? [] as [Any] : [["PortIndex":index,"Watts":index + 1]]
            return (props,power)
        }
        // Reference: separate registry walks append every output row, OR availability,
        // and keep the last successful charging/identity parse, never clobber with nil.
        let oldPower = services.compactMap(\.powerOut).flatMap { PowerReader.parsePowerOut($0 as? [Any] ?? []) }
        let oldCharging = services.compactMap(\.properties).compactMap { PowerReader.parseChargingPower(properties:$0) }.last
        let oldIdentity = services.compactMap(\.properties).compactMap { PowerReader.parseChargerIdentity(properties:$0) }.last
        let snapshot = autoreleasepool {
            var result = BatterySnapshot()
            for service in services { result.append(properties:service.properties,powerOut:service.powerOut) }
            return result
        }
        #expect(snapshot.power.map(powerFields) == oldPower.map(powerFields))
        #expect(snapshot.meteringAvailable == services.contains { $0.powerOut != nil })
        #expect(chargingFields(snapshot.charging) == chargingFields(oldCharging))
        #expect(snapshot.identity?.name == oldIdentity?.name)
        #expect(snapshot.identity?.manufacturer == oldIdentity?.manufacturer)
        #expect(snapshot.identity?.maxWatts == oldIdentity?.maxWatts)
        #expect(snapshot.identity?.pdos.map { [$0.voltageMV,$0.currentMA] } == oldIdentity?.pdos.map { [$0.voltageMV,$0.currentMA] })
    }
}
