/*
 * package counter
 * Derived from Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import Foundation
import CAetherCore

enum EyeCarePhase: Equatable {
    case working
    case resting
    case awaitingCompletion
}

enum EyeCarePauseReason: Equatable {
    case user
    case timerConflict
    case away
}

enum EyeCareCycleState: Equatable {
    case stopped
    case working(deadline: Date)
    case resting(deadline: Date)
    case awaitingCompletion
    case paused(phase: EyeCarePhase, remaining: TimeInterval, reason: EyeCarePauseReason)

    var showsWorkingNotchActivity: Bool {
        switch self {
        case .working:
            return true
        case let .paused(phase, _, reason):
            return phase == .working && reason != .timerConflict
        case .stopped, .resting, .awaitingCompletion:
            return false
        }
    }

    var suppressesRetainedTimerInNotch: Bool {
        switch self {
        case .stopped:
            return false
        case let .paused(_, _, reason):
            return reason != .timerConflict
        case .working, .resting, .awaitingCompletion:
            return true
        }
    }
}

/// Value state and transitions live in Rust; Date and presentation enums stay native.
struct EyeCareCycleMachine {
    private var core = AetherEyeCare()

    var state: EyeCareCycleState {
        switch core.phase {
        case 1: return .working(deadline: Date(timeIntervalSinceReferenceDate: core.value))
        case 2: return .resting(deadline: Date(timeIntervalSinceReferenceDate: core.value))
        case 3: return .awaitingCompletion
        case 4:
            let phase: EyeCarePhase = core.paused_phase == 1 ? .working : core.paused_phase == 2 ? .resting : .awaitingCompletion
            let reason: EyeCarePauseReason = core.reason == 0 ? .user : core.reason == 1 ? .timerConflict : .away
            return .paused(phase: phase, remaining: core.value, reason: reason)
        default: return .stopped
        }
    }
    var awayStartedAt: Date? {
        core.away_active == 0 ? nil : Date(timeIntervalSinceReferenceDate: core.away_date)
    }
    var isActive: Bool { core.phase != 0 }
    var isPaused: Bool { core.phase == 4 }
    var isBreakVisible: Bool { core.phase == 2 || core.phase == 3 }
    var canCompleteRest: Bool { core.phase == 3 }

    mutating func start(workDuration: TimeInterval, now: Date) {
        _ = event(0, now: now, duration: workDuration)
    }
    mutating func stop() { _ = event(1, now: Date(timeIntervalSinceReferenceDate: 0)) }
    @discardableResult
    mutating func advanceIfNeeded(now: Date, restDuration: TimeInterval) -> Bool {
        event(2, now: now, duration: restDuration)
    }
    @discardableResult
    mutating func pause(reason: EyeCarePauseReason, now: Date) -> Bool {
        event(3, now: now, reason: reason == .user ? 0 : reason == .timerConflict ? 1 : 2)
    }
    @discardableResult
    mutating func resume(now: Date) -> Bool { event(4, now: now) }
    @discardableResult
    mutating func completeRest(workDuration: TimeInterval, now: Date) -> Bool {
        event(5, now: now, duration: workDuration)
    }
    @discardableResult
    mutating func beginAway(now: Date) -> Bool { event(6, now: now) }
    @discardableResult
    mutating func returnFromAway(now: Date, workDuration: TimeInterval, restThreshold: TimeInterval) -> Bool {
        event(7, now: now, duration: workDuration, threshold: restThreshold)
    }
    func remainingTime(at now: Date) -> TimeInterval {
        aether_eyecare_remaining(core, now.timeIntervalSinceReferenceDate)
    }
    private mutating func event(_ event: UInt32, now: Date, duration: Double = 0, threshold: Double = 0, reason: UInt32 = 0) -> Bool {
        core = aether_eyecare_event(core, event, now.timeIntervalSinceReferenceDate, duration, threshold, reason)
        return core.changed != 0
    }
}
