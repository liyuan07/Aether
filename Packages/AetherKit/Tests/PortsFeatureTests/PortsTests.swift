import Foundation
import Testing
import WhatPortCore
import WhatPortIOKit
@testable import PortsFeature

private func poweredPort(_ id: Int = 1, watts: Double = 2) -> PortState {
    PortState(id: id, portType: .usbC, ccConnected: true, power: PortPower(watts: watts, current: 100, voltage: 20000, configuredVoltage: 0, configuredCurrent: 0, vconnCurrent: 0))
}

@Test func timestampHistoryPrunesAndBreaksMissingReadings() {
    var history = PortHistory()
    let now = Date(timeIntervalSince1970: 1000)
    history.append(ports: [poweredPort()], at: now)
    history.append(ports: [poweredPort()], at: now.addingTimeInterval(1))
    #expect(history.points[1]?.count == 2)
    #expect(history.points[1]?.first?.segment == history.points[1]?.last?.segment)
    history.append(ports: [PortState(id: 1, portType: .usbC)], at: now.addingTimeInterval(2))
    history.append(ports: [poweredPort()], at: now.addingTimeInterval(3))
    #expect(history.points[1]?.first?.segment != history.points[1]?.last?.segment)
    history.prune(at: now.addingTimeInterval(62))
    #expect(history.points[1]?.count == 1)
}

@Test func historySeparatesSessionsAndLongGapsAndPorts() {
    var history = PortHistory()
    let now = Date(timeIntervalSince1970: 1000)
    history.append(ports: [poweredPort(1), poweredPort(2, watts: 8)], at: now)
    history.breakSession()
    history.append(ports: [poweredPort(1)], at: now.addingTimeInterval(1))
    history.append(ports: [poweredPort(1)], at: now.addingTimeInterval(10))
    #expect(Set(history.points[1, default: []].map(\.segment)).count == 3)
    #expect(history.points[2]?.first?.watts == 8)
    history.prune(at: now.addingTimeInterval(71))
    #expect(history.points.isEmpty)
}

@Test func historyBoundsBurstsAndRejectsInvalidPower() {
    var history = PortHistory()
    let now = Date(timeIntervalSince1970: 1000)
    for i in 0..<1000 { history.append(ports: [poweredPort()], at: now.addingTimeInterval(Double(i) / 10000)) }
    #expect(history.points[1]?.count == 1)
    history.append(ports: [poweredPort(watts: .nan)], at: now.addingTimeInterval(1))
    history.append(ports: [poweredPort(watts: -1)], at: now.addingTimeInterval(2))
    #expect(history.points[1]?.count == 1)
}

@Test func unknownPowerAndSpeedAreNotZeroOrGuessed() {
    let idle = PortState(id: 1, portType: .usbC)
    #expect(PortPresentation.power([idle], direction: .incoming) == "不可用")
    var usb = idle
    usb.lane0 = LaneState(transport: .usb, powerLevel: .on, client: nil)
    #expect(PortPresentation.summary(usb).contains("不可用"))
    #expect(!PortPresentation.summary(usb).contains("5 Gbps"))
    #expect(PortPresentation.power([poweredPort()], direction: .incoming) == "无已报告读数")
}

private final class FakeSource: @unchecked Sendable, PortDataSource {
    var starts = 0
    var stops = 0
    var updates: AsyncStream<PortSnapshot>.Continuation?
    var events: AsyncStream<RawPortLifecycleEvent>.Continuation?
    func observePortUpdates() -> AsyncStream<PortSnapshot> { AsyncStream { updates = $0 } }
    func observeLifecycleEvents() -> AsyncStream<RawPortLifecycleEvent> { AsyncStream { events = $0 } }
    func start() async { starts += 1 }
    // Keep continuations alive to simulate callbacks already queued at teardown.
    func stop() { stops += 1 }
}

@MainActor private func settle() async {
    for _ in 0..<30 { await Task.yield() }
}

