// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import Testing
@testable import WhatPortCore

@Test func rustConnectorPowerMatchesOriginalAcrossSixThousandSnapshots() {
    var seed: UInt64 = 181
    func next() -> UInt64 { seed = seed &* 6364136223846793005 &+ 1; return seed >> 32 }
    let types = ["MagSafe 3","MAGSAFE","prefix-magsafe-suffix","USB-C","usb-c","","synthetic"]
    let extremes = [Int.min,-1,0,1,20000,Int.max]
    var powered = 0
    for _ in 0..<6000 {
        let cc = (0..<Int(next() % 10)).map { _ in CCInput(portNumber:Int(next() % 6) - 1,portType:types[Int(next() % UInt64(types.count))],active:next() % 2 == 0) }
        let chargers = (0..<Int(next() % 12)).map { _ in ChargerInput(portType:types[Int(next() % UInt64(types.count))],portNumber:Int(next() % 6) - 1,maxWatts:extremes[Int(next() % 6)],voltage:extremes[Int(next() % 6)],maxCurrent:extremes[Int(next() % 6)],hasWinningContract:next() % 2 == 0) }
        let telemetry: ChargingPowerInput? = next() % 4 == 0 ? nil : .init(systemPowerIn:extremes[Int(next() % 6)],systemVoltageIn:extremes[Int(next() % 6)],systemCurrentIn:extremes[Int(next() % 6)],isCharging:next() % 2 == 0,fullyCharged:next() % 2 == 0,notChargingReason:Int(next() % 9))
        let usbNode = next() % 2 == 0, usbSMC = next() % 2 == 0
        let smcPorts = Set((0..<Int(next() % 5)).map { _ in Int(next() % 6) - 1 })
        let old = originalConnectors(cc,chargerData:chargers,chargingPower:telemetry,usbCHoldsNodeContract:usbNode,usbCHasSMCEvidence:usbSMC,smcContractPorts:smcPorts)
        let rust = RustPortPower.connectors(cc,chargers:chargers,telemetry:telemetry,usbNode:usbNode,usbSMC:usbSMC,smcPorts:smcPorts)
        #expect(old.map(\.id) == rust.map(\.id))
        #expect(old.map(\.portType) == rust.map(\.portType))
        #expect(old.map(\.ccConnected) == rust.map(\.ccConnected))
        #expect(old.map(\.power) == rust.map(\.power))
        powered += rust.filter { $0.power != nil }.count
    }
    #expect(powered > 500)
}

