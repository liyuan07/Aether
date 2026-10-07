import AppKit

@MainActor
final class ApplicationWindowMover {
    private final class Request {
        let id = UUID()
        let lease: WindowMoveLease
        let action: ApplicationActionToken
        let display: ShortcutDisplayContext
        var report = WindowMoveReport()
        var completion: ((WindowMoveReport) -> Void)?
        var task: Task<Void, Never>?
        var timeout: Task<Void, Never>?

        init(lease: WindowMoveLease, action: ApplicationActionToken, display: ShortcutDisplayContext,
             completion: @escaping (WindowMoveReport) -> Void) {
            self.lease = lease
            self.action = action
            self.display = display
            self.completion = completion
        }
    }
    private var request: Request?
    private let worker: WindowMoveWorking
    private let screens: @MainActor () -> [PlacementScreen]
    private let permissionGranted: () -> Bool
    private let timeLimit: (WindowCaptureScope) -> TimeInterval
    private let notify: (String, ShortcutDisplayContext) -> Void
    private let clock: @Sendable () -> TimeInterval
    private let waitForTimeout: @Sendable (TimeInterval) async throws -> Void
    var onUndoAvailabilityChanged: ((Bool) -> Void)?

    init(worker: WindowMoveWorking = WindowMoveWorker(),
         screens: @escaping @MainActor () -> [PlacementScreen] = { PlacementScreen.snapshot() },
         permissionGranted: @escaping () -> Bool = { AccessibilityPermission.isGranted },
         timeLimit: @escaping (WindowCaptureScope) -> TimeInterval = { $0.timeLimit },
         clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         waitForTimeout: @escaping @Sendable (TimeInterval) async throws -> Void = { duration in
             try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
         },
         notify: ((String, ShortcutDisplayContext) -> Void)? = nil) {
        self.worker = worker
        self.screens = screens
        self.permissionGranted = permissionGranted
        self.timeLimit = timeLimit
        self.clock = clock
        self.waitForTimeout = waitForTimeout
        // Window placement failures are internal recovery state, not an interruptive
        // notification. Keep the hook injectable for tests and diagnostics, but do not
        // create an on-screen panel during normal application use.
        self.notify = notify ?? { _, _ in }
    }

    func showFeedback(_ message: String, display: ShortcutDisplayContext) {
        notify(message, display)
    }

    func move(pid: Int32, display: ShortcutDisplayContext, scope: WindowCaptureScope,
              restoreMinimized: Bool, action: ApplicationActionToken,
              completion: @escaping (WindowMoveReport) -> Void) {
        cancel()
        guard action.isActive(now: clock()) else { return }
        guard permissionGranted() else {
            var report = WindowMoveReport()
            report.readFailure = .permission
            report.isComplete = true
            notify(report.message!, display)
            completion(report)
            return
        }
        let duration = timeLimit(scope)
        let lease = WindowMoveLease(duration: duration, action: action, clock: clock)
        let request = Request(lease: lease, action: action, display: display, completion: completion)
        if case .undo = scope { request.report.restoringLayout = true }
        if case .appearing = scope { request.report.awaitingWindow = true }
        self.request = request
        let waitForTimeout = self.waitForTimeout
        request.timeout = Task { [weak self, weak request] in
            do { try await waitForTimeout(duration) }
            catch { return }
            guard let self, let request else { return }
            request.report.timedOut = true
            self.finish(request)
        }
        request.task = Task { [weak self, weak request] in
            guard let self, let request else { return }
            while !Task.isCancelled, lease.isActive() {
                let screens = self.screens()
                let (report, canUndo) = await self.worker.step(
                    id: request.id, pid: pid, display: display, scope: scope,
                    restoreMinimized: restoreMinimized, actionID: action.id, screens: screens, lease: lease)
                self.onUndoAvailabilityChanged?(canUndo)
                guard self.request === request else { return }
                request.report = report
                if report.isComplete { self.finish(request); return }
                do { try await Task.sleep(nanoseconds: 20_000_000) }
                catch { break }
            }
            if self.request === request {
                if action.isActive(now: clock()) { request.report.timedOut = true }
                self.finish(request)
            }
        }
    }

    func restoreLastLayout(action: ApplicationActionToken, display: ShortcutDisplayContext) {
        cancel()
        Task { [weak self] in
            guard let self else { return }
            let undo = await self.worker.lastUndo()
            guard action.isActive(now: clock()), let undo else { return }
            self.move(pid: undo.pid, display: display, scope: .undo(undo), restoreMinimized: true,
                      action: action) { _ in }
        }
    }

    func cancel() {
        guard let request else { return }
        request.lease.cancel()
        request.completion = nil
        request.timeout?.cancel()
        request.task?.cancel()
        worker.end(request.id)
        self.request = nil
    }

    private func finish(_ request: Request) {
        guard self.request === request else { return }
        // Close the lease BEFORE activation, including timeout and failure paths.
        request.lease.cancel()
        request.timeout?.cancel()
        request.task?.cancel()
        worker.end(request.id)
        let completion = request.completion
        request.completion = nil
        self.request = nil
        guard request.action.isActive(now: clock()) else { return }
        if let message = request.report.message { notify(message, request.display) }
        completion?(request.report)
    }

    deinit {
        request?.lease.cancel()
        request?.timeout?.cancel()
        request?.task?.cancel()
    }
}
