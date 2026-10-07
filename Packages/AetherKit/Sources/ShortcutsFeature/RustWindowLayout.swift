// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CAetherCore

private extension CGRect {
    // History must preserve the raw CGRect, including signed sizes. Geometry selection
    // uses native canonical bounds exactly as the pre-migration WindowPlacement adapter.
    var storedRect: AetherRect { .init(x: origin.x, y: origin.y, width: size.width, height: size.height) }
    var canonicalRect: AetherRect { .init(x: minX, y: minY, width: width, height: height) }
    init(stored rect: AetherRect) { self.init(x: rect.x, y: rect.y, width: rect.width, height: rect.height) }
}

private extension MovableWindow {
    var storedWindow: AetherMoveWindow {
        var flags: UInt8 = 0
        if isStandard { flags |= 1 }; if isFullScreen { flags |= 2 }; if isMinimized { flags |= 4 }
        if isResizable { flags |= 8 }; if isFocused { flags |= 16 }; if isMain { flags |= 32 }
        return .init(frame: frame.storedRect, id: Int64(id), pid: pid, flags: flags)
    }
    var focusWindow: AetherMoveWindow { var value = storedWindow; value.frame = frame.canonicalRect; return value }
    init(stored window: AetherMoveWindow) {
        self.init(id: Int(window.id), pid: window.pid, frame: .init(stored: window.frame),
            isStandard: window.flags & 1 != 0, isFullScreen: window.flags & 2 != 0,
            isMinimized: window.flags & 4 != 0, isResizable: window.flags & 8 != 0,
            isFocused: window.flags & 16 != 0, isMain: window.flags & 32 != 0)
    }
}

private extension PlacementScreen {
    var storedScreen: AetherPlacementScreen { .init(frame: frame.storedRect, visible: visibleFrame.storedRect, id: id) }
    var focusScreen: AetherPlacementScreen { .init(frame: frame.canonicalRect, visible: .init(), id: id) }
    init(stored screen: AetherPlacementScreen) {
        self.init(id: screen.id, frame: .init(stored: screen.frame), visibleFrame: .init(stored: screen.visible))
    }
}

private extension SavedWindowLayout {
    init(stored layout: AetherSavedWindowLayout) {
        self.init(window: .init(stored: layout.window), screen: .init(stored: layout.screen))
    }
}

/// All access stays on WindowMoveWorker's existing serial queue. Native DTOs are
/// produced only on lookup or explicit undo, rather than retained in duplicate maps.
final class WindowLayoutHistory {
    private let handle: UnsafeMutableRawPointer
    init() { handle = aether_window_history_create()! }
    deinit { aether_window_history_destroy(handle) }

    var hasUndo: Bool { aether_window_history_has_undo(handle) != 0 }
    var undo: WindowLayoutUndo? {
        guard let snapshot = aether_window_history_snapshot(handle) else { return nil }
        defer { aether_window_snapshot_destroy(snapshot) }
        let info = aether_window_snapshot_info(snapshot)
        var layouts: [Int: SavedWindowLayout] = [:]
        layouts.reserveCapacity(info.count)
        for index in 0..<info.count {
            let view = aether_window_snapshot_saved(snapshot, index)
            precondition(view.valid != 0)
            let layout = SavedWindowLayout(stored: view.saved)
            layouts[layout.window.id] = layout
        }
        return .init(operationID: UUID(uuid: info.operation.bytes), pid: info.pid, layouts: layouts)
    }

    func saved(id: Int, screenID: CGDirectDisplayID) -> SavedWindowLayout? {
        let view = aether_window_history_saved(handle, Int64(id), screenID)
        return view.valid == 0 ? nil : .init(stored: view.saved)
    }
    func record(_ window: MovableWindow, screen: PlacementScreen, operationID: UUID) {
        let saved = AetherSavedWindowLayout(window: window.storedWindow, screen: screen.storedScreen)
        precondition(aether_window_history_record(handle, saved, .init(bytes: operationID.uuid)) != 0)
    }
    func remove(_ ids: Set<Int>) { remove(ids, mode: 0) }
    func restored(_ ids: Set<Int>) { remove(ids, mode: 1) }
    private func remove(_ ids: Set<Int>, mode: UInt8) {
        let values = ids.map(Int64.init)
        let accepted = values.withUnsafeBufferPointer {
            aether_window_history_remove(handle, $0.baseAddress, $0.count, mode)
        }
        precondition(accepted != 0)
    }
}