@Test @MainActor func visibilitySharesSessionAndSleepCreatesFreshSource() async {
    var sources: [FakeSource] = []
    let model = PortsModel { let source = FakeSource(); sources.append(source); return source }
    #expect(sources.isEmpty)
    model.setVisible(.summary, true)
    model.setVisible(.summary, true)
    model.setVisible(.details, true)
    await settle()
    #expect(sources.count == 1)
    #expect(sources[0].starts == 1)
    model.setVisible(.summary, false)
    #expect(sources[0].stops == 0)
    let firstTime = Date(timeIntervalSince1970: 1000)
    sources[0].updates?.yield(PortSnapshot(timestamp: firstTime))
    await settle()
    #expect(model.lastUpdated == firstTime)
    model.setSleeping(true)
    #expect(sources[0].stops == 1)
    #expect(!model.collecting)
    model.setSleeping(false)
    await settle()
    #expect(sources.count == 2)
    #expect(model.lastUpdated == nil)
    let fresh = Date(timeIntervalSince1970: 1010)
    sources[1].updates?.yield(PortSnapshot(timestamp: fresh))
    sources[0].updates?.yield(PortSnapshot(timestamp: firstTime))
    sources[0].events?.yield(RawPortLifecycleEvent(portNumber: 9, isMagSafe: false, signal: .attach))
    await settle()
    #expect(model.lastUpdated == fresh)
    #expect(model.manager.lifecyclePhases[9] == nil)
    model.setVisible(.details, false)
    #expect(sources[1].stops == 1)
    #expect(!model.collecting)
    model.setSleeping(true)
    model.setSleeping(false)
    #expect(sources.count == 2)
    model.stop()
    for source in sources { source.updates?.finish(); source.events?.finish() }
}

@Test @MainActor func stoppingBeforeStartupCannotReviveSession() async {
    let source = FakeSource()
    let model = PortsModel(factory: { source })
    model.setVisible(.details, true)
    model.stop()
    await settle()
    source.updates?.yield(PortSnapshot())
    await settle()
    #expect(!model.collecting)
    #expect(model.lastUpdated == nil)
    #expect(source.stops == 1)
    source.updates?.finish(); source.events?.finish()
}

@Test @MainActor func hidingApplicationPausesWithoutLosingVisibleSurfaces() async {
    var sources: [FakeSource] = []
    let model = PortsModel { let source = FakeSource(); sources.append(source); return source }
    model.setVisible(.details, true)
    await settle()
    model.setApplicationHidden(true)
    #expect(!model.collecting)
    #expect(sources[0].stops == 1)
    model.setApplicationHidden(false)
    await settle()
    #expect(model.collecting)
    #expect(sources.count == 2)
    model.stop()
    for source in sources { source.updates?.finish(); source.events?.finish() }
}

@Test func changingPowerDirectionStartsNewChartSegment() {
    var history = PortHistory()
    let now = Date(timeIntervalSince1970: 1000)
    var port = poweredPort()
    history.append(ports: [port], at: now)
    port.power?.direction = .incoming
    history.append(ports: [port], at: now.addingTimeInterval(1))
    #expect(history.points[1]?.first?.segment != history.points[1]?.last?.segment)
}

// Explicit opt-in: regular tests never need connected hardware.
@Test(.enabled(if: ProcessInfo.processInfo.environment["AETHER_PORTS_HARDWARE_TESTS"] == "1"))
func liveSourceSamplesAndStopsOnThisMachine() async throws {
    let source = LivePortDataSource()
    let stream = source.observePortUpdates()
    let events = source.observeLifecycleEvents()
    _ = events
    let received = HardwareReadings()
    let consumer = Task {
        for await snapshot in stream { await received.add(snapshot) }
    }
    await source.start()
    try await Task.sleep(for: .seconds(2.3))
    source.stop()
    await consumer.value
    let times = await received.timestamps
    #expect(times.count >= 3)
    #expect(zip(times, times.dropFirst()).allSatisfy { $1 >= $0 })
    let count = await received.timestamps.count
    try await Task.sleep(for: .seconds(1.2))
    #expect(await received.timestamps.count == count)
    // A stopped source is terminal; re-opening the UI creates a fresh one.
    await source.start()
    #expect(await received.timestamps.count == count)
}

private actor HardwareReadings {
    var timestamps: [Date] = []
    func add(_ snapshot: PortSnapshot) { timestamps.append(snapshot.timestamp) }
}
