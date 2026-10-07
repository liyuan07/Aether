// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
// Frozen ad24e1a session decisions; native protocols and already-migrated geometry/history are shared.
import AppKit
@testable import ShortcutsFeature

/// A frozen cohort prevents a shortcut from adopting the user's later windows.
final class ReferenceWindowMoveSession {
    private struct Progress {
        let original: MovableWindow
        let source: PlacementScreen
        let target: PlacementScreen
        var desired: CGRect
        let minimized: Bool
        var attempts = 0
        var nextAttempt: TimeInterval = 0
        var recorded = false
        var complete = false
        var failed = false
        var closed = false
    }
    private let access: WindowAccess
    private let history: WindowLayoutHistory
    private let pid: Int32
    private let targetID: CGDirectDisplayID
    private let scope: WindowCaptureScope
    private let restoreMinimized: Bool
    private let operationID: UUID
    private var firstAppearance: TimeInterval?
    private var frozen = false
    private var progress: [Progress] = []
    private var preferredFocus: Int?
    private var unreadableWindows = 0
    private(set) var report = WindowMoveReport()

    init(access: WindowAccess, history: WindowLayoutHistory, pid: Int32,
         targetID: CGDirectDisplayID, scope: WindowCaptureScope,
         restoreMinimized: Bool, operationID: UUID) {
        self.access = access
        self.history = history
        self.pid = pid
        self.targetID = targetID
        self.scope = scope
        self.restoreMinimized = restoreMinimized
        self.operationID = operationID
        if case .undo = scope { report.restoringLayout = true }
        if case .appearing = scope { report.awaitingWindow = true }
    }

    func step(screens: [PlacementScreen], lease: WindowMoveLease,
              now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> WindowMoveReport {
        guard lease.isActive(), !report.isComplete else { return report }
        guard screens.contains(where: { $0.id == targetID }) || isUndo else {
            report.displayDisconnected = true
            report.isComplete = true
            return report
        }
        let windows: [MovableWindow]
        switch access.windows(pid: pid, lease: lease) {
        case let .success(value): windows = value
        case let .failure(error):
            report.readFailure = error
            report.isComplete = true
            return report
        }
        guard lease.isActive() else { return report }
        report.hasWindows = !windows.isEmpty
        report.knownIDs = Set(windows.map(\.id))
        if !frozen {
            let candidates: [MovableWindow]
            switch scope {
            case .existing: candidates = windows
            case let .appearing(excluded):
                candidates = windows.filter { !excluded.contains($0.id) }
                guard candidates.contains(where: { $0.isStandard }) else { return report }
                if firstAppearance == nil { firstAppearance = now }
                // A short, fixed collection interval for startup bursts, never extended by new windows.
                guard now - firstAppearance! >= 0.12 else { return report }
            case let .undo(batch): candidates = windows.filter { batch.layouts[$0.id] != nil }
            }
            freeze(candidates, screens: screens)
        }
        for index in progress.indices {
            guard lease.isActive() else { return report }
            if progress[index].complete || progress[index].failed { continue }
            guard let current = windows.first(where: { $0.id == progress[index].original.id }) else {
                progress[index].complete = true
                progress[index].closed = true
                continue
            }
            if current.isFullScreen {
                progress[index].complete = true
                progress[index].closed = true
                continue
            }
            guard screens.contains(where: { $0.id == progress[index].target.id }) else {
                progress[index].failed = true
                report.displayDisconnected = true
                continue
            }
            let positioned = WindowPlacement.approximatelyEqual(current.frame, progress[index].desired)
            let restored = current.isMinimized == progress[index].minimized
            if positioned && restored { progress[index].complete = true; continue }
            guard now >= progress[index].nextAttempt else { continue }
            guard progress[index].attempts < 3 else { progress[index].failed = true; continue }
            progress[index].attempts += 1
            progress[index].nextAttempt = now + 0.04
            var changed = false
            if !positioned {
                if let accepted = access.setFrame(progress[index].desired, of: current.id, lease: lease) {
                    progress[index].desired = WindowPlacement.destination(
                        for: accepted, source: progress[index].target.visibleFrame,
                        target: progress[index].target.visibleFrame, resizable: false)
                    changed = true
                }
            } else if !restored {
                changed = access.setMinimized(progress[index].minimized, of: current.id, lease: lease)
            }
            if changed, !progress[index].recorded, !isUndo {
                history.record(progress[index].original, screen: progress[index].source, operationID: operationID)
                progress[index].recorded = true
            }
            // Verify the frame before restoring a minimized window; verify restoration on the next scan.
        }
        report.moved = progress.filter {
            $0.complete && !$0.closed && !WindowPlacement.approximatelyEqual($0.original.frame, $0.desired)
        }.count
        report.failed = unreadableWindows + progress.filter(\.failed).count
        if progress.allSatisfy({ $0.complete || $0.failed }) {
            if isUndo {
                history.restored(Set(progress.filter { $0.complete }.map { $0.original.id }))
            } else {
                let available = progress.filter { $0.complete && !$0.closed && !$0.minimized }
                if let item = available.first(where: { $0.original.id == preferredFocus }) ?? available.first,
                   lease.isActive() {
                    report.focusFailed = !access.focus(item.original.id, lease: lease)
                }
            }
            report.isComplete = true
        }
        return report
    }

    private var isUndo: Bool { if case .undo = scope { return true }; return false }

    private func freeze(_ windows: [MovableWindow], screens: [PlacementScreen]) {
        frozen = true
        report.awaitingWindow = false
        preferredFocus = WindowFocusSelection.choose(windows, targetID: targetID, screens: screens,
                                                     restoreMinimized: restoreMinimized)
        var occupied = windows.filter {
            $0.isStandard && !$0.isFullScreen && WindowPlacement.source(for: $0.frame, screens: screens)?.id == targetID
        }.map(\.frame)
        for window in windows {
            guard window.isStandard else { continue }
            if window.isFullScreen { report.skippedFullScreen += 1; continue }
            if !isUndo, window.isMinimized, !restoreMinimized { report.skippedMinimized += 1; continue }
            guard window.frame.width > 0, window.frame.height > 0 else { unreadableWindows += 1; continue }
            guard let source = WindowPlacement.source(for: window.frame, screens: screens) else { continue }
            let target: PlacementScreen
            var desired: CGRect
            let minimized: Bool
            if case let .undo(batch) = scope {
                guard let saved = batch.layouts[window.id],
                      let screen = screens.first(where: { $0.id == saved.screen.id }) else {
                    report.displayDisconnected = true
                    continue
                }
                target = screen
                desired = WindowPlacement.destination(for: saved.window.frame, source: saved.screen.visibleFrame,
                                                      target: target.visibleFrame, resizable: window.isResizable)
                minimized = saved.window.isMinimized
            } else {
                guard let screen = screens.first(where: { $0.id == targetID }) else { continue }
                target = screen
                minimized = false
                if source.id == target.id { desired = window.frame }
                else {
                    let saved = history.saved(id: window.id, screenID: target.id)
                    desired = WindowPlacement.destination(for: saved?.window.frame ?? window.frame,
                                                          source: saved?.screen.visibleFrame ?? source.visibleFrame,
                                                          target: target.visibleFrame, resizable: window.isResizable)
                    desired = WindowPlacement.avoidingOverlap(desired, occupied: occupied, within: target.visibleFrame)
                    occupied.append(desired)
                }
            }
            progress.append(Progress(original: window, source: source, target: target,
                                     desired: desired, minimized: minimized))
        }
    }
}
