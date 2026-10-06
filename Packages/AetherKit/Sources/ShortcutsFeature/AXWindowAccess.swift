import AppKit
import ApplicationServices

/// AX elements never leave the mover's serial queue. IDs are bounded, process-local handles.
final class AXWindowAccess: WindowAccess {
    private struct Entry {
        let pid: Int32
        let application: NSRunningApplication
        let element: AXUIElement
    }
    private var entries: [Int: Entry] = [:]
    private var nextID = 0
    private let history: WindowLayoutHistory

    init(history: WindowLayoutHistory) { self.history = history }

    func windows(pid: Int32, lease: WindowMoveLease) -> Result<[MovableWindow], WindowAccessFailure> {
        remove(Set(entries.filter { $0.value.application.isTerminated }.keys))
        guard let running = NSRunningApplication(processIdentifier: pid), !running.isTerminated else {
            remove(Set(entries.filter { $0.value.pid == pid }.keys))
            return .success([])
        }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.08)
        var value: CFTypeRef?
        guard lease.isActive() else { return .failure(.unresponsive) }
        let error = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        guard error == .success, let elements = value as? [AXUIElement] else {
            return .failure(error == .apiDisabled ? .permission : error == .cannotComplete ? .unresponsive : .unavailable)
        }
        let removed = Set(entries.filter { $0.value.pid == pid && !elements.contains($0.value.element) }.keys)
        remove(removed)
        var focused: CFTypeRef?
        var main: CFTypeRef?
        var loadedFocus = false
        var loadedMain = false
        var windows: [MovableWindow] = []
        for element in elements {
            guard lease.isActive() else { return .failure(.unresponsive) }
            AXUIElementSetMessagingTimeout(element, 0.08)
            let id: Int
            if let existing = entries.first(where: { $0.value.pid == pid && CFEqual($0.value.element, element) }) {
                id = existing.key
            } else {
                nextID += 1
                id = nextID
                entries[id] = Entry(pid: pid, application: running, element: element)
            }
            let standard = AXHelpers.string(element, attribute: kAXSubroleAttribute as CFString) == kAXStandardWindowSubrole
            if !standard {
                windows.append(MovableWindow(id: id, pid: pid, frame: .zero, isStandard: false))
                continue
            }
            let fullScreen = AXHelpers.bool(element, attribute: "AXFullScreen" as CFString)
            if fullScreen {
                // Full-screen windows are deliberately never moved or focused by the
                // placement flow. Avoid the slower geometry/state queries for them.
                windows.append(MovableWindow(id: id, pid: pid, frame: .zero,
                                             isStandard: true, isFullScreen: true))
                continue
            }
            if !loadedFocus {
                focused = AXHelpers.value(app, attribute: kAXFocusedWindowAttribute as CFString)
                loadedFocus = true
            }
            if !loadedMain {
                main = AXHelpers.value(app, attribute: kAXMainWindowAttribute as CFString)
                loadedMain = true
            }
            let frame = Self.frame(element) ?? .zero
            windows.append(MovableWindow(
                id: id, pid: pid, frame: frame,
                isStandard: true,
                isFullScreen: false,
                isMinimized: AXHelpers.bool(element, attribute: kAXMinimizedAttribute as CFString),
                isResizable: AXHelpers.isAttributeSettable(element, attribute: kAXSizeAttribute as CFString),
                isFocused: focused.map { CFEqual($0, element) } ?? false,
                isMain: main.map { CFEqual($0, element) } ?? false))
        }
        // Keep current windows, evict stale handles from other applications first.
        if entries.count > 256 {
            let stale = entries.filter { $0.value.pid != pid }.keys.sorted()
            remove(Set(stale.prefix(entries.count - 256)))
        }
        return .success(windows)
    }

    func setFrame(_ frame: CGRect, of id: Int, lease: WindowMoveLease) -> CGRect? {
        guard let entry = entries[id], lease.isActive(),
              !AXHelpers.bool(entry.element, attribute: "AXFullScreen" as CFString),
              AXHelpers.isAttributeSettable(entry.element, attribute: kAXPositionAttribute as CFString),
              let current = Self.frame(entry.element) else { return nil }
        var desired = frame
        var resized = false
        if current.size != frame.size {
            guard lease.isActive() else { return nil }
            var size = frame.size
            if let value = AXValueCreate(.cgSize, &size) {
                resized = AXUIElementSetAttributeValue(entry.element, kAXSizeAttribute as CFString, value) == .success
            }
            if let actual = Self.frame(entry.element), !resized || actual.size != current.size {
                // Do not mistake an asynchronously acknowledged resize for a minimum-size constraint.
                desired.size = actual.size
            }
        }
        guard lease.isActive() else { return resized ? desired : nil }
        var point = desired.origin
        guard let value = AXValueCreate(.cgPoint, &point) else { return resized ? desired : nil }
        let positioned = AXUIElementSetAttributeValue(entry.element, kAXPositionAttribute as CFString, value) == .success
        return positioned || resized ? desired : nil
    }

    func setMinimized(_ minimized: Bool, of id: Int, lease: WindowMoveLease) -> Bool {
        guard let entry = entries[id], lease.isActive(),
              !AXHelpers.bool(entry.element, attribute: "AXFullScreen" as CFString) else { return false }
        return AXUIElementSetAttributeValue(entry.element, kAXMinimizedAttribute as CFString,
                                           minimized ? kCFBooleanTrue : kCFBooleanFalse) == .success
    }

    func focus(_ id: Int, lease: WindowMoveLease) -> Bool {
        guard let entry = entries[id], lease.isActive(),
              !AXHelpers.bool(entry.element, attribute: "AXFullScreen" as CFString),
              !AXHelpers.bool(entry.element, attribute: kAXMinimizedAttribute as CFString) else { return false }
        _ = AXUIElementSetAttributeValue(entry.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        guard lease.isActive() else { return false }
        return AXUIElementPerformAction(entry.element, kAXRaiseAction as CFString) == .success
    }

    private func remove(_ ids: Set<Int>) {
        for id in ids { entries.removeValue(forKey: id) }
        history.remove(ids)
    }

    private static func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = AXHelpers.value(element, attribute: kAXPositionAttribute as CFString),
              let size = AXHelpers.value(element, attribute: kAXSizeAttribute as CFString),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }
}
