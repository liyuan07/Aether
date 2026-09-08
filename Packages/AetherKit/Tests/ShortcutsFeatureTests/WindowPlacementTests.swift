import AppKit
import Testing
import ShortcutCore
@testable import ShortcutsFeature

@Test func screenCoordinateConversionPreservesAboveAndLeftDisplays() {
    #expect(WindowPlacement.quartzRect(CGRect(x: -189, y: 982, width: 1920, height: 1080), primaryTop: 982)
            == CGRect(x: -189, y: -1080, width: 1920, height: 1080))
}

@Test(arguments: [CGPoint(x: -1920, y: 0), CGPoint(x: 1512, y: 0), CGPoint(x: 0, y: -1080), CGPoint(x: 0, y: 982)])
func allDisplayArrangements(_ origin: CGPoint) {
    let source = CGRect(x: 0, y: 25, width: 1512, height: 930)
    let target = CGRect(origin: origin, size: CGSize(width: 1920, height: 1080))
    let window = CGRect(x: 151.2, y: 118, width: 600, height: 400)
    let result = WindowPlacement.destination(for: window, source: source, target: target, resizable: true)
    #expect(abs(result.minX - (origin.x + 192)) < 0.01)
    #expect(abs(result.minY - (origin.y + 108)) < 0.01)
    #expect(result.size == window.size)
    #expect(target.contains(result))
}

@Test func oversizedAndOffscreenWindowsRemainReachable() {
    let target = CGRect(x: -1280, y: -800, width: 1280, height: 760)
    let source = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let window = CGRect(x: 1900, y: -200, width: 1600, height: 900)
    let resized = WindowPlacement.destination(for: window, source: source, target: target, resizable: true)
    #expect(resized == target)
    let fixed = WindowPlacement.destination(for: window, source: source, target: target, resizable: false)
    #expect(fixed.origin == target.origin)
    #expect(fixed.size == window.size)
}

@Test func largestOverlapDeterminesSource() {
    let a = PlacementScreen(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 800), visibleFrame: .zero)
    let b = PlacementScreen(id: 2, frame: CGRect(x: 1000, y: 0, width: 1000, height: 800), visibleFrame: .zero)
    #expect(WindowPlacement.source(for: CGRect(x: 900, y: 100, width: 500, height: 400), screens: [a, b])?.id == 2)
    #expect(WindowPlacement.source(for: CGRect(x: -2000, y: 0, width: 100, height: 100), screens: [a, b])?.id == 1)
    #expect(WindowPlacement.source(for: .zero, screens: []) == nil)
}

@Test func requestCancellationAndDeadline() {
    let old = WindowMoveLease(now: 100)
    #expect(old.isActive(now: 109.9))
    #expect(!old.isActive(now: 110))
    old.cancel()
    let new = WindowMoveLease(now: 105)
    #expect(!old.isActive(now: 106))
    #expect(new.isActive(now: 106))
}

@Test @MainActor func launcherKeepsKeyDownDisplayUntilRelease() {
    let app = RegisteredApplication(bundleIdentifier: "example.test", displayName: "Test", applicationPath: "/test.app", initial: "T")
    var launches: [ShortcutDisplayContext?] = []
    let controller = ApplicationLauncherController(
        applicationsProvider: { _ in [app] }, defaultApplicationProvider: { _ in app },
        holdDurationProvider: { 100 }, setDefaultHandler: { _, _ in }, moveApplicationsHandler: { _, _, _ in },
        launchHandler: { _, display in launches.append(display) })
    let first = ShortcutDisplayContext(displayID: 1)
    let second = ShortcutDisplayContext(displayID: 2)
    controller.eventRouter.onEvent?("T", .pressed, first)
    controller.eventRouter.onEvent?("T", .released, second)
    #expect(launches == [first])
    controller.eventRouter.onEvent?("T", .pressed, second)
    controller.eventRouter.onEvent?("T", .released, first)
    #expect(launches == [first, second])
    controller.stop()
    controller.eventRouter.onEvent?("T", .released, first)
    #expect(launches.count == 2)
}

@Test func multipleWindowOffsetsRemainOrdered() {
    let source = CGRect(x: 0, y: 25, width: 1200, height: 800)
    let target = CGRect(x: -1920, y: -1080, width: 1920, height: 1055)
    let first = WindowPlacement.destination(for: CGRect(x: 100, y: 125, width: 500, height: 400), source: source, target: target, resizable: true)
    let second = WindowPlacement.destination(for: CGRect(x: 200, y: 225, width: 500, height: 400), source: source, target: target, resizable: true)
    #expect(first.minX < second.minX)
    #expect(first.minY < second.minY)
    #expect(first.size == second.size)
    #expect(target.contains(first) && target.contains(second))
}
