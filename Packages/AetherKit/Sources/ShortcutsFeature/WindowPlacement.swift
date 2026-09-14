import AppKit

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

enum WindowPlacement {
    static func quartzRect(_ rect: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryTop - rect.maxY, width: rect.width, height: rect.height)
    }

    static func source(for window: CGRect, screens: [PlacementScreen]) -> PlacementScreen? {
        screens.max { lhs, rhs in
            func area(_ screen: PlacementScreen) -> CGFloat {
                let intersection = window.intersection(screen.frame)
                return intersection.isNull ? 0 : intersection.width * intersection.height
            }
            let a = area(lhs), b = area(rhs)
            if a != b { return a < b }
            func distance(_ screen: PlacementScreen) -> CGFloat {
                pow(window.midX - screen.frame.midX, 2) + pow(window.midY - screen.frame.midY, 2)
            }
            return distance(lhs) > distance(rhs)
        }
    }

    static func destination(for window: CGRect, source: CGRect, target: CGRect, resizable: Bool) -> CGRect {
        let size = resizable
            ? CGSize(width: min(window.width, target.width), height: min(window.height, target.height))
            : window.size
        func position(_ value: CGFloat, _ sourceStart: CGFloat, _ sourceLength: CGFloat,
                      _ targetStart: CGFloat, _ targetLength: CGFloat, _ windowLength: CGFloat) -> CGFloat {
            let relative = (value - sourceStart) / max(sourceLength, 1)
            return min(max(targetStart + relative * targetLength, targetStart),
                       targetStart + max(0, targetLength - windowLength))
        }
        return CGRect(x: position(window.minX, source.minX, source.width, target.minX, target.width, size.width),
                      y: position(window.minY, source.minY, source.height, target.minY, target.height, size.height),
                      width: size.width, height: size.height)
    }

    static func approximatelyEqual(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 3 && abs(a.minY - b.minY) <= 3
            && abs(a.width - b.width) <= 3 && abs(a.height - b.height) <= 3
    }

    /// Preserve existing target-screen windows and stagger exact collisions.
    static func avoidingOverlap(_ frame: CGRect, occupied: [CGRect], within bounds: CGRect) -> CGRect {
        func collides(_ candidate: CGRect) -> Bool {
            occupied.contains { abs($0.minX - candidate.minX) < 20 && abs($0.minY - candidate.minY) < 20 }
        }
        if !collides(frame) { return frame }
        for distance in 1...12 {
            for direction in [CGPoint(x: 1, y: 1), CGPoint(x: -1, y: -1), CGPoint(x: 1, y: -1), CGPoint(x: -1, y: 1)] {
                let offset = CGFloat(distance * 28)
                let candidate = CGRect(x: frame.minX + direction.x * offset,
                                       y: frame.minY + direction.y * offset,
                                       width: frame.width, height: frame.height)
                if bounds.contains(candidate), !collides(candidate) { return candidate }
            }
        }
        return frame // No space: do not shrink or move existing windows to manufacture room.
    }
}

/// Cancellation is visible on the AX queue, including between individual window writes.
final class WindowMoveLease: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private let action: ApplicationActionToken?
    let deadline: TimeInterval
    init(now: TimeInterval = ProcessInfo.processInfo.systemUptime, duration: TimeInterval = 10,
         action: ApplicationActionToken? = nil) {
        deadline = now + duration
        self.action = action
    }
    func cancel() { lock.withLock { cancelled = true } }
    func isActive(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        lock.withLock { !cancelled && now < deadline } && (action?.isActive(now: now) ?? true)
    }
}
