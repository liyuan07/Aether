// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import WhatPortCore

@Test func rustLifecycleMatchesOriginalAcrossNoisyAndRebasedEvents() {
    var native = OriginalLifecycle()
    var rust = PortLifecycleStateMachine()
    var seed: UInt64 = 17
    func next() -> UInt64 { seed = seed &* 6364136223846793005 &+ 1; return seed }
    var now = 1000.0
    let signals: [LifecycleSignalKind] = [.attach, .negotiating, .contractEstablished, .transportReady]
    let steps = [0.0, 0.1, 2.999999, 3.0, 6.0, -100.0, 100.0]
    for _ in 0..<20000 {
        now += steps[Int(next() % UInt64(steps.count))]
        let date = Date(timeIntervalSinceReferenceDate: now)
        let id = Int(next() % 19) - 9
        if next() % 3 != 0 {
            let signal = signals[Int(next() % 4)]
            native.handle(signal, portID: id, at: date)
            rust.handle(signal, portID: id, at: date)
        } else {
            let disconnected: Set<Int> = next() % 2 == 0 ? [id] : []
            let resolved: Set<Int> = next() % 2 == 0 ? [id + 1] : []
            native.reconcile(disconnectedPortIDs: disconnected, resolvedPortIDs: resolved, now: date)
            rust.reconcile(disconnectedPortIDs: disconnected, resolvedPortIDs: resolved, now: date)
        }
        #expect(rust.phases == native.phases)
    }
}
@Test func rustLifecycleCopiesRemainIndependent() {
    var first = PortLifecycleStateMachine()
    first.handle(.attach, portID: Int.min, at: Date(timeIntervalSinceReferenceDate: 100))
    var copy = first
    copy.handle(.negotiating, portID: Int.min, at: Date(timeIntervalSinceReferenceDate: 101))
    #expect(first.phases[Int.min] == .detecting)
    #expect(copy.phases[Int.min] == .negotiating)
    first.handle(.attach, portID: Int.max, at: Date(timeIntervalSinceReferenceDate: 101))
    #expect(copy.phases[Int.max] == nil)
    copy.reconcile(disconnectedPortIDs: [Int.min], resolvedPortIDs: [], now: Date(timeIntervalSinceReferenceDate: 102))
    #expect(copy.phases.isEmpty)
    #expect(first.phases.count == 2)
}

// Independent migration baseline from the original Swift implementation.
private struct OriginalLifecycle {
    // Signals stop firing partway through a connection more often than they
    // run to completion (empirical corpus behaviour), so a phase that has
    // gone quiet this long is assumed abandoned rather than mid-negotiation.
    static let staleTimeout: TimeInterval = 3
    // Ceiling on how long any phase may be shown at all, even under
    // continuous non-progressing signal churn that keeps refreshing
    // lastSignalAt: never let the UI show a stuck phase forever.
    static let maxPhaseDuration: TimeInterval = 6

    private struct Episode {
        var phase: PortLifecyclePhase
        var startedAt: Date
        var lastSignalAt: Date
    }

    private var episodes: [Int: Episode] = [:]

    init() {}

    var phases: [Int: PortLifecyclePhase] {
        episodes.mapValues(\.phase)
    }

    // No backward-clock guard needed here: a `now` that is earlier than a
    // previously stored value only ever shortens or restarts an episode
    // (never extends one), and any resulting negative interval is caught by
    // reconcile's own rebase on its next call.
    mutating func handle(_ signal: LifecycleSignalKind, portID: Int, at now: Date) {
        switch signal {
        case .attach:
            if var episode = episodes[portID] {
                // Forward-only within an episode: a stray attach arriving
                // after negotiating has already started must not downgrade it.
                episode.lastSignalAt = now
                episodes[portID] = episode
            } else {
                episodes[portID] = Episode(phase: .detecting, startedAt: now, lastSignalAt: now)
            }

        case .negotiating, .contractEstablished:
            if var episode = episodes[portID] {
                episode.phase = .negotiating
                episode.lastSignalAt = now
                episodes[portID] = episode
            } else {
                episodes[portID] = Episode(phase: .negotiating, startedAt: now, lastSignalAt: now)
            }

        case .transportReady:
            episodes.removeValue(forKey: portID)
        }
    }

    // Clears tracked ports the caller already knows are done (disconnected or
    // resolved to a live PortState), then expires anything left stale or over
    // the hard ceiling. Called from PortManager.applySnapshot, so the 1s poll
    // (and the debounced connection-notification path feeding it) double as
    // this machine's timeout clock; no separate Timer or Task needed.
    mutating func reconcile(disconnectedPortIDs: Set<Int>, resolvedPortIDs: Set<Int>, now: Date) {
        for portID in disconnectedPortIDs {
            episodes.removeValue(forKey: portID)
        }
        for portID in resolvedPortIDs {
            episodes.removeValue(forKey: portID)
        }

        // Plain interval comparisons: a backwards clock jump produces a
        // negative interval, which simply never satisfies `>= timeout`, so it
        // can't crash. But left alone a negative interval also means the
        // episode keeps reading as fresh for roughly jump+timeout seconds, so
        // a large backward jump can leave a phase visible far longer than any
        // timeout is meant to allow. Date is wall-clock and can jump backward
        // (NTP correction, manual clock change); rebasing startedAt and
        // lastSignalAt to `now` when either interval goes negative bounds the
        // episode to at most one timeout window measured from the corrected
        // clock, same as if it had just started.
        var expired: [Int] = []
        for (portID, episode) in episodes {
            var episode = episode
            if now < episode.lastSignalAt || now < episode.startedAt {
                episode.startedAt = now
                episode.lastSignalAt = now
                episodes[portID] = episode
                continue
            }
            let sinceSignal = now.timeIntervalSince(episode.lastSignalAt)
            let sinceStart = now.timeIntervalSince(episode.startedAt)
            if sinceSignal >= Self.staleTimeout || sinceStart >= Self.maxPhaseDuration {
                expired.append(portID)
            }
        }
        for portID in expired {
            episodes.removeValue(forKey: portID)
        }
    }
}
