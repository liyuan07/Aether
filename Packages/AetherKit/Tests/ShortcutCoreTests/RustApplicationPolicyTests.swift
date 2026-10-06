// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import ShortcutCore

@Test func rustApplicationOrderingMatchesOriginalAcrossFiveThousandEdits() {
    var seed: UInt64 = 204
    func next() -> UInt64 { seed = seed &* 6364136223846793005 &+ 1; return seed >> 32 }
    let strings = ["","A","a","É","E\u{301}","合成","missing","x\0y"]
    for _ in 0..<5000 {
        let apps = (0..<Int(next() % 10)).map { i in RegisteredApplication(bundleIdentifier:strings[Int(next() % 8)],displayName:"synthetic-\(i)",applicationPath:"/synthetic/\(i).app",initial:"S") }
        let prefs = (0..<Int(next() % 12)).map { _ in strings[Int(next() % 8)] }
        let old = OriginalOrder.ordered(apps,preferredBundleIdentifiers:prefs)
        let rust = ApplicationOrderResolver.ordered(apps,preferredBundleIdentifiers:prefs)
        #expect(old == rust)
        #expect(old.map { Array($0.bundleIdentifier.utf8) } == rust.map { Array($0.bundleIdentifier.utf8) })
        let offsets = IndexSet((0..<Int(next() % 5)).map { _ in Int(next() % UInt64(old.count + 2)) })
        let destination = Int(next() % UInt64(old.count + 3)) - 1
        let oldMove = OriginalOrder.updatingPreference(prefs,availableApplications:apps,moving:offsets,toOffset:destination)
        let rustMove = ApplicationOrderResolver.updatingPreference(prefs,availableApplications:apps,moving:offsets,toOffset:destination)
        #expect(oldMove == rustMove)
        #expect(oldMove?.map { Array($0.utf8) } == rustMove?.map { Array($0.utf8) })
    }
}

@Test func rustABCGuardMatchesOriginalAcrossTwentyThousandEvents() {
    var seed: UInt64 = 209
    func next() -> UInt64 { seed = seed &* 6364136223846793005 &+ 1; return seed >> 32 }
    var old = OriginalABC(), rust = ABCSwitchGuardState()
    var uptime: Double = 0
    let special = [Double.nan,Double.infinity,-Double.infinity,0,5,5.00001,-1]
    for _ in 0..<20000 {
        uptime += Double(next() % 20) / 10
        let now = next() % 20 == 0 ? special[Int(next() % 7)] : uptime
        switch next() % 8 {
        case 0: old.reset(); rust.reset()
        case 1,2: old.physicalInputSwitchKeyWasPressed(at:now); rust.physicalInputSwitchKeyWasPressed(at:now)
        default:
            let block = next() % 2 == 0, abc = next() % 5 != 0, observe = next() % 2 == 0
            #expect(old.decision(blockAutomaticABC:block,switchedToABC:abc,canObservePhysicalKey:observe,uptime:now) == rust.decision(blockAutomaticABC:block,switchedToABC:abc,canObservePhysicalKey:observe,uptime:now))
        }
        #expect(old.isManualABCSessionActive == rust.isManualABCSessionActive)
    }
}

private enum OriginalOrder {
    public static func ordered(
        _ applications: [RegisteredApplication],
        preferredBundleIdentifiers: [String]
    ) -> [RegisteredApplication] {
        var applicationsByBundleIdentifier: [String: RegisteredApplication] = [:]
        for application in applications where applicationsByBundleIdentifier[application.bundleIdentifier] == nil {
            applicationsByBundleIdentifier[application.bundleIdentifier] = application
        }
        let preferred = preferredBundleIdentifiers.compactMap { applicationsByBundleIdentifier[$0] }
        let preferredIdentifiers = Set(preferred.map(\.bundleIdentifier))
        var appendedIdentifiers = preferredIdentifiers
        return preferred + applications.filter { appendedIdentifiers.insert($0.bundleIdentifier).inserted }
    }

    public static func updatingPreference(
        _ existingPreference: [String],
        availableApplications: [RegisteredApplication],
        moving offsets: IndexSet,
        toOffset destination: Int
    ) -> [String]? {
        let orderedApplications = ordered(
            availableApplications,
            preferredBundleIdentifiers: existingPreference
        )
        guard !offsets.isEmpty,
              offsets.allSatisfy(orderedApplications.indices.contains),
              destination >= 0,
              destination <= orderedApplications.count
        else { return nil }

        var reordered = orderedApplications.map(\.bundleIdentifier)
        let movingIdentifiers = offsets.map { reordered[$0] }
        let removedBeforeDestination = offsets.filter { $0 < destination }.count
        let insertionIndex = destination - removedBeforeDestination
        for index in offsets.reversed() { reordered.remove(at: index) }
        reordered.insert(contentsOf: movingIdentifiers, at: insertionIndex)

        var seen = Set<String>()
        let normalizedPreference = existingPreference.filter { seen.insert($0).inserted }
        let availableIdentifiers = Set(reordered)
        var reorderedIterator = reordered.makeIterator()
        var result = normalizedPreference.map { identifier in
            availableIdentifiers.contains(identifier) ? reorderedIterator.next()! : identifier
        }
        let existingIdentifiers = Set(normalizedPreference)
        result.append(contentsOf: reordered.filter { !existingIdentifiers.contains($0) })
        return result
    }
}

private struct OriginalABC: Equatable, Sendable {
    public static let manualAuthorizationDuration: TimeInterval = 5

    public private(set) var isManualABCSessionActive = false
    private var physicalInputSwitchKeyPressedAt: TimeInterval?

    public init() {}

    public mutating func physicalInputSwitchKeyWasPressed(at uptime: TimeInterval) {
        physicalInputSwitchKeyPressedAt = uptime
    }

    public mutating func decision(
        blockAutomaticABC: Bool,
        switchedToABC: Bool,
        canObservePhysicalKey: Bool,
        uptime: TimeInterval
    ) -> ABCSwitchDecision {
        guard switchedToABC else {
            isManualABCSessionActive = false
            physicalInputSwitchKeyPressedAt = nil
            return .ignore
        }
        guard blockAutomaticABC, canObservePhysicalKey else { return .ignore }
        if isManualABCSessionActive { return .allowManualSwitch }
        if let pressedAt = physicalInputSwitchKeyPressedAt,
           uptime >= pressedAt,
           uptime - pressedAt <= Self.manualAuthorizationDuration {
            physicalInputSwitchKeyPressedAt = nil
            isManualABCSessionActive = true
            return .allowManualSwitch
        }
        physicalInputSwitchKeyPressedAt = nil
        return .restoreDoubao
    }

    public mutating func reset() {
        isManualABCSessionActive = false
        physicalInputSwitchKeyPressedAt = nil
    }
}

