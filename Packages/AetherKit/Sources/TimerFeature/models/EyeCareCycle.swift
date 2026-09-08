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

struct EyeCareCycleMachine {
    private(set) var state: EyeCareCycleState = .stopped
    private(set) var awayStartedAt: Date?

    var isActive: Bool {
        state != .stopped
    }

    var isPaused: Bool {
        if case .paused = state { return true }
        return false
    }

    var isBreakVisible: Bool {
        switch state {
        case .resting, .awaitingCompletion:
            return true
        default:
            return false
        }
    }

    var canCompleteRest: Bool {
        state == .awaitingCompletion
    }

    mutating func start(workDuration: TimeInterval, now: Date) {
        awayStartedAt = nil
        state = .working(deadline: now.addingTimeInterval(max(0, workDuration)))
    }

    mutating func stop() {
        awayStartedAt = nil
        state = .stopped
    }

    @discardableResult
    mutating func advanceIfNeeded(now: Date, restDuration: TimeInterval) -> Bool {
        switch state {
        case let .working(deadline) where deadline <= now:
            state = .resting(deadline: now.addingTimeInterval(max(0, restDuration)))
            return true
        case let .resting(deadline) where deadline <= now:
            state = .awaitingCompletion
            return true
        default:
            return false
        }
    }

    @discardableResult
    mutating func pause(reason: EyeCarePauseReason, now: Date) -> Bool {
        switch state {
        case let .working(deadline):
            state = .paused(
                phase: .working,
                remaining: max(0, deadline.timeIntervalSince(now)),
                reason: reason
            )
        case let .resting(deadline):
            state = .paused(
                phase: .resting,
                remaining: max(0, deadline.timeIntervalSince(now)),
                reason: reason
            )
        case .awaitingCompletion:
            state = .paused(phase: .awaitingCompletion, remaining: 0, reason: reason)
        case let .paused(phase, remaining, currentReason):
            guard currentReason == .away, reason == .timerConflict else { return false }
            awayStartedAt = nil
            state = .paused(phase: phase, remaining: remaining, reason: .timerConflict)
        case .stopped:
            return false
        }
        return true
    }

    @discardableResult
    mutating func resume(now: Date) -> Bool {
        guard case let .paused(phase, remaining, _) = state else { return false }
        awayStartedAt = nil

        switch phase {
        case .working:
            state = .working(deadline: now.addingTimeInterval(max(0, remaining)))
        case .resting:
            state = .resting(deadline: now.addingTimeInterval(max(0, remaining)))
        case .awaitingCompletion:
            state = .awaitingCompletion
        }
        return true
    }

    @discardableResult
    mutating func completeRest(workDuration: TimeInterval, now: Date) -> Bool {
        guard canCompleteRest else { return false }
        start(workDuration: workDuration, now: now)
        return true
    }

    @discardableResult
    mutating func beginAway(now: Date) -> Bool {
        guard !isPaused, state != .stopped else { return false }
        awayStartedAt = now
        return pause(reason: .away, now: now)
    }

    @discardableResult
    mutating func returnFromAway(
        now: Date,
        workDuration: TimeInterval,
        restThreshold: TimeInterval
    ) -> Bool {
        guard case let .paused(_, _, reason) = state,
              reason == .away,
              let awayStartedAt else {
            return false
        }

        if now.timeIntervalSince(awayStartedAt) >= max(0, restThreshold) {
            start(workDuration: workDuration, now: now)
        } else {
            _ = resume(now: now)
        }
        return true
    }

    func remainingTime(at now: Date) -> TimeInterval {
        switch state {
        case let .working(deadline), let .resting(deadline):
            return max(0, deadline.timeIntervalSince(now))
        case let .paused(_, remaining, _):
            return max(0, remaining)
        case .stopped, .awaitingCompletion:
            return 0
        }
    }
}
