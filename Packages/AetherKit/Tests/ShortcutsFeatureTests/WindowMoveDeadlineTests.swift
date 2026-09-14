import AppKit
import Testing
@testable import ShortcutsFeature

private final class SuspendedWindowWorker: WindowMoveWorking, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(WindowMoveReport, Bool), Never>?
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var lease: WindowMoveLease?
    var leaseIsActive: Bool { lock.withLock { lease?.isActive() ?? false } }

    func step(id: UUID, pid: Int32, display: ShortcutDisplayContext, scope: WindowCaptureScope,
              restoreMinimized: Bool, actionID: UUID, screens: [PlacementScreen],
              lease: WindowMoveLease) async -> (WindowMoveReport, Bool) {
        await withCheckedContinuation { continuation in
            let waiters = lock.withLock {
                self.continuation = continuation
                self.lease = lease
                let waiters = startedWaiters
                startedWaiters.removeAll()
                return waiters
            }
            waiters.forEach { $0.resume() }
        }
    }
    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            let started = lock.withLock {
                if lease != nil { return true }
                startedWaiters.append(continuation)
                return false
            }
            if started { continuation.resume() }
        }
    }
    func complete() {
        let pending = lock.withLock {
            let result = continuation
            continuation = nil
            return result
        }
        var report = WindowMoveReport()
        report.hasWindows = true
        report.isComplete = true
        pending?.resume(returning: (report, false))
    }
    func end(_ id: UUID) {}
    func lastUndo() async -> WindowLayoutUndo? { nil }
}

@Test @MainActor func deadlineClosesMovementBeforeActivationEvenWithAXStillSuspended() async throws {
    let worker = SuspendedWindowWorker()
    var reports: [WindowMoveReport] = []
    let mover = ApplicationWindowMover(worker: worker, screens: { [] }, permissionGranted: { true },
                                      timeLimit: { _ in 0.025 }, notify: { _, _ in })
    let action = ApplicationActionToken(sourcePID: 1, targetPID: 2)
    mover.move(pid: 2, display: ShortcutDisplayContext(displayID: 1), scope: .existing,
               restoreMinimized: true, action: action) { report in
        #expect(!worker.leaseIsActive)
        reports.append(report)
    }
    await worker.waitUntilStarted()
    defer { worker.complete() }
    try await Task.sleep(nanoseconds: 80_000_000)
    #expect(reports.count == 1 && reports.first?.timedOut == true)
    #expect(action.isActive())
    worker.complete() // A late AX reply cannot produce a second activation.
    try await Task.sleep(nanoseconds: 10_000_000)
    #expect(reports.count == 1)
}

@Test @MainActor func cancelledIntentCannotActivateFromDeadlineOrLateAXReply() async throws {
    let worker = SuspendedWindowWorker()
    var callbacks = 0
    var messages = 0
    let mover = ApplicationWindowMover(worker: worker, screens: { [] }, permissionGranted: { true },
                                      timeLimit: { _ in 0.025 }, notify: { _, _ in messages += 1 })
    let action = ApplicationActionToken(sourcePID: 1, targetPID: 2)
    mover.move(pid: 2, display: ShortcutDisplayContext(displayID: 1), scope: .existing,
               restoreMinimized: true, action: action) { _ in callbacks += 1 }
    await worker.waitUntilStarted()
    defer { worker.complete() }
    action.cancel()
    try await Task.sleep(nanoseconds: 80_000_000)
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
