import AppKit

protocol WindowMoveWorking: Sendable {
    func step(id: UUID, pid: Int32, display: ShortcutDisplayContext, scope: WindowCaptureScope,
              restoreMinimized: Bool, actionID: UUID, screens: [PlacementScreen],
              lease: WindowMoveLease) async -> (WindowMoveReport, Bool)
    func end(_ id: UUID)
    func lastUndo() async -> WindowLayoutUndo?
}

/// The only cross-thread owner of AX/session/history state; every access is confined to queue.
final class WindowMoveWorker: WindowMoveWorking, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.liyuan.aether.window-movement", qos: .userInitiated)
    private let history = WindowLayoutHistory()
    private lazy var access = AXWindowAccess(history: history)
    private var sessions: [UUID: WindowMoveSession] = [:]

    func step(id: UUID, pid: Int32, display: ShortcutDisplayContext, scope: WindowCaptureScope,
              restoreMinimized: Bool, actionID: UUID, screens: [PlacementScreen],
              lease: WindowMoveLease) async -> (WindowMoveReport, Bool) {
        await withCheckedContinuation { continuation in
            queue.async {
                let session = self.sessions[id] ?? WindowMoveSession(
                    access: self.access, history: self.history, pid: pid, targetID: display.displayID,
                    scope: scope, restoreMinimized: restoreMinimized, operationID: actionID)
                self.sessions[id] = session
                let report = session.step(screens: screens, lease: lease)
                continuation.resume(returning: (report, self.history.hasUndo))
            }
        }
    }

    func end(_ id: UUID) { queue.async { self.sessions.removeValue(forKey: id) } }

    func lastUndo() async -> WindowLayoutUndo? {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.history.undo) }
        }
    }
}
