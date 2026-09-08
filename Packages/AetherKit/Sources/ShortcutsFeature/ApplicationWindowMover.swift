import AppKit
import ApplicationServices

@MainActor
final class ApplicationWindowMover {
    private struct Request {
        let lease: WindowMoveLease
        let task: Task<Void, Never>
    }
    private var requests: [String: Request] = [:]
    private let queue = DispatchQueue(label: "com.liyuan.aether.window-movement", qos: .userInitiated)
    private let feedback = WindowMoveFeedback()

    func start(key: String, display: ShortcutDisplayContext,
               application: @escaping @MainActor () -> NSRunningApplication?) {
        requests.removeValue(forKey: key).map { $0.lease.cancel(); $0.task.cancel() }
        let lease = WindowMoveLease()
        guard AccessibilityPermission.isGranted else {
            feedback.show("窗口未移动：请在系统设置中授予 Aether 辅助功能权限。", display: display)
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            let backend = AXWindowMoveSession(lease: lease)
            var observedSource: CFRunLoopSource?
            var message: String?
            var lastScan: TimeInterval = 0
            defer {
                lease.cancel()
                if let source = observedSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
                if self.requests[key]?.lease === lease {
                    self.requests.removeValue(forKey: key)
                    if let message { self.feedback.show(message, display: display) }
                }
            }
            while !Task.isCancelled, lease.isActive() {
                let screens = PlacementScreen.snapshot()
                guard screens.contains(where: { $0.id == display.displayID }) else {
                    message = "窗口未移动：目标显示器已断开。"
                    break
                }
                if let app = application() {
                    if app.isTerminated { break }
                    let now = ProcessInfo.processInfo.systemUptime
                    if backend.consumeChange() || now - lastScan >= 1 {
                        lastScan = now
                        let pid = app.processIdentifier
                        await withCheckedContinuation { continuation in
                            self.queue.async {
                                backend.scan(pid: pid, screens: screens, targetID: display.displayID)
                                continuation.resume()
                            }
                        }
                        if observedSource == nil, let observer = backend.observer {
                            let source = AXObserverGetRunLoopSource(observer)
                            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
                            observedSource = source
                        }
                    }
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            if !Task.isCancelled, message == nil { message = backend.failureMessage }
        }
        requests[key] = Request(lease: lease, task: task)
    }

    deinit {
        for request in requests.values { request.lease.cancel(); request.task.cancel() }
    }
}

/// All AX reads/writes run on the mover's serial queue. Only the notification flag
/// crosses threads; AX elements are retained for the bounded request lifetime.
private final class AXWindowMoveSession: @unchecked Sendable {
    private struct Window {
        let element: AXUIElement
        var expected: CGRect?
        var completed = false
        var attempts = 0
    }
    let lease: WindowMoveLease
    private var windows: [Window] = []
    private var appElement: AXUIElement?
    private(set) var observer: AXObserver?
    private let changeLock = NSLock()
    private var changed = true
    private var sawWindow = false
    private var skippedFullScreen = false
    private var readFailed = false

    init(lease: WindowMoveLease) { self.lease = lease }
    func consumeChange() -> Bool { changeLock.withLock { let result = changed; changed = false; return result } }
    func markChanged() { changeLock.withLock { changed = true } }

    var failureMessage: String? {
        if windows.contains(where: { !$0.completed }) || readFailed {
            return "部分窗口未能移动：应用未允许操作，或窗口位于其他桌面。"
        }
        if skippedFullScreen { return "全屏窗口保持原位；普通窗口已处理。" }
        if !sawWindow { return "未找到可移动窗口；应用可能仍在启动。" }
        return nil
    }

    func scan(pid: pid_t, screens: [PlacementScreen], targetID: CGDirectDisplayID) {
        guard lease.isActive(), CGDisplayIsActive(targetID) != 0,
              let target = screens.first(where: { $0.id == targetID }) else { return }
        if appElement == nil {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.15)
            appElement = app
            var newObserver: AXObserver?
            if AXObserverCreate(pid, { _, _, _, context in
                guard let context else { return }
                Unmanaged<AXWindowMoveSession>.fromOpaque(context).takeUnretainedValue().markChanged()
            }, &newObserver) == .success, let newObserver {
                observer = newObserver
                AXObserverAddNotification(newObserver, app, kAXWindowCreatedNotification as CFString,
                                          Unmanaged.passUnretained(self).toOpaque())
            }
        }
        guard let app = appElement else { return }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let elements = value as? [AXUIElement] else { readFailed = true; return }
        readFailed = false
        for element in elements {
            guard lease.isActive() else { return }
            guard AXHelpers.string(element, attribute: kAXSubroleAttribute as CFString) == kAXStandardWindowSubrole else { continue }
            sawWindow = true
            if AXHelpers.bool(element, attribute: "AXFullScreen" as CFString) {
                skippedFullScreen = true
                continue
            }
            if !windows.contains(where: { CFEqual($0.element, element) }) {
                windows.append(Window(element: element))
            }
        }
        for index in windows.indices {
            guard lease.isActive(), CGDisplayIsActive(targetID) != 0 else { return }
            if windows[index].completed { continue }
            let element = windows[index].element
            // A user can close or make a window fullscreen while startup is pending.
            if !elements.contains(where: { CFEqual($0, element) }) {
                windows[index].completed = true
                continue
            }
            if AXHelpers.bool(element, attribute: "AXFullScreen" as CFString) {
                skippedFullScreen = true
                windows[index].completed = true
                continue
            }
            AXUIElementSetMessagingTimeout(element, 0.15)
            if AXHelpers.bool(element, attribute: kAXMinimizedAttribute as CFString) {
                guard lease.isActive() else { return }
                if AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse) != .success {
                    windows[index].attempts += 1
                    continue
                }
            }
            guard let frame = Self.frame(element), frame.width > 0, frame.height > 0,
                  let source = WindowPlacement.source(for: frame, screens: screens) else { continue }
            if let expected = windows[index].expected {
                if abs(frame.minX - expected.minX) <= 3, abs(frame.minY - expected.minY) <= 3 {
                    windows[index].completed = true
                    continue
                }
            } else if source.id == targetID {
                windows[index].completed = true
                continue
            }
            guard windows[index].attempts < 3 else { continue }
            windows[index].attempts += 1
            guard AXHelpers.isAttributeSettable(element, attribute: kAXPositionAttribute as CFString) else { continue }
            var desired = windows[index].expected ?? WindowPlacement.destination(
                for: frame, source: source.visibleFrame, target: target.visibleFrame,
                resizable: AXHelpers.isAttributeSettable(element, attribute: kAXSizeAttribute as CFString))
            if desired.size != frame.size {
                guard lease.isActive() else { return }
                var size = desired.size
                if let value = AXValueCreate(.cgSize, &size) {
                    AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
                }
                // Honor minimum sizes and applications that refuse resizing.
                if let actual = Self.frame(element) {
                    desired = WindowPlacement.destination(for: CGRect(origin: desired.origin, size: actual.size),
                                                          source: target.visibleFrame, target: target.visibleFrame, resizable: false)
                }
            }
            guard lease.isActive(), CGDisplayIsActive(targetID) != 0 else { return }
            var point = desired.origin
            if let value = AXValueCreate(.cgPoint, &point),
               AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value) == .success {
                windows[index].expected = desired
                // Verify on a later scan: some apps acknowledge before applying the frame.
                markChanged()
            }
        }
    }

    private static func frame(_ window: AXUIElement) -> CGRect? {
        guard let position = AXHelpers.value(window, attribute: kAXPositionAttribute as CFString),
              let size = AXHelpers.value(window, attribute: kAXSizeAttribute as CFString),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }
}

@MainActor
private final class WindowMoveFeedback {
    private var panel: NSPanel?
    private var dismissal: Task<Void, Never>?

    func show(_ text: String, display: ShortcutDisplayContext) {
        dismissal?.cancel()
        panel?.orderOut(nil)
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
        }) ?? NSScreen.main else { return }
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 13)
        label.frame = NSRect(x: 16, y: 12, width: 388, height: 42)
        panel.contentView?.addSubview(label)
        panel.setFrame(NSRect(x: screen.visibleFrame.midX - 210, y: screen.visibleFrame.minY + 40, width: 420, height: 66), display: true)
        panel.orderFrontRegardless()
        self.panel = panel
        dismissal = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.panel?.orderOut(nil)
            self?.panel = nil
        }
    }
}