enum WindowFocusSelection {
    static func choose(_ windows: [MovableWindow], targetID: CGDirectDisplayID,
                       screens: [PlacementScreen], restoreMinimized: Bool) -> Int? {
        let values = windows.map(\.focusWindow)
        let displays = screens.map(\.focusScreen)
        let index = values.withUnsafeBufferPointer { windows in
            displays.withUnsafeBufferPointer {
                aether_window_focus_choose(windows.baseAddress, windows.count, $0.baseAddress, $0.count, targetID, restoreMinimized ? 1 : 0)
            }
        }
        return index < 0 ? nil : windows[index].id
    }
}

private final class WindowFreezeLookup {
    let windows: [MovableWindow]
    let history: WindowLayoutHistory
    let undo: WindowLayoutUndo?
    init(windows: [MovableWindow], history: WindowLayoutHistory, undo: WindowLayoutUndo?) {
        self.windows = windows; self.history = history; self.undo = undo
    }
}

struct WindowFreezeResult<T> {
    let info: AetherWindowFreezeInfo
    let records: [T]
    let preferredID: Int?
}

/// Primitive normalization and DTO assembly only; the core owns cohort and geometry decisions.
func rustWindowFreeze<T>(_ windows: [MovableWindow], screens: [PlacementScreen], scope: WindowCaptureScope,
    targetID: UInt32, restoreMinimized: Bool, history: WindowLayoutHistory,
    collection: AetherWindowCollection, now: TimeInterval,
    assemble: (Int, Int, Int, CGRect, Bool) -> T) -> WindowFreezeResult<T> {
    let values = windows.map { AetherWindowFreezeInput(window: $0.focusWindow, raw: $0.frame.storedRect) }
    let displays = screens.map { AetherPlacementScreen(frame: $0.frame.canonicalRect, visible: $0.visibleFrame.canonicalRect, id: $0.id) }
    let kind: UInt8; let ids: [Int64]; let undo: WindowLayoutUndo?
    switch scope {
    case .existing: kind = 0; ids = []; undo = nil
    case let .appearing(excluded): kind = 1; ids = excluded.map(Int64.init); undo = nil
    case let .undo(batch): kind = 2; ids = batch.layouts.keys.map(Int64.init); undo = batch
    }
    let context = WindowFreezeLookup(windows: windows, history: history, undo: undo)
    let lookup: @convention(c) (UnsafeMutableRawPointer?, Int, UInt32, UInt8) -> AetherWindowFreezeSaved = { pointer, index, target, isUndo in
        let context = Unmanaged<WindowFreezeLookup>.fromOpaque(pointer!).takeUnretainedValue()
        let id = context.windows[index].id
        let saved = isUndo != 0 ? context.undo?.layouts[id] : context.history.saved(id: id, screenID: target)
        guard let saved else { return .init() }
        return .init(frame: saved.window.frame.canonicalRect, visible: saved.screen.visibleFrame.canonicalRect,
            screen: saved.screen.id, minimized: saved.window.isMinimized ? 1 : 0, valid: 1)
    }
    return withExtendedLifetime(context) {
        let plan = values.withUnsafeBufferPointer { values in
            displays.withUnsafeBufferPointer { displays in
                ids.withUnsafeBufferPointer {
                    aether_window_freeze_plan(values.baseAddress, values.count, displays.baseAddress, displays.count,
                        $0.baseAddress, $0.count, kind, targetID, restoreMinimized ? 1 : 0, collection, now,
                        lookup, Unmanaged.passUnretained(context).toOpaque())
                }
            }
        }
        guard let plan else { preconditionFailure("Invalid window freeze input") }
        defer { aether_window_freeze_destroy(plan) }
        let info = aether_window_freeze_info(plan)
        let records = (0..<info.count).map { index -> T in
            let entry = aether_window_freeze_entry(plan, index)
            precondition(entry.valid != 0)
            return assemble(entry.window, entry.source, entry.target, .init(stored: entry.desired), entry.minimized != 0)
        }
        return .init(info: info, records: records, preferredID: info.preferred < 0 ? nil : windows[info.preferred].id)
    }
}
