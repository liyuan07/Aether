import AppKit
import Testing
@testable import ShortcutsFeature

private final class TestWindowAccess: WindowAccess {
    var values: [MovableWindow]
    var events: [String] = []
    var rejectWrites = false
    var rejectIDs: Set<Int> = []
    var ignoreSize = false
    var focusAllowed = true
    var readFailure: WindowAccessFailure?
    var beforeWrite: (() -> Void)?

    init(_ values: [MovableWindow]) { self.values = values }
    func windows(pid: Int32, lease: WindowMoveLease) -> Result<[MovableWindow], WindowAccessFailure> {
        if let readFailure { return .failure(readFailure) }
        return .success(values.filter { $0.pid == pid })
    }
    func setFrame(_ frame: CGRect, of id: Int, lease: WindowMoveLease) -> CGRect? {
        beforeWrite?()
        guard lease.isActive(), !rejectWrites, !rejectIDs.contains(id), let index = values.firstIndex(where: { $0.id == id }) else { return nil }
        events.append("move:\(id)")
        values[index].frame = ignoreSize ? CGRect(origin: frame.origin, size: values[index].frame.size) : frame
        return frame
    }
    func setMinimized(_ minimized: Bool, of id: Int, lease: WindowMoveLease) -> Bool {
        beforeWrite?()
        guard lease.isActive(), !rejectWrites, let index = values.firstIndex(where: { $0.id == id }) else { return false }
        events.append("minimized:\(id):\(minimized)")
        values[index].isMinimized = minimized
        return true
    }
    func focus(_ id: Int, lease: WindowMoveLease) -> Bool {
        guard lease.isActive() else { return false }
        events.append("focus:\(id)")
        return focusAllowed
    }
}

private let largeScreen = PlacementScreen(id: 1, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                         visibleFrame: CGRect(x: 0, y: 25, width: 1920, height: 1055))
private let smallScreen = PlacementScreen(id: 2, frame: CGRect(x: 1920, y: 0, width: 1280, height: 800),
                                         visibleFrame: CGRect(x: 1920, y: 25, width: 1280, height: 775))
private let testScreens = [largeScreen, smallScreen]
private func testWindow(_ id: Int = 1, frame: CGRect = CGRect(x: 100, y: 100, width: 800, height: 600),
                        minimized: Bool = false, fullScreen: Bool = false, focused: Bool = false) -> MovableWindow {
    MovableWindow(id: id, pid: 42, frame: frame, isFullScreen: fullScreen, isMinimized: minimized, isFocused: focused)
}
private func session(_ access: TestWindowAccess, history: WindowLayoutHistory = WindowLayoutHistory(),
                     target: UInt32 = 2, scope: WindowCaptureScope = .existing,
                     restoreMinimized: Bool = true) -> WindowMoveSession {
    WindowMoveSession(access: access, history: history, pid: 42, targetID: target, scope: scope,
                      restoreMinimized: restoreMinimized, operationID: UUID())
}
private func finish(_ session: WindowMoveSession, lease: WindowMoveLease = WindowMoveLease(),
                    screens: [PlacementScreen] = testScreens) -> WindowMoveReport {
    let base = ProcessInfo.processInfo.systemUptime
    var result = WindowMoveReport()
    for tick in 0..<20 {
        result = session.step(screens: screens, lease: lease, now: base + Double(tick) * 0.05)
        if result.isComplete { break }
    }
    return result
}

@Test func minimizedWindowMovesAndVerifiesBeforeRestorationAndFocus() {
    let access = TestWindowAccess([testWindow(minimized: true)])
    let report = finish(session(access))
    #expect(report.isComplete && report.failed == 0)
    #expect(access.events == ["move:1", "minimized:1:false", "focus:1"])
    #expect(smallScreen.visibleFrame.contains(access.values[0].frame))
}

@Test func warmRequestFreezesItsInitialWindowCohort() {
    let access = TestWindowAccess([testWindow()])
    let move = session(access)
    let lease = WindowMoveLease()
    _ = move.step(screens: testScreens, lease: lease)
    let later = testWindow(2)
    access.values.append(later)
    let report = finish(move, lease: lease)
    #expect(report.isComplete)
    #expect(access.values[1] == later)
    #expect(!access.events.contains("move:2"))
    access.values.append(testWindow(3))
    _ = move.step(screens: testScreens, lease: lease)
    #expect(!access.events.contains("move:3"))
}