@Test func rustConnectorPowerUsesFirstWinningNonUSBContract() {
    let cc = [CCInput(portNumber:1,portType:"MagSafe 3",active:true)]
    let chargers = [ChargerInput(portType:"USB-C",portNumber:1,voltage:11,maxCurrent:12,hasWinningContract:true),
                    ChargerInput(portType:"MagSafe 3",portNumber:1,voltage:21,maxCurrent:22,hasWinningContract:false),
                    ChargerInput(portType:"MagSafe 3",portNumber:1,voltage:31,maxCurrent:32,hasWinningContract:true),
                    ChargerInput(portType:"MagSafe 3",portNumber:1,voltage:41,maxCurrent:42,hasWinningContract:true)]
    let telemetry = ChargingPowerInput(systemPowerIn:6000,systemVoltageIn:20000,systemCurrentIn:300,fullyCharged:true)
    let powered = RustPortPower.connectors(cc,chargers:chargers,telemetry:telemetry,usbNode:false,usbSMC:true,smcPorts:[])
    #expect(powered[0].power?.configuredVoltage == 31)
    #expect(powered[0].power?.configuredCurrent == 32)
    #expect(powered[0].power?.watts == 6)
    #expect(powered[0].power?.contractIsEstimated == false)
    let overridden = RustPortPower.connectors(cc,chargers:chargers,telemetry:telemetry,usbNode:true,usbSMC:true,smcPorts:[1])
    #expect(overridden[0].power == nil)
}

    private func originalConnectors(
        _ ccEntries: [CCInput],
        chargerData: [ChargerInput],
        chargingPower: ChargingPowerInput? = nil,
        usbCHoldsNodeContract: Bool = false,
        usbCHasSMCEvidence: Bool = false,
        smcContractPorts: Set<Int> = []
    ) -> [PortState] {
        ccEntries.map { cc in
            let portType: PortType = cc.portType.lowercased().contains("magsafe") ? .magSafe : .usbC

            // The contract macOS published for this connector, when it did.
            //
            // A WINNING option only. ChargerReader falls back to the highest
            // entry in PowerSourceOptions when there is no winning one, and
            // flags that it did; those volts and amps are what the adapter can
            // offer, not what the two of them agreed on. The view labels this
            // field "Contract", so filling it from the fallback would report a
            // capability as an agreement, which is the same class of mistake as
            // the measured-input values this replaced.
            let negotiated = chargerData.first {
                $0.portType != "USB-C" && $0.portNumber == cc.portNumber && $0.hasWinningContract
            }

            // Show the wattage whenever this connector is the one delivering,
            // NOT only while the battery happens to be charging.
            //
            // The old rule required `isCharging`, so sitting at 100% on MagSafe
            // showed a connected port with no power at all, even though the
            // charger was still carrying the machine's whole running load. That
            // is not an edge case: 312 of 318 corpus machines that are plugged
            // in and not charging still report a positive systemPowerIn, 4 W to
            // 41 W of it. Optimised charging pausing at 80% reads the same way.
            //
            // "Delivering" is simply that USB-C is not, which makes double
            // attribution impossible by construction rather than by
            // observation. Keying it on this connector's OWN contract as well
            // was tempting and wrong: a MagSafe contract only changes the answer
            // when USB-C is taking power too, and in that single case it hands
            // the same watts to two cards. It cannot even be justified as
            // defensive, because `totalWattsIn` sums every incoming port, so
            // the menu bar total would double with it.
            //
            // The 11 of 84 not-charging corpus machines whose MagSafe node
            // publishes no contract are covered here, not by a contract check:
            // nothing says USB-C is taking power, so MagSafe is the only
            // candidate and gets the figure.
            //
            // When the evidence says USB-C is taking power but no figure can be
            // attributed to it (an SMC contract on a machine where a connected
            // MagSafe makes the SMC path decline), both cards stay blank. That
            // is deliberate: the alternative is putting the machine's whole
            // draw against a MagSafe cable that is only plugged in, and a wrong
            // port is worse than no number.
            //
            // A winning contract on THIS connector overrides that SMC evidence,
            // because it is macOS answering about this very port. It cannot
            // double-count: the SMC path declines outright while a MagSafe port
            // is connected, so it never puts a figure on USB-C in this state.
            //
            // Why the battery state is not consulted at all: `ChargingStatus`
            // already carries charging / fullyCharged / onHoldForHealth /
            // notCharging, and the detail view shows it on this very card. The
            // answer to "why isn't it charging" belongs there, not smuggled in
            // by blanking the wattage.
            var power: PortPower?
            let deliveringOnItsOwnEvidence = negotiated != nil || smcContractPorts.contains(cc.portNumber)
            let deliversPower = !usbCHoldsNodeContract
                && (deliveringOnItsOwnEvidence || !usbCHasSMCEvidence)
            if cc.active, deliversPower, let cp = chargingPower, cp.systemPowerIn > 0 {
                power = PortPower(
                    watts: Double(cp.systemPowerIn) / 1000.0,
                    current: cp.systemCurrentIn,
                    voltage: cp.systemVoltageIn,
                    // The negotiated contract, when macOS published one. This
                    // used to repeat the measured input under the "Contract"
                    // label, which reported a measurement as an agreement. With
                    // no contract to show, 0 leaves the row hidden rather than
                    // relabelling the figure already displayed beside it.
                    configuredVoltage: negotiated?.voltage ?? 0,
                    configuredCurrent: negotiated?.maxCurrent ?? 0,
                    vconnCurrent: 0,
                    vconnPower: 0,
                    vconnMaxCurrent: 0,
                    direction: .incoming,
                    // `negotiated` is filtered to hasWinningContract above, so
                    // when it is present it is macOS's own answer, not a guess.
                    contractIsEstimated: false
                )
            }

            return PortState(
                id: 100 + cc.portNumber,
                portType: portType,
                ccConnected: cc.active,
                power: power
            )
        }
    }

