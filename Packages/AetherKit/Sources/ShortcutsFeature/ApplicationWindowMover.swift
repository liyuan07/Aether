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
    private let feedback = WindowMoveFeedback()
    var onUndoAvailabilityChanged: ((Bool) -> Void)?

    init(worker: WindowMoveWorking = WindowMoveWorker(),
         screens: @escaping @MainActor () -> [PlacementScreen] = { PlacementScreen.snapshot() },
         permissionGranted: @escaping () -> Bool = { AccessibilityPermission.isGranted },
         timeLimit: @escaping (WindowCaptureScope) -> TimeInterval = { $0.timeLimit },
         notify: ((String, ShortcutDisplayContext) -> Void)? = nil) {
        self.worker = worker
        self.screens = screens
        self.permissionGranted = permissionGranted
        self.timeLimit = timeLimit
        let feedback = feedback
        self.notify = notify ?? { feedback.show($0, display: $1) }
    }

    func showFeedback(_ message: String, display: ShortcutDisplayContext) {
        notify(message, display)
    }

    func move(pid: Int32, display: ShortcutDisplayContext, scope: WindowCaptureScope,
              restoreMinimized: Bool, action: ApplicationActionToken,
              completion: @escaping (WindowMoveReport) -> Void) {
        cancel()
        guard action.isActive() else { return }
        guard permissionGranted() else {
            var report = WindowMoveReport()
            report.readFailure = .permission
            report.isComplete = true
            notify(report.message!, display)
            completion(report)
            return
        }
        let duration = timeLimit(scope)
        let lease = WindowMoveLease(duration: duration, action: action)
        let request = Request(lease: lease, action: action, display: display, completion: completion)
        if case .undo = scope { request.report.restoringLayout = true }
        if case .appearing = scope { request.report.awaitingWindow = true }
        self.request = request
        request.timeout = Task { [weak self, weak request] in
            do { try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000)) }
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
                if action.isActive() { request.report.timedOut = true }
                self.finish(request)
            }
        }
    }

    func restoreLastLayout(action: ApplicationActionToken, display: ShortcutDisplayContext) {
        cancel()
        Task { [weak self] in
            guard let self else { return }
            let undo = await self.worker.lastUndo()
            guard action.isActive(), let undo else { return }
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
        guard request.action.isActive() else { return }
        if let message = request.report.message { notify(message, request.display) }
        completion?(request.report)
    }

    deinit {
        request?.lease.cancel()
        request?.timeout?.cancel()
        request?.task?.cancel()
    }
}

@MainActor
private final class WindowMoveFeedback {
    private var panel: NSPanel?
    private var dismissal: Task<Void, Never>?

    func show(_ text: String, display: ShortcutDisplayContext) {
        dismissal?.cancel()
        panel?.orderOut(nil)
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
        }) ?? NSScreen.main else { return }
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 13)
        label.frame = NSRect(x: 16, y: 12, width: 388, height: 42)
        panel.contentView?.addSubview(label)
        panel.setFrame(NSRect(x: screen.visibleFrame.midX - 210, y: screen.visibleFrame.minY + 40, width: 420, height: 66), display: true)
        panel.orderFrontRegardless()
        self.panel = panel
        dismissal = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.panel?.orderOut(nil)
            self?.panel = nil
        }
    }
}
