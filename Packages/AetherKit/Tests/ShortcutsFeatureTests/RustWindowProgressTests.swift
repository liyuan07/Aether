// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Testing
@testable import ShortcutsFeature

private final class ProgressTestAccess: WindowAccess {
    var values: [MovableWindow]
    var events: [String] = []
    var rejectIDs: Set<Int> = []
    var ignoreSize = false
    var focusAllowed = true
    var failure: WindowAccessFailure?
    var cancelAtAttempt: Int?
    private var attempts = 0
    init(_ windows: [MovableWindow]) { values = windows }
    func windows(pid: Int32, lease: WindowMoveLease) -> Result<[MovableWindow], WindowAccessFailure> {
        events.append("read")
        if let failure { return .failure(failure) }
        return .success(values.filter { $0.pid == pid })
    }
    private func prepare(_ lease: WindowMoveLease) {
        attempts += 1
        if attempts == cancelAtAttempt { lease.cancel() }
    }
    func setFrame(_ frame: CGRect, of id: Int, lease: WindowMoveLease) -> CGRect? {
        events.append("moveAttempt:\(id)"); prepare(lease)
        guard lease.isActive(), !rejectIDs.contains(id), let index = values.firstIndex(where: { $0.id == id }) else { return nil }
        values[index].frame = ignoreSize ? CGRect(origin: frame.origin, size: values[index].frame.size) : frame
        return frame
    }
    func setMinimized(_ minimized: Bool, of id: Int, lease: WindowMoveLease) -> Bool {
        events.append("minimizeAttempt:\(id):\(minimized)"); prepare(lease)
        guard lease.isActive(), !rejectIDs.contains(id), let index = values.firstIndex(where: { $0.id == id }) else { return false }
        values[index].isMinimized = minimized
        return true
    }
    func focus(_ id: Int, lease: WindowMoveLease) -> Bool {
        events.append("focus:\(id)")
        return lease.isActive() && focusAllowed
    }
}

private struct WindowSignature: Equatable {
    let id: Int
    let pid: Int32
    let geometry: [UInt64]
    let flags: [Bool]
    init(_ window: MovableWindow) {
        id = window.id; pid = window.pid; geometry = bits(window.frame)
        flags = [window.isStandard, window.isFullScreen, window.isMinimized, window.isResizable, window.isFocused, window.isMain]
    }
}
private func bits(_ rect: CGRect) -> [UInt64] {
    [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height].map { Double($0).bitPattern }
}
private struct ReportSignature: Equatable {
    let counts: [Int]
    let flags: [Bool]
    let ids: Set<Int>
    let message: String?
    init(_ report: WindowMoveReport) {
        let failure: Int
        switch report.readFailure { case .permission: failure = 1; case .unresponsive: failure = 2; case .unavailable: failure = 3; case nil: failure = 0 }
        counts = [report.moved, report.failed, report.skippedFullScreen, report.skippedMinimized, failure]
        flags = [report.hasWindows, report.timedOut, report.awaitingWindow, report.restoringLayout,
            report.displayDisconnected, report.focusFailed, report.isComplete]
        ids = report.knownIDs; message = report.message
    }
}
private func sameUndo(_ lhs: WindowLayoutUndo?, _ rhs: WindowLayoutUndo?) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil): return true
    case let (left?, right?):
        return left.operationID == right.operationID && left.pid == right.pid && Set(left.layouts.keys) == Set(right.layouts.keys)
            && left.layouts.allSatisfy { id, saved in
                guard let other = right.layouts[id] else { return false }
                return WindowSignature(saved.window) == WindowSignature(other.window) && saved.screen.id == other.screen.id
                    && bits(saved.screen.frame) == bits(other.screen.frame) && bits(saved.screen.visibleFrame) == bits(other.screen.visibleFrame)
            }
    default: return false
    }
}

