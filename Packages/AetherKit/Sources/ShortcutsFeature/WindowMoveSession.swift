import AppKit
import CAetherCore

private extension CGRect {
    var progressRawRect: AetherRect { .init(x: origin.x, y: origin.y, width: size.width, height: size.height) }
    var progressBounds: AetherRect { .init(x: minX, y: minY, width: width, height: height) }
    init(progress rect: AetherRect) { self.init(x: rect.x, y: rect.y, width: rect.width, height: rect.height) }
}

struct MovableWindow: Equatable, Sendable {
    let id: Int
    let pid: Int32
    var frame: CGRect
    var isStandard = true
    var isFullScreen = false
    var isMinimized = false
    var isResizable = true
    var isFocused = false
    var isMain = false
}

enum WindowAccessFailure: Error, Sendable {
    case permission, unresponsive, unavailable
}

/// Implementations execute on one serial queue. Tests use an in-memory desktop.
protocol WindowAccess: AnyObject {
    func windows(pid: Int32, lease: WindowMoveLease) -> Result<[MovableWindow], WindowAccessFailure>
    func setFrame(_ frame: CGRect, of id: Int, lease: WindowMoveLease) -> CGRect?
    func setMinimized(_ minimized: Bool, of id: Int, lease: WindowMoveLease) -> Bool
    func focus(_ id: Int, lease: WindowMoveLease) -> Bool
}

struct SavedWindowLayout: Sendable {
    let window: MovableWindow
    let screen: PlacementScreen
}

struct WindowLayoutUndo: Sendable {
    let operationID: UUID
    let pid: Int32
    var layouts: [Int: SavedWindowLayout]
}


enum WindowCaptureScope: Sendable {
    case existing
    case appearing(excluding: Set<Int>)
    case undo(WindowLayoutUndo)

    var timeLimit: TimeInterval {
        aether_window_scope_time_limit(coreKind)
    }
    private var coreKind: UInt8 { switch self { case .existing: 0; case .appearing: 1; case .undo: 2 } }
}

struct WindowMoveReport: Sendable {
    var hasWindows = false
    var knownIDs: Set<Int> = []
    var moved = 0
    var failed = 0
    var skippedFullScreen = 0
    var skippedMinimized = 0
    var readFailure: WindowAccessFailure?
    var timedOut = false
    var awaitingWindow = false
    var restoringLayout = false
    var displayDisconnected = false
    var focusFailed = false
    var isComplete = false

    var message: String? {
        if displayDisconnected { return "目标显示器已断开，已停止移动窗口。" }
        if timedOut {
            if restoringLayout { return "布局恢复超时，已停止后续操作；可重试未完成的窗口。" }
            // An application may legitimately expose no standard window after a
            // background launch or new-window request. Keep the state for the
            // activation flow, but do not present a non-actionable alert.
            if awaitingWindow { return nil }
            return "窗口准备超时，已停止后续移动；应用按当前位置唤起。"
        }
        switch readFailure {
        case .permission: return "窗口未移动：请在系统设置中授予 Aether 辅助功能权限。"
        case .unresponsive: return "应用未及时响应窗口操作，已停止移动。"
        case .unavailable: return "无法读取应用窗口，已停止移动。"
        case nil: break
        }
        if failed > 0 { return "已移动 \(moved) 个窗口，\(failed) 个未完成；应用未接受操作或无法确认位置。" }
        if focusFailed { return "窗口已就位，但应用未允许切换到目标窗口。" }
        return nil // Fullscreen and intentionally minimized windows are normal skips.
    }
}