@Test func startupCaptureEndsAfterItsFixedCollectionInterval() {
    let access = TestWindowAccess([testWindow()])
    let move = session(access, scope: .appearing(excluding: [1]))
    let lease = WindowMoveLease()
    let now = ProcessInfo.processInfo.systemUptime
    #expect(!move.step(screens: testScreens, lease: lease, now: now).isComplete)
    access.values.append(testWindow(2))
    _ = move.step(screens: testScreens, lease: lease, now: now + 0.01)
    access.values.append(testWindow(3))
    _ = move.step(screens: testScreens, lease: lease, now: now + 0.14)
    access.values.append(testWindow(4))
    _ = move.step(screens: testScreens, lease: lease, now: now + 0.20)
    #expect(access.events.contains("move:2") && access.events.contains("move:3"))
    #expect(!access.events.contains("move:1") && !access.events.contains("move:4"))
}

@Test func emptyWarmApplicationCompletesWithoutAdoptingLaterWindows() {
    let access = TestWindowAccess([])
    let move = session(access)
    let report = finish(move)
    #expect(report.isComplete && !report.hasWindows)
    access.values.append(testWindow())
    _ = finish(move)
    #expect(access.events.isEmpty)
}

@Test func cancelledInputStopsRemainingWindowWritesAndFocus() {
    let access = TestWindowAccess([testWindow(), testWindow(2)])
    let intent = ApplicationIntent()
    let token = intent.begin(sourcePID: 7, targetPID: 42)
    let lease = WindowMoveLease(action: token)
    access.beforeWrite = { intent.interrupt() }
    _ = finish(session(access), lease: lease)
    #expect(access.events.isEmpty)
    #expect(!token.isActive())
}

@Test func closedMovementLeaseNeverRestoresOrFocusesAfterTimeout() {
    let access = TestWindowAccess([testWindow(minimized: true)])
    let move = session(access)
    let lease = WindowMoveLease()
    _ = move.step(screens: testScreens, lease: lease)
    lease.cancel() // The real timeout closes this before calling activation.
    _ = finish(move, lease: lease)
    #expect(access.events == ["move:1"])
    #expect(access.values[0].isMinimized)
}

@Test func crossScreenRoundTripRestoresOriginalSizeAndPosition() {
    let original = testWindow(frame: CGRect(x: 120, y: 100, width: 1600, height: 900))
    let access = TestWindowAccess([original])
    let history = WindowLayoutHistory()
    #expect(finish(session(access, history: history)).failed == 0)
    #expect(access.values[0].frame.size == smallScreen.visibleFrame.size)
    #expect(finish(session(access, history: history, target: 1)).failed == 0)
    #expect(access.values[0].frame == original.frame)
}

@Test func manualLayoutBecomesTheRememberedLayoutForThatDisplay() {
    let access = TestWindowAccess([testWindow()])
    let history = WindowLayoutHistory()
    _ = finish(session(access, history: history))
    let manual = CGRect(x: 2050, y: 150, width: 900, height: 500)
    access.values[0].frame = manual
    _ = finish(session(access, history: history, target: 1))
    _ = finish(session(access, history: history, target: 2))
    #expect(access.values[0].frame == manual)
}

@Test func gatheringWindowsKeepsExistingTargetWindowAndStaggersCollision() {
    let other = PlacementScreen(id: 2, frame: largeScreen.frame.offsetBy(dx: 1920, dy: 0),
                                visibleFrame: largeScreen.visibleFrame.offsetBy(dx: 1920, dy: 0))
    let existing = testWindow()
    let access = TestWindowAccess([existing, testWindow(2, frame: existing.frame.offsetBy(dx: 1920, dy: 0))])
    let report = finish(session(access, target: 1), screens: [largeScreen, other])
    #expect(report.failed == 0)
    #expect(access.values[0].frame == existing.frame)
    #expect(access.values[1].frame.origin != existing.frame.origin)
    #expect(largeScreen.visibleFrame.contains(access.values[1].frame))
}

@Test func undoRestoresGeometryAndOriginalMinimizedState() throws {
    let original = testWindow(minimized: true)
    let access = TestWindowAccess([original])
    let history = WindowLayoutHistory()
    _ = finish(session(access, history: history))
    let undo = try #require(history.undo)
    access.events.removeAll()
    let report = finish(session(access, history: history, scope: .undo(undo)))
    #expect(report.isComplete && report.failed == 0)
    #expect(access.values[0].frame == original.frame && access.values[0].isMinimized)
    #expect(history.undo == nil)
    #expect(!access.events.contains("focus:1"))
}

@Test func undoOnDisconnectedDisplayKeepsRecordForRetry() throws {
    let access = TestWindowAccess([testWindow()])
    let history = WindowLayoutHistory()
    _ = finish(session(access, history: history))
    let undo = try #require(history.undo)
    access.events.removeAll()
    let report = finish(session(access, history: history, scope: .undo(undo)), screens: [smallScreen])
    #expect(report.displayDisconnected && report.message != nil)
    #expect(access.events.isEmpty && history.undo != nil)
}