@Test("Rust 会话进度与冻结旧实现逐步报告、AX 调用、窗口与撤销一致")
func rustWindowSessionProgressParity() {
    var seed: UInt64 = 1219
    func next(_ limit: Int) -> Int {
        seed = seed &* 6364136223846793005 &+ 1
        return Int((seed >> 32) % UInt64(limit))
    }
    let displays = [
        PlacementScreen(id: 1, frame: .init(x: 0, y: 0, width: 1920, height: 1080), visibleFrame: .init(x: 0, y: 25, width: 1920, height: 1055)),
        PlacementScreen(id: 2, frame: .init(x: 1920, y: 0, width: 1280, height: 800), visibleFrame: .init(x: 1920, y: 25, width: 1280, height: 775)),
        PlacementScreen(id: 3, frame: .init(x: -1280, y: -800, width: 1280, height: 800), visibleFrame: .init(x: -1280, y: -775, width: 1280, height: 775))]
    for iteration in 0..<1000 {
        let windows = (0..<(iteration % 12)).map { id -> MovableWindow in
            let display = displays[next(displays.count)]
            let frame: CGRect
            switch next(25) {
            case 0: frame = .zero
            case 1: frame = .init(x: 100, y: 100, width: -400, height: 300)
            default: frame = .init(x: display.frame.minX + Double(next(200)), y: display.frame.minY + 50,
                width: Double(200 + next(1800)), height: Double(150 + next(900)))
            }
            return .init(id: id, pid: 42, frame: frame, isStandard: next(7) != 0,
                isFullScreen: next(8) == 0, isMinimized: next(3) == 0, isResizable: next(3) != 0,
                isFocused: next(7) == 0, isMain: next(7) == 0)
        }
        let access = ProgressTestAccess(windows), oldAccess = ProgressTestAccess(windows)
        let rejected = Set(windows.filter { _ in next(5) == 0 }.map(\.id))
        access.rejectIDs = rejected; oldAccess.rejectIDs = rejected
        let ignoreSize = next(5) == 0; access.ignoreSize = ignoreSize; oldAccess.ignoreSize = ignoreSize
        let focus = next(4) != 0; access.focusAllowed = focus; oldAccess.focusAllowed = focus
        let cancellation = next(4) == 0 ? 1 + next(5) : nil
        access.cancelAtAttempt = cancellation; oldAccess.cancelAtAttempt = cancellation
        let history = WindowLayoutHistory(), oldHistory = WindowLayoutHistory()
        let operation = UUID(), previous = UUID()
        for window in windows where next(2) == 0 {
            let display = displays[next(displays.count)]
            history.record(window, screen: display, operationID: previous)
            oldHistory.record(window, screen: display, operationID: previous)
        }
        let scope: WindowCaptureScope, oldScope: WindowCaptureScope
        switch iteration % 3 {
        case 1:
            let excluded = Set(windows.filter { _ in next(2) == 0 }.map(\.id))
            scope = .appearing(excluding: excluded); oldScope = scope
        case 2:
            scope = .undo(history.undo ?? .init(operationID: previous, pid: 42, layouts: [:]))
            oldScope = .undo(oldHistory.undo ?? .init(operationID: previous, pid: 42, layouts: [:]))
        default: scope = .existing; oldScope = .existing
        }
        let target = UInt32(1 + next(4)), restore = next(2) == 0
        let session = WindowMoveSession(access: access, history: history, pid: 42, targetID: target,
            scope: scope, restoreMinimized: restore, operationID: operation)
        let original = ReferenceWindowMoveSession(access: oldAccess, history: oldHistory, pid: 42, targetID: target,
            scope: oldScope, restoreMinimized: restore, operationID: operation)
        let lease = WindowMoveLease(), oldLease = WindowMoveLease()
        var screens = displays
        for tick in 0..<20 {
            if tick == 1 && iteration.isMultiple(of: 4) {
                let later = MovableWindow(id: 200, pid: 42, frame: .init(x: 100, y: 100, width: 400, height: 300))
                access.values.append(later); oldAccess.values.append(later)
            }
            if tick == 2 && iteration.isMultiple(of: 5) { access.values.removeAll { $0.id == 0 }; oldAccess.values.removeAll { $0.id == 0 } }
            if tick == 3 && iteration.isMultiple(of: 7) { screens.removeAll { $0.id == target } }
            if tick == 4 && iteration.isMultiple(of: 11) { access.failure = .unresponsive; oldAccess.failure = .unresponsive }
            let now = 100 + Double(tick) * (iteration.isMultiple(of: 6) ? 0.01 : 0.05)
            let report = session.step(screens: screens, lease: lease, now: now)
            let expected = original.step(screens: screens, lease: oldLease, now: now)
            #expect(ReportSignature(report) == ReportSignature(expected))
            #expect(access.events == oldAccess.events)
            #expect(access.values.map(WindowSignature.init) == oldAccess.values.map(WindowSignature.init))
            #expect(sameUndo(history.undo, oldHistory.undo))
        }
    }
}

@Test("Rust 会话的特殊时间输入、精确收集边界及共享重试预算保持旧行为")
func rustWindowSessionTimeBoundaryParity() {
    let screens = [PlacementScreen(id: 1, frame: .init(x: 0, y: 0, width: 1920, height: 1080), visibleFrame: .init(x: 0, y: 25, width: 1920, height: 1055)),
        PlacementScreen(id: 2, frame: .init(x: 1920, y: 0, width: 1280, height: 800), visibleFrame: .init(x: 1920, y: 25, width: 1280, height: 775))]
    let values: [[Double]] = [[0, 0.04, 0.08, 0.12, 0.16], [.nan, 1, 2, .infinity],
        [-.infinity, 0, .infinity, .infinity], [-0.0, 0, 0.119999, 0.12, 0.16],
        [.greatestFiniteMagnitude, .greatestFiniteMagnitude, .greatestFiniteMagnitude]]
    for appearing in [false, true] {
        for times in values {
            let window = MovableWindow(id: 1, pid: 42, frame: .init(x: 50, y: 50, width: 1600, height: 900), isMinimized: true)
            let access = ProgressTestAccess([window]), oldAccess = ProgressTestAccess([window])
            access.ignoreSize = true; oldAccess.ignoreSize = true
            let history = WindowLayoutHistory(), oldHistory = WindowLayoutHistory()
            let scope: WindowCaptureScope = appearing ? .appearing(excluding: []) : .existing
            let operation = UUID()
            let session = WindowMoveSession(access: access, history: history, pid: 42, targetID: 2,
                scope: scope, restoreMinimized: true, operationID: operation)
            let original = ReferenceWindowMoveSession(access: oldAccess, history: oldHistory, pid: 42, targetID: 2,
                scope: scope, restoreMinimized: true, operationID: operation)
            let lease = WindowMoveLease(), oldLease = WindowMoveLease()
            for time in times {
                #expect(ReportSignature(session.step(screens: screens, lease: lease, now: time))
                    == ReportSignature(original.step(screens: screens, lease: oldLease, now: time)))
                #expect(access.events == oldAccess.events)
                #expect(access.values.map(WindowSignature.init) == oldAccess.values.map(WindowSignature.init))
                #expect(sameUndo(history.undo, oldHistory.undo))
            }
        }
    }
    #expect(WindowCaptureScope.existing.timeLimit == 0.35)
    #expect(WindowCaptureScope.appearing(excluding: []).timeLimit == 1.5)
    #expect(WindowCaptureScope.undo(.init(operationID: UUID(), pid: 42, layouts: [:])).timeLimit == 0.8)
}
