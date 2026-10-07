import AppKit
import Testing
@testable import ShortcutsFeature

// Wall time controls only the bounded test wait, never the simulated movement deadline.
private final class MovementTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    private var fired = false
    private var waiter: CheckedContinuation<Void, Never>?
    var now: TimeInterval { lock.withLock { value } }
    func wait(_ duration: TimeInterval) async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock {
                if fired { return true }
                waiter = continuation
                return false
            }
            if ready { continuation.resume() }
        }
    }
    func fire() {
        let pending = lock.withLock {
            value = 1; fired = true
            let pending = waiter; waiter = nil
            return pending
        }
        pending?.resume()
    }
}

private final class SuspendedWindowWorker: WindowMoveWorking, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(WindowMoveReport, Bool), Never>?
    private var lease: WindowMoveLease?
    private var started = false
    private var ended = false
    private var completed = false
    var didStart: Bool { lock.withLock { started } }
    var leaseIsActive: Bool { lock.withLock { lease?.isActive() ?? false } }
    private var completeReport: WindowMoveReport {
        var report = WindowMoveReport(); report.hasWindows = true; report.isComplete = true
        return report
    }
    func step(id: UUID, pid: Int32, display: ShortcutDisplayContext, scope: WindowCaptureScope,
              restoreMinimized: Bool, actionID: UUID, screens: [PlacementScreen],
              lease: WindowMoveLease) async -> (WindowMoveReport, Bool) {
        await withCheckedContinuation { continuation in
            let alreadyCompleted = lock.withLock {
                self.lease = lease; started = true
                if completed { return true }
                self.continuation = continuation
                return false
            }
            if alreadyCompleted { continuation.resume(returning: (completeReport, false)) }
        }
    }
    private func wait(forEnd: Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !lock.withLock({ forEnd ? ended : started }) {
            guard ContinuousClock.now < deadline else { throw WaitError.notReached }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
    private enum WaitError: Error { case notReached }
    func waitUntilStarted() async throws { try await wait(forEnd: false) }
    func waitUntilEnded() async throws { try await wait(forEnd: true) }
    func complete() {
        let pending = lock.withLock {
            completed = true
            let pending = continuation; continuation = nil
            return pending
        }
        pending?.resume(returning: (completeReport, false))
    }
    func end(_ id: UUID) { lock.withLock { ended = true } }
    func lastUndo() async -> WindowLayoutUndo? { nil }
}

@Test @MainActor func deadlineClosesMovementBeforeActivationEvenWithAXStillSuspended() async throws {
    let worker = SuspendedWindowWorker()
    let clock = MovementTestClock()
    var reports: [WindowMoveReport] = []
    let mover = ApplicationWindowMover(worker: worker, screens: { [] }, permissionGranted: { true },
                                      timeLimit: { _ in 0.025 }, clock: { clock.now },
                                      waitForTimeout: { await clock.wait($0) }, notify: { _, _ in })
    let action = ApplicationActionToken(sourcePID: 1, targetPID: 2, now: clock.now)
    mover.move(pid: 2, display: ShortcutDisplayContext(displayID: 1), scope: .existing,
               restoreMinimized: true, action: action) { report in
        #expect(!worker.leaseIsActive)
        reports.append(report)
    }
    defer { worker.complete(); clock.fire() }
    try await worker.waitUntilStarted()
    clock.fire()
    try await worker.waitUntilEnded()
    #expect(reports.count == 1 && reports.first?.timedOut == true)
    #expect(action.isActive(now: clock.now))
    worker.complete() // A late AX reply cannot produce a second activation.
    try await Task.sleep(nanoseconds: 10_000_000)
    #expect(reports.count == 1)
}

@Test @MainActor func noAppearingWindowTimeoutDoesNotShowFeedback() async throws {
    let worker = SuspendedWindowWorker()
    let clock = MovementTestClock()
    var messages: [String] = []
    let mover = ApplicationWindowMover(worker: worker, screens: { [] }, permissionGranted: { true },
                                      timeLimit: { _ in 0.025 }, clock: { clock.now },
                                      waitForTimeout: { await clock.wait($0) }, notify: { text, _ in messages.append(text) })
    let action = ApplicationActionToken(sourcePID: 1, targetPID: 2, now: clock.now)
    mover.move(pid: 2, display: ShortcutDisplayContext(displayID: 1), scope: .appearing(excluding: []),
               restoreMinimized: true, action: action) { _ in }
    defer { worker.complete(); clock.fire() }
    try await worker.waitUntilStarted()
    clock.fire()
    try await worker.waitUntilEnded()
    #expect(messages.isEmpty)
}

@Test @MainActor func cancelledIntentCannotActivateFromDeadlineOrLateAXReply() async throws {
    let worker = SuspendedWindowWorker()
    let clock = MovementTestClock()
    var callbacks = 0
    var messages = 0
    let mover = ApplicationWindowMover(worker: worker, screens: { [] }, permissionGranted: { true },
                                      timeLimit: { _ in 0.025 }, clock: { clock.now },
                                      waitForTimeout: { await clock.wait($0) }, notify: { _, _ in messages += 1 })
    let action = ApplicationActionToken(sourcePID: 1, targetPID: 2, now: clock.now)
    mover.move(pid: 2, display: ShortcutDisplayContext(displayID: 1), scope: .existing,
               restoreMinimized: true, action: action) { _ in callbacks += 1 }
    defer { worker.complete(); clock.fire() }
    try await worker.waitUntilStarted()
    action.cancel()
    clock.fire()
    try await worker.waitUntilEnded()
    worker.complete()
    try await Task.sleep(nanoseconds: 10_000_000)
    #expect(callbacks == 0 && messages == 0)
    #expect(!worker.leaseIsActive)
}

@Test @MainActor func permissionFailureFallsBackOnceWithoutTouchingWindowWorker() {
    let worker = SuspendedWindowWorker()
    var reports: [WindowMoveReport] = []
    var messages: [String] = []
    let mover = ApplicationWindowMover(worker: worker, screens: { [] }, permissionGranted: { false },
                                      notify: { text, _ in messages.append(text) })
    mover.move(pid: 2, display: ShortcutDisplayContext(displayID: 1), scope: .existing,
               restoreMinimized: true, action: ApplicationActionToken(sourcePID: 1, targetPID: 2)) {
        reports.append($0)
    }
    #expect(reports.count == 1 && messages.count == 1)
    #expect(reports[0].readFailure == .permission)
    #expect(!worker.leaseIsActive)
}


@Test @MainActor func deadlineCanCloseBeforeWindowWorkerStarts() async throws {
    let worker = SuspendedWindowWorker()
    let clock = MovementTestClock()
    var reports: [WindowMoveReport] = []
    let mover = ApplicationWindowMover(worker: worker, screens: { [] }, permissionGranted: { true },
        timeLimit: { _ in 0.025 }, clock: { clock.now }, waitForTimeout: { await clock.wait($0) },
        notify: { _, _ in })
    let action = ApplicationActionToken(sourcePID: 1, targetPID: 2, now: clock.now)
    mover.move(pid: 2, display: ShortcutDisplayContext(displayID: 1), scope: .existing,
        restoreMinimized: true, action: action) { reports.append($0) }
    // Expire before yielding the main actor to either movement or timeout tasks.
    clock.fire()
    defer { worker.complete(); clock.fire() }
    try await worker.waitUntilEnded()
    #expect(!worker.didStart)
    #expect(reports.count == 1 && reports.first?.timedOut == true)
}
