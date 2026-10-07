import AppKit
import CAetherCore

/// Captured on the event-tap thread, before activation or a delayed chooser.
struct ShortcutDisplayContext: Equatable, Sendable {
    let displayID: CGDirectDisplayID

    static func capture(at point: CGPoint? = nil) -> Self? {
        guard let point = point ?? CGEvent(source: nil)?.location else { return nil }
        var display: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 1, &display, &count) == .success, count > 0 else { return nil }
        return Self(displayID: display)
    }
}

struct PlacementScreen: Equatable, Sendable {
    let id: CGDirectDisplayID
    let frame: CGRect
    let visibleFrame: CGRect

    @MainActor static func snapshot() -> [Self] {
        // AX/Quartz use a top-left origin; AppKit uses the primary screen's bottom-left.
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        return NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return Self(id: id.uint32Value,
                        frame: WindowPlacement.quartzRect(screen.frame, primaryTop: primaryTop),
                        visibleFrame: WindowPlacement.quartzRect(screen.visibleFrame, primaryTop: primaryTop))
        }
    }
}

private extension CGRect {
    var rustRect: AetherRect { AetherRect(x: minX, y: minY, width: width, height: height) }
    init(_ rect: AetherRect) { self.init(x: rect.x, y: rect.y, width: rect.width, height: rect.height) }
}

enum WindowPlacement {
    static func quartzRect(_ rect: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(aether_rect_quartz(rect.rustRect, primaryTop))
    }
    static func source(for window: CGRect, screens: [PlacementScreen]) -> PlacementScreen? {
        let frames = screens.map { $0.frame.rustRect }
        let index = frames.withUnsafeBufferPointer { aether_rect_source(window.rustRect, $0.baseAddress, $0.count) }
        return index < 0 ? nil : screens[index]
    }
    static func destination(for window: CGRect, source: CGRect, target: CGRect, resizable: Bool) -> CGRect {
        CGRect(aether_rect_destination(window.rustRect, source.rustRect, target.rustRect, resizable ? 1 : 0))
    }
    static func approximatelyEqual(_ a: CGRect, _ b: CGRect) -> Bool {
        aether_rect_approximately_equal(a.rustRect, b.rustRect) != 0
    }
    static func avoidingOverlap(_ frame: CGRect, occupied: [CGRect], within bounds: CGRect) -> CGRect {
        let frames = occupied.map(\.rustRect)
        return frames.withUnsafeBufferPointer {
            CGRect(aether_rect_avoid_overlap(frame.rustRect, $0.baseAddress, $0.count, bounds.rustRect))
        }
    }
}

/// Cancellation is visible on the AX queue, including between individual window writes.
final class WindowMoveLease: @unchecked Sendable {
    private let lock = NSLock()
    private var state: AetherActionDeadline
    private let action: ApplicationActionToken?
    var deadline: TimeInterval { lock.withLock { state.deadline } }
    init(now: TimeInterval = ProcessInfo.processInfo.systemUptime, duration: TimeInterval = 10,
         action: ApplicationActionToken? = nil) {
        state = aether_action_deadline_create(now, duration)
        self.action = action
    }
    func cancel() { lock.withLock { state = aether_action_deadline_cancel(state) } }
    func isActive(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        lock.withLock { aether_action_deadline_active(state, now) != 0 } && (action?.isActive(now: now) ?? true)
    }
}
