// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Testing
@testable import ShortcutsFeature

private func rectBits(_ rect: CGRect) -> [UInt64] {
    [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height].map { Double($0).bitPattern }
}
private func equalSaved(_ lhs: SavedWindowLayout?, _ rhs: SavedWindowLayout?) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil): return true
    case let (l?, r?):
        return l.window.id == r.window.id && l.window.pid == r.window.pid
            && rectBits(l.window.frame) == rectBits(r.window.frame)
            && l.window.isStandard == r.window.isStandard && l.window.isFullScreen == r.window.isFullScreen
            && l.window.isMinimized == r.window.isMinimized && l.window.isResizable == r.window.isResizable
            && l.window.isFocused == r.window.isFocused && l.window.isMain == r.window.isMain
            && l.screen.id == r.screen.id && rectBits(l.screen.frame) == rectBits(r.screen.frame)
            && rectBits(l.screen.visibleFrame) == rectBits(r.screen.visibleFrame)
    default: return false
    }
}
private func equalUndo(_ lhs: WindowLayoutUndo?, _ rhs: WindowLayoutUndo?) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil): return true
    case let (l?, r?):
        return l.operationID == r.operationID && l.pid == r.pid && Set(l.layouts.keys) == Set(r.layouts.keys)
            && l.layouts.allSatisfy { equalSaved($0.value, r.layouts[$0.key]) }
    default: return false
    }
}

@Test("Rust 布局记忆与撤销对照旧实现保留全部字段、首项与最新布局")
func rustLayoutHistoryParityAcrossOperations() {
    var seed: UInt64 = 812
    func next(_ limit: Int) -> Int {
        seed = seed &* 6364136223846793005 &+ 1
        return Int((seed >> 32) % UInt64(limit))
    }
    let ids = [Int.min, Int.max, 0] + Array(-5...25)
    let screenIDs: [UInt32] = [0, .max, 1, 2, 3, 4]
    let values: [Double] = [-0.0, 0, -1, 100, 900, .infinity, -.infinity, .nan, .greatestFiniteMagnitude]
    func rect() -> CGRect {
        .init(x: values[next(values.count)], y: values[next(values.count)],
            width: values[next(values.count)], height: values[next(values.count)])
    }
    let operations = (0..<6).map { _ in UUID() }
    let actual = WindowLayoutHistory(); let reference = ReferenceWindowLayoutHistory()
    var oldSnapshots: [(WindowLayoutUndo?, WindowLayoutUndo?)] = []
    for iteration in 0..<3000 {
        let id = ids[next(ids.count)]
        switch next(4) {
        case 0, 1:
            let window = MovableWindow(id: id, pid: Int32(truncatingIfNeeded: next(Int.max)), frame: rect(),
                isStandard: next(2) == 0, isFullScreen: next(2) == 0, isMinimized: next(2) == 0,
                isResizable: next(2) == 0, isFocused: next(2) == 0, isMain: next(2) == 0)
            let screen = PlacementScreen(id: screenIDs[next(screenIDs.count)], frame: rect(), visibleFrame: rect())
            let operation = operations[next(operations.count)]
            actual.record(window, screen: screen, operationID: operation)
            reference.record(window, screen: screen, operationID: operation)
        case 2:
            let removed: Set<Int> = [id, ids[next(ids.count)]]
            actual.remove(removed); reference.remove(removed)
        default:
            let restored: Set<Int> = next(5) == 0 ? [] : [id]
            actual.restored(restored); reference.restored(restored)
        }
        #expect(actual.hasUndo == (reference.undo != nil))
        #expect(equalUndo(actual.undo, reference.undo))
        for screen in screenIDs {
            #expect(equalSaved(actual.saved(id: id, screenID: screen), reference.saved(id: id, screenID: screen)))
        }
        if iteration.isMultiple(of: 50) { oldSnapshots.append((actual.undo, reference.undo)) }
    }
    for (actual, reference) in oldSnapshots { #expect(equalUndo(actual, reference)) }
}

@Test("Rust 部分恢复只移除撤销，关闭窗口同时清理全部屏幕记忆")
func rustLayoutPartialRestorationAndSnapshotLifetime() throws {
    let firstScreen = PlacementScreen(id: 0, frame: .init(x: 0, y: 0, width: 100, height: 100), visibleFrame: .zero)
    let secondScreen = PlacementScreen(id: .max, frame: .infinite, visibleFrame: .null)
    let first = MovableWindow(id: 0, pid: .min, frame: .init(x: -0.0, y: 5, width: -20, height: 10))
    let second = MovableWindow(id: .max, pid: .max, frame: .zero)
    let operation = UUID()
    let snapshot: WindowLayoutUndo = try {
        let history = WindowLayoutHistory()
        history.record(first, screen: firstScreen, operationID: operation)
        history.record(second, screen: secondScreen, operationID: operation)
        let original = try #require(history.undo)
        var changed = first; changed.frame = .infinite
        history.record(changed, screen: secondScreen, operationID: operation)
        #expect(equalSaved(history.saved(id: first.id, screenID: .max), .init(window: changed, screen: secondScreen)))
        #expect(equalSaved(history.undo?.layouts[first.id], .init(window: first, screen: firstScreen)))
        history.restored([first.id])
        #expect(history.hasUndo && history.undo?.layouts[first.id] == nil)
        #expect(history.saved(id: first.id, screenID: 0) != nil)
        history.remove([first.id])
        #expect(history.saved(id: first.id, screenID: 0) == nil && history.saved(id: first.id, screenID: .max) == nil)
        history.restored([second.id]); #expect(!history.hasUndo && history.undo == nil)
        #expect(history.saved(id: second.id, screenID: .max) != nil)
        history.record(changed, screen: secondScreen, operationID: operation)
        #expect(history.undo?.pid == changed.pid)
        return original
    }() // native history and Rust owner have both been released
    #expect(snapshot.operationID == operation && snapshot.pid == first.pid)
    #expect(equalSaved(snapshot.layouts[first.id], .init(window: first, screen: firstScreen)))
    #expect(equalSaved(snapshot.layouts[second.id], .init(window: second, screen: secondScreen)))
}

@Test("Rust 窗口焦点选择与原生旧筛选和优先顺序一致")
func rustWindowFocusSelectionParity() {
    var seed: UInt64 = 914
    func next(_ limit: Int) -> Int {
        seed = seed &* 6364136223846793005 &+ 1
        return Int((seed >> 32) % UInt64(limit))
    }
    let values: [Double] = [-1000, -0.0, 0, 1, 50, 300, -300, .nan, .infinity, -.infinity]
    func rect() -> CGRect {
        .init(x: values[next(values.count)], y: values[next(values.count)],
            width: values[next(values.count)], height: values[next(values.count)])
    }
    for iteration in 0..<4000 {
        let windows = (0..<(iteration % 23)).map { position in
            MovableWindow(id: position % 7, pid: Int32(position), frame: rect(),
                isStandard: next(3) != 0, isFullScreen: next(5) == 0, isMinimized: next(3) == 0,
                isResizable: next(2) == 0, isFocused: next(8) == 0, isMain: next(6) == 0)
        }
        let screens = (0..<(iteration % 6)).map { _ in PlacementScreen(id: UInt32(next(4)), frame: rect(), visibleFrame: rect()) }
        let target = UInt32(next(5))
        for restore in [false, true] {
            #expect(WindowFocusSelection.choose(windows, targetID: target, screens: screens, restoreMinimized: restore)
                == ReferenceWindowFocusSelection.choose(windows, targetID: target, screens: screens, restoreMinimized: restore))
        }
    }
}
