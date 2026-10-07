// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
// Frozen business rules from 35439f0; native DTOs and already-migrated geometry are shared.
import AppKit
@testable import ShortcutsFeature

/// Session-only geometry: no titles, document paths, or user history is persisted.
final class ReferenceWindowLayoutHistory {
    private var layouts: [Int: [CGDirectDisplayID: SavedWindowLayout]] = [:]
    private(set) var undo: WindowLayoutUndo?

    func saved(id: Int, screenID: CGDirectDisplayID) -> SavedWindowLayout? { layouts[id]?[screenID] }

    func record(_ window: MovableWindow, screen: PlacementScreen, operationID: UUID) {
        let saved = SavedWindowLayout(window: window, screen: screen)
        layouts[window.id, default: [:]][screen.id] = saved
        if undo?.operationID != operationID {
            undo = WindowLayoutUndo(operationID: operationID, pid: window.pid, layouts: [:])
        }
        if undo?.layouts[window.id] == nil { undo?.layouts[window.id] = saved }
    }

    func remove(_ ids: Set<Int>) {
        for id in ids {
            layouts.removeValue(forKey: id)
            undo?.layouts.removeValue(forKey: id)
        }
        if undo?.layouts.isEmpty == true { undo = nil }
    }

    func restored(_ ids: Set<Int>) {
        for id in ids { undo?.layouts.removeValue(forKey: id) }
        if undo?.layouts.isEmpty == true { undo = nil }
    }
}


enum ReferenceWindowFocusSelection {
    static func choose(_ windows: [MovableWindow], targetID: CGDirectDisplayID,
                       screens: [PlacementScreen], restoreMinimized: Bool) -> Int? {
        let candidates = windows.filter {
            $0.isStandard && !$0.isFullScreen && $0.frame.width > 0 && $0.frame.height > 0
                && (restoreMinimized || !$0.isMinimized)
        }
        return candidates.first(where: \.isFocused)?.id
            ?? candidates.first(where: \.isMain)?.id
            ?? candidates.first(where: { WindowPlacement.source(for: $0.frame, screens: screens)?.id == targetID })?.id
            ?? candidates.first?.id
    }
}