/// A frozen cohort prevents a shortcut from adopting the user's later windows.
final class WindowMoveSession {
    private struct Progress {
        let original: MovableWindow
        let source: PlacementScreen
        let target: PlacementScreen
        var state: AetherWindowProgress
        var desired: CGRect {
            get { .init(progress: state.desired) }
            set { state.desired = newValue.progressRawRect }
        }
        var minimized: Bool { state.flags & 1 != 0 }
        var isFinished: Bool { state.flags & 12 != 0 }
        init(original: MovableWindow, source: PlacementScreen, target: PlacementScreen, desired: CGRect, minimized: Bool) {
            self.original = original; self.source = source; self.target = target
            state = aether_window_progress_create(desired.progressRawRect, minimized ? 1 : 0)
        }
    }
    private let access: WindowAccess
    private let history: WindowLayoutHistory
    private let pid: Int32
    private let targetID: CGDirectDisplayID
    private let scope: WindowCaptureScope
    private let restoreMinimized: Bool
    private let operationID: UUID
    private var collection = AetherWindowCollection()
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
        if !frozen, !freeze(windows, screens: screens, now: now) { return report }
        for index in progress.indices {
            guard lease.isActive() else { return report }
            if progress[index].isFinished { continue }
            let current = windows.first(where: { $0.id == progress[index].original.id })
            let decision = aether_window_progress_decide(progress[index].state, current == nil ? 0 : 1,
                current?.isFullScreen == true ? 1 : 0,
                screens.contains(where: { $0.id == progress[index].target.id }) ? 1 : 0,
                current.map { WindowPlacement.approximatelyEqual($0.frame, progress[index].desired) } == true ? 1 : 0,
                current?.isMinimized == progress[index].minimized ? 1 : 0, now)
            progress[index].state = decision.state
            if decision.disconnected != 0 { report.displayDisconnected = true }
            guard decision.command != 0, let current else { continue }
            var changed = false
            if decision.command == 1 {
                if let accepted = access.setFrame(progress[index].desired, of: current.id, lease: lease) {
                    progress[index].desired = WindowPlacement.destination(
                        for: accepted, source: progress[index].target.visibleFrame,
                        target: progress[index].target.visibleFrame, resizable: false)
                    changed = true
                }
            } else if decision.command == 2 {
                changed = access.setMinimized(progress[index].minimized, of: current.id, lease: lease)
            }
            let acknowledged = aether_window_progress_ack(progress[index].state, changed ? 1 : 0, isUndo ? 1 : 0)
            progress[index].state = acknowledged.state
            if acknowledged.record != 0 {
                history.record(progress[index].original, screen: progress[index].source, operationID: operationID)
            }
            // Verify the frame before restoring a minimized window; verify restoration on the next scan.
        }
        let entries = progress.map {
            AetherWindowProgressSummaryEntry(original: $0.original.frame.progressBounds, desired: $0.desired.progressBounds,
                flags: $0.state.flags, preferred: $0.original.id == preferredFocus ? 1 : 0)
        }
        var restored = [Int](repeating: 0, count: isUndo ? progress.count : 0)
        let summary = entries.withUnsafeBufferPointer { entries in
            restored.withUnsafeMutableBufferPointer {
                aether_window_progress_summary(entries.baseAddress, entries.count, unreadableWindows, isUndo ? 1 : 0, $0.baseAddress, $0.count)
            }
        }
        precondition(summary.valid != 0)
        report.moved = summary.moved
        report.failed = summary.failed
        if summary.command != 0 {
            if summary.command == 1 {
                history.restored(Set(restored.prefix(summary.restored).map { progress[$0].original.id }))
            } else if summary.focus >= 0, lease.isActive() {
                report.focusFailed = !access.focus(progress[summary.focus].original.id, lease: lease)
            }
            report.isComplete = true
        }
        return report
    }

    private var isUndo: Bool { if case .undo = scope { return true }; return false }

    private func freeze(_ windows: [MovableWindow], screens: [PlacementScreen], now: TimeInterval) -> Bool {
        let result = rustWindowFreeze(windows, screens: screens, scope: scope, targetID: targetID,
            restoreMinimized: restoreMinimized, history: history, collection: collection, now: now) { window, source, target, desired, minimized in
                Progress(original: windows[window], source: screens[source], target: screens[target], desired: desired, minimized: minimized)
            }
        collection = result.info.collection
        guard result.info.ready != 0 else { return false }
        frozen = true
        report.awaitingWindow = false
        preferredFocus = result.preferredID
        report.skippedFullScreen += result.info.fullscreen
        report.skippedMinimized += result.info.minimized
        unreadableWindows += result.info.unreadable
        if result.info.disconnected != 0 { report.displayDisconnected = true }
        progress = result.records
        return true
    }
}