@Test func keepingMinimizedWindowsLeavesTheirGeometryAndStateUntouched() {
    let minimized = testWindow(minimized: true)
    let access = TestWindowAccess([minimized, testWindow(2)])
    let report = finish(session(access, restoreMinimized: false))
    #expect(report.skippedMinimized == 1 && report.message == nil)
    #expect(access.values[0] == minimized)
    #expect(access.events == ["move:2", "focus:2"])
}

@Test func fullScreenWindowCannotTakeFocusFromAnEligibleOrdinaryWindow() {
    let fullScreen = testWindow(2, fullScreen: true, focused: true)
    let access = TestWindowAccess([fullScreen, testWindow()])
    let report = finish(session(access))
    #expect(report.skippedFullScreen == 1 && report.message == nil)
    #expect(access.values[0] == fullScreen)
    #expect(access.events.last == "focus:1")
}

@Test func alreadyPlacedWindowsDoNotMoveOrCreateUndoRecords() {
    let access = TestWindowAccess([testWindow()])
    let history = WindowLayoutHistory()
    let report = finish(session(access, history: history, target: 1))
    #expect(report.isComplete && report.moved == 0)
    #expect(access.events == ["focus:1"] && history.undo == nil)
}

@Test func rejectedMovementFinishesPromptlyAndDoesNotReplacePreviousUndo() throws {
    let access = TestWindowAccess([testWindow()])
    let history = WindowLayoutHistory()
    _ = finish(session(access, history: history))
    let previous = try #require(history.undo).operationID
    access.rejectWrites = true
    let report = finish(session(access, history: history, target: 1))
    #expect(report.isComplete && report.failed == 1)
    #expect(report.message?.contains("1 个未完成") == true)
    #expect(history.undo?.operationID == previous)
}

@Test func positionAcknowledgementWithoutRequiredSizeIsNotSuccess() {
    let access = TestWindowAccess([testWindow(frame: CGRect(x: 50, y: 50, width: 1600, height: 900))])
    access.ignoreSize = true
    let report = finish(session(access))
    #expect(report.isComplete && report.failed == 1)
}

@Test func readFailuresAreReportedWithoutInventingASpaceOrPermissionCause() {
    let access = TestWindowAccess([testWindow()])
    access.readFailure = .unresponsive
    let report = finish(session(access))
    #expect(report.isComplete && report.message == "应用未及时响应窗口操作，已停止移动。")
    #expect(access.events.isEmpty)
}

@Test func missingDestinationStopsWithoutMovingAnyWindow() {
    let access = TestWindowAccess([testWindow()])
    let report = finish(session(access), screens: [largeScreen])
    #expect(report.isComplete && report.displayDisconnected)
    #expect(access.events.isEmpty)
}

@Test func onlyFullScreenWindowsAreASilentNormalOutcome() {
    let access = TestWindowAccess([testWindow(fullScreen: true)])
    let report = finish(session(access))
    #expect(report.isComplete && report.hasWindows && report.message == nil)
    #expect(access.events.isEmpty)
}

@Test func focusFallsBackToASuccessfulWindowIfThePreferredOneRefusesMovement() {
    let access = TestWindowAccess([testWindow(focused: true), testWindow(2)])
    access.rejectIDs = [1]
    let report = finish(session(access))
    #expect(report.isComplete && report.failed == 1 && report.moved == 1)
    #expect(access.events.last == "focus:2")
}

@Test func timeoutMessagesDescribeTheActualOperation() {
    var report = WindowMoveReport()
    report.timedOut = true
    report.restoringLayout = true
    #expect(report.message?.contains("布局恢复超时") == true)
    report.restoringLayout = false
    report.awaitingWindow = true
    #expect(report.message == "未发现可处理的新窗口，已结束本次等待。")
}

@Test func closedWindowHistoryCannotBeReusedByAnotherWindow() {
    let history = WindowLayoutHistory()
    history.record(testWindow(), screen: largeScreen, operationID: UUID())
    #expect(history.undo != nil)
    history.remove([1])
    #expect(history.undo == nil)
    #expect(history.saved(id: 1, screenID: 1) == nil)
    #expect(history.saved(id: 2, screenID: 1) == nil)
}

@Test func oneUnreadableWindowDoesNotBlockOtherOrdinaryWindows() {
    let access = TestWindowAccess([testWindow(), testWindow(2, frame: .zero)])
    let report = finish(session(access))
    #expect(report.isComplete && report.moved == 1 && report.failed == 1)
    #expect(access.events == ["move:1", "focus:1"])
}
