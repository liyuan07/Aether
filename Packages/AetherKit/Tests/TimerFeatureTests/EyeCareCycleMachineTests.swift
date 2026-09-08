/*
 * package counter
 * Copyright (C) 2026 Li Yuan and Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import XCTest
@testable import TimerFeature

final class EyeCareCycleMachineTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000_000)

    func testFullCycleRequiresRestToFinishAndExplicitCompletion() {
        var machine = EyeCareCycleMachine()
        machine.start(workDuration: 1_200, now: start)

        XCTAssertEqual(machine.remainingTime(at: start.addingTimeInterval(300)), 900, accuracy: 0.001)
        XCTAssertFalse(machine.advanceIfNeeded(now: start.addingTimeInterval(1_199), restDuration: 20))
        XCTAssertTrue(machine.advanceIfNeeded(now: start.addingTimeInterval(1_200), restDuration: 20))
        XCTAssertTrue(machine.isBreakVisible)
        XCTAssertFalse(machine.canCompleteRest)
        XCTAssertFalse(machine.completeRest(workDuration: 1_200, now: start.addingTimeInterval(1_205)))

        XCTAssertFalse(machine.advanceIfNeeded(now: start.addingTimeInterval(1_219), restDuration: 20))
        XCTAssertTrue(machine.advanceIfNeeded(now: start.addingTimeInterval(1_220), restDuration: 20))
        XCTAssertEqual(machine.state, .awaitingCompletion)
        XCTAssertTrue(machine.canCompleteRest)

        let nextStart = start.addingTimeInterval(1_230)
        XCTAssertTrue(machine.completeRest(workDuration: 1_200, now: nextStart))
        XCTAssertEqual(machine.state, .working(deadline: nextStart.addingTimeInterval(1_200)))
    }

    func testUserPauseFreezesRemainingTimeUntilManualResume() {
        var machine = EyeCareCycleMachine()
        machine.start(workDuration: 100, now: start)

        XCTAssertTrue(machine.pause(reason: .user, now: start.addingTimeInterval(30)))
        XCTAssertEqual(
            machine.state,
            .paused(phase: .working, remaining: 70, reason: .user)
        )
        XCTAssertFalse(machine.advanceIfNeeded(now: start.addingTimeInterval(500), restDuration: 20))

        let resumeDate = start.addingTimeInterval(50)
        XCTAssertTrue(machine.resume(now: resumeDate))
        XCTAssertEqual(machine.state, .working(deadline: resumeDate.addingTimeInterval(70)))
    }

    func testNewSettingsApplyWhenTheNextPhaseBegins() {
        var machine = EyeCareCycleMachine()
        machine.start(workDuration: 1_200, now: start)

        let workEnd = start.addingTimeInterval(1_200)
        XCTAssertTrue(machine.advanceIfNeeded(now: workEnd, restDuration: 60))
        XCTAssertEqual(machine.state, .resting(deadline: workEnd.addingTimeInterval(60)))

        let restEnd = workEnd.addingTimeInterval(60)
        XCTAssertTrue(machine.advanceIfNeeded(now: restEnd, restDuration: 60))
        XCTAssertTrue(machine.completeRest(workDuration: 600, now: restEnd))
        XCTAssertEqual(machine.state, .working(deadline: restEnd.addingTimeInterval(600)))
    }

    func testRestCanBePausedResumedAndStoppedWithoutLosingTime() {
        var machine = EyeCareCycleMachine()
        machine.start(workDuration: 10, now: start)
        let workEnd = start.addingTimeInterval(10)
        XCTAssertTrue(machine.advanceIfNeeded(now: workEnd, restDuration: 20))

        let pauseDate = workEnd.addingTimeInterval(5)
        XCTAssertTrue(machine.pause(reason: .user, now: pauseDate))
        XCTAssertEqual(
            machine.state,
            .paused(phase: .resting, remaining: 15, reason: .user)
        )

        let resumeDate = pauseDate.addingTimeInterval(100)
        XCTAssertTrue(machine.resume(now: resumeDate))
        XCTAssertEqual(machine.state, .resting(deadline: resumeDate.addingTimeInterval(15)))

        machine.stop()
        XCTAssertEqual(machine.state, .stopped)
        XCTAssertFalse(machine.isBreakVisible)
    }

    func testShortTimeAwayResumesTheFrozenPhase() {
        var machine = EyeCareCycleMachine()
        machine.start(workDuration: 1_200, now: start)

        let awayDate = start.addingTimeInterval(300)
        XCTAssertTrue(machine.beginAway(now: awayDate))
        XCTAssertEqual(
            machine.state,
            .paused(phase: .working, remaining: 900, reason: .away)
        )

        let returnDate = awayDate.addingTimeInterval(10)
        XCTAssertTrue(machine.returnFromAway(
            now: returnDate,
            workDuration: 1_200,
            restThreshold: 20
        ))
        XCTAssertEqual(machine.state, .working(deadline: returnDate.addingTimeInterval(900)))
    }

    func testEnoughTimeAwayStartsAFreshWorkCycle() {
        var machine = EyeCareCycleMachine()
        machine.start(workDuration: 1_200, now: start)

        let awayDate = start.addingTimeInterval(300)
        XCTAssertTrue(machine.beginAway(now: awayDate))

        let returnDate = awayDate.addingTimeInterval(20)
        XCTAssertTrue(machine.returnFromAway(
            now: returnDate,
            workDuration: 900,
            restThreshold: 20
        ))
        XCTAssertEqual(machine.state, .working(deadline: returnDate.addingTimeInterval(900)))
    }

    func testUserPausedCycleDoesNotResumeAfterTimeAway() {
        var machine = EyeCareCycleMachine()
        machine.start(workDuration: 1_200, now: start)
        XCTAssertTrue(machine.pause(reason: .user, now: start.addingTimeInterval(200)))
        let pausedState = machine.state

        XCTAssertFalse(machine.beginAway(now: start.addingTimeInterval(300)))
        XCTAssertFalse(machine.returnFromAway(
            now: start.addingTimeInterval(600),
            workDuration: 1_200,
            restThreshold: 20
        ))
        XCTAssertEqual(machine.state, pausedState)
    }

    func testTimerConflictDuringAwayPreventsAutomaticResume() {
        var machine = EyeCareCycleMachine()
        machine.start(workDuration: 1_200, now: start)
        XCTAssertTrue(machine.beginAway(now: start.addingTimeInterval(100)))
        XCTAssertTrue(machine.pause(reason: .timerConflict, now: start.addingTimeInterval(105)))

        XCTAssertEqual(
            machine.state,
            .paused(phase: .working, remaining: 1_100, reason: .timerConflict)
        )
        XCTAssertFalse(machine.returnFromAway(
            now: start.addingTimeInterval(500),
            workDuration: 1_200,
            restThreshold: 20
        ))
    }

    func testAwayLongEnoughAlsoCompletesAnAwaitingBreak() {
        var machine = EyeCareCycleMachine()
        machine.start(workDuration: 1, now: start)
        XCTAssertTrue(machine.advanceIfNeeded(now: start.addingTimeInterval(1), restDuration: 20))
        XCTAssertTrue(machine.advanceIfNeeded(now: start.addingTimeInterval(21), restDuration: 20))
        XCTAssertEqual(machine.state, .awaitingCompletion)

        let awayDate = start.addingTimeInterval(30)
        XCTAssertTrue(machine.beginAway(now: awayDate))
        let returnDate = awayDate.addingTimeInterval(20)
        XCTAssertTrue(machine.returnFromAway(
            now: returnDate,
            workDuration: 1_200,
            restThreshold: 20
        ))
        XCTAssertEqual(machine.state, .working(deadline: returnDate.addingTimeInterval(1_200)))
    }

    func testNotchPresentationFollowsEyeCarePhaseAndConflictOwnership() {
        let working = EyeCareCycleState.working(deadline: start.addingTimeInterval(1_200))
        let userPausedWork = EyeCareCycleState.paused(
            phase: .working,
            remaining: 600,
            reason: .user
        )
        let conflictPausedWork = EyeCareCycleState.paused(
            phase: .working,
            remaining: 600,
            reason: .timerConflict
        )
        let awayPausedRest = EyeCareCycleState.paused(
            phase: .resting,
            remaining: 10,
            reason: .away
        )

        XCTAssertTrue(working.showsWorkingNotchActivity)
        XCTAssertTrue(userPausedWork.showsWorkingNotchActivity)
        XCTAssertFalse(conflictPausedWork.showsWorkingNotchActivity)
        XCTAssertFalse(EyeCareCycleState.resting(deadline: start).showsWorkingNotchActivity)
        XCTAssertFalse(EyeCareCycleState.awaitingCompletion.showsWorkingNotchActivity)

        XCTAssertTrue(working.suppressesRetainedTimerInNotch)
        XCTAssertTrue(EyeCareCycleState.resting(deadline: start).suppressesRetainedTimerInNotch)
        XCTAssertTrue(EyeCareCycleState.awaitingCompletion.suppressesRetainedTimerInNotch)
        XCTAssertTrue(awayPausedRest.suppressesRetainedTimerInNotch)
        XCTAssertFalse(conflictPausedWork.suppressesRetainedTimerInNotch)
        XCTAssertFalse(EyeCareCycleState.stopped.suppressesRetainedTimerInNotch)
    }
}
