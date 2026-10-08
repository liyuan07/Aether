import SharedSupport
import AppKit
import ApplicationServices
import ShortcutCore
import CAetherCore

@MainActor
final class ActionExecutor {
    private let workspace = NSWorkspace.shared
    private let windowMover = ApplicationWindowMover()
    private let preferences: () -> ApplicationShortcutPreferences
    private var commandTask: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?
    private var fallbackInputMonitor: Any?
    var onUndoAvailabilityChanged: ((Bool) -> Void)? {
        didSet { windowMover.onUndoAvailabilityChanged = onUndoAvailabilityChanged }
    }

    init(preferences: @escaping () -> ApplicationShortcutPreferences = { ApplicationShortcutPreferences() }) {
        self.preferences = preferences
        activationObserver = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            ApplicationIntent.shared.applicationActivated(pid: app.processIdentifier)
        }
        fallbackInputMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { event in
            // With AX permission the event tap handles input synchronously, including our shortcut key.
            guard !AXIsProcessTrusted(), event.cgEvent.map({ !SyntheticInput.isOurs($0) }) ?? true else { return }
            ApplicationIntent.shared.interrupt()
        }
    }

    func cancel() {
        ApplicationIntent.shared.interrupt()
        commandTask?.cancel()
        commandTask = nil
        windowMover.cancel()
    }

    func restoreLastWindowLayout() {
        cancel()
        guard let display = ShortcutDisplayContext.capture() else { return }
        let action = ApplicationIntent.shared.begin(sourcePID: workspace.frontmostApplication?.processIdentifier)
        windowMover.restoreLastLayout(action: action, display: display)
    }

    deinit {
        commandTask?.cancel()
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        if let fallbackInputMonitor { NSEvent.removeMonitor(fallbackInputMonitor) }
    }

    func execute(_ action: ShortcutAction, targetDisplay: ShortcutDisplayContext? = nil) {
        cancel()
        if case let .application(target, _) = action,
           let route = LegacyApplication.route(identifier: target.bundleIdentifier, path: target.applicationPath) {
            AppRouter.shared.send(route)
            return
        }

        switch action {
        case let .application(target, mode):
            openApplication(target, mode: mode, display: targetDisplay)
        case let .finderFolder(path):
            openFinder(path: path)
        case let .terminal(fallbackPath, useFrontmostFinder):
            openTerminal(fallbackPath: fallbackPath, useFrontmostFinder: useFrontmostFinder)
        case .showDesktop:
            if !SystemShowDesktopShortcut.perform() { NSSound.beep() }
        case let .windowLayout(layout):
            if !WindowLayoutManager.apply(layout) { NSSound.beep() }
        case let .remap(target):
            SyntheticKeySender.send(target)
        }
    }

    private func openApplication(_ target: ApplicationTarget, mode: ApplicationOpenMode, display: ShortcutDisplayContext?) {
        let applicationURL = resolvedApplicationURL(for: target)
        let identifier = applicationURL.flatMap { Bundle(url: $0)?.bundleIdentifier } ?? target.bundleIdentifier
        let behavior = preferences().windowBehavior(for: identifier)
        let display = behavior.moveWindows ? (display ?? ShortcutDisplayContext.capture()) : nil
        let running = identifier.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }
            ?? workspace.runningApplications.first { app in
                applicationURL != nil && app.bundleURL?.standardizedFileURL == applicationURL?.standardizedFileURL
            }
        let action = ApplicationIntent.shared.begin(sourcePID: workspace.frontmostApplication?.processIdentifier,
                                                    targetPID: running?.processIdentifier)
        let plan = applicationLaunchPlan(mode: mode, running: running != nil, hasURL: applicationURL != nil, hasDisplay: display != nil)
        if let running {
            // Activation is the visible part of an activate-existing shortcut. Start it
            // immediately and keep window placement as a guarded background refinement.
            // This is especially important for a full-screen window in another Space:
            // waiting for AX inspection first makes the shortcut feel stuck even though
            // there is no movable window to prepare.
            if plan.activate_now != 0 { activateImmediately(running) }
            if plan.open_existing_background != 0, let applicationURL {
                openInBackground(applicationURL, mode: mode, display: nil,
                                 restoreMinimized: false, action: action)
                return
            }
            prepare(running, display: display, scope: .existing, restoreMinimized: behavior.restoreMinimized,
                    action: action) { [weak self] report in
                guard let self, action.isActive() else { return }
                // Only a successful, empty inventory justifies reopening. Unknown is not windowless.
                let decision = applicationLaunchPlan(mode: mode, running: true, hasURL: applicationURL != nil,
                    hasDisplay: display != nil, report: report)
                if decision.reopen_existing != 0, let applicationURL {
                    self.openInBackground(applicationURL, mode: mode, display: display,
                                          restoreMinimized: behavior.restoreMinimized, action: action)
                } else {
                    self.activate(running, mode: mode, display: display, restoreMinimized: behavior.restoreMinimized,
                                  report: report, action: action)
                }
            }
        } else if plan.launch != 0, let applicationURL {
            openInBackground(applicationURL, mode: mode, display: display,
                             restoreMinimized: behavior.restoreMinimized, action: action)
        } else { NSSound.beep() }
    }

    private func openInBackground(_ url: URL, mode: ApplicationOpenMode, display: ShortcutDisplayContext?,
                                  restoreMinimized: Bool, action: ApplicationActionToken) {
        guard action.isActive() else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        // Launch completion may arrive after the user has switched tasks. Only our guarded callback activates.
        configuration.activates = false
        workspace.openApplication(at: url, configuration: configuration) { [weak self] app, _ in
            Task { @MainActor in
                guard let self, action.isActive() else { return }
                guard let app else { NSSound.beep(); return }
                action.setTarget(app.processIdentifier)
                if applicationLaunchPlan(mode: mode, running: true, hasURL: true, hasDisplay: display != nil).activate_now != 0 { self.activateImmediately(app) }
                self.prepare(app, display: display, scope: .appearing(excluding: []),
                             restoreMinimized: restoreMinimized, action: action) { [weak self] report in
                    self?.activate(app, mode: mode, display: display, restoreMinimized: restoreMinimized,
                                   report: report, action: action)
                }
            }
        }
    }

    private func prepare(_ app: NSRunningApplication, display: ShortcutDisplayContext?, scope: WindowCaptureScope,
                         restoreMinimized: Bool, action: ApplicationActionToken,
                         completion: @escaping (WindowMoveReport) -> Void) {
        guard action.isActive(), !app.isTerminated else { return }
        guard let display else {
            var report = WindowMoveReport()
            report.isComplete = true
            completion(report)
            return
        }
        windowMover.move(pid: app.processIdentifier, display: display, scope: scope,
                         restoreMinimized: restoreMinimized, action: action, completion: completion)
    }

    private func activate(_ app: NSRunningApplication, mode: ApplicationOpenMode, display: ShortcutDisplayContext?,
                          restoreMinimized: Bool, report: WindowMoveReport, action: ApplicationActionToken) {
        guard action.isActive(), !app.isTerminated else { return }
        activateImmediately(app)
        let decision = applicationLaunchPlan(mode: mode, running: true, hasURL: true, hasDisplay: display != nil, report: report)
        guard decision.request_new_window != 0 else { return }
        commandTask = Task { [weak self] in
            guard let self else { return }
            let deadline = ProcessInfo.processInfo.systemUptime + 0.8
            while action.isActive(), !Task.isCancelled, !app.isTerminated,
                  ProcessInfo.processInfo.systemUptime < deadline {
                if action.canSend(to: app.processIdentifier,
                                  frontmostPID: self.workspace.frontmostApplication?.processIdentifier) {
                    // Target the process as well as checking focus: a focus race cannot send Command+N to another app.
                    SyntheticKeySender.send(KeyCombination(keyCode: 45, modifiers: [.command]), to: app.processIdentifier)
                    if decision.followup_prepare != 0, let display {
                        self.prepare(app, display: display, scope: .appearing(excluding: report.knownIDs),
                                     restoreMinimized: restoreMinimized, action: action) { _ in }
                    }
                    return
                }
                do { try await Task.sleep(nanoseconds: 20_000_000) }
                catch { return }
            }
            if action.isActive(), !Task.isCancelled, let display {
                self.windowMover.showFeedback("未能激活目标应用，新建窗口未执行。", display: display)
            }
        }
    }

    private func activateImmediately(_ app: NSRunningApplication) {
        if app.isHidden { app.unhide() }
        app.activate()
    }

    private func openFinder(path: String) {
        let expandedPath = NSString(string: path).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expandedPath) else {
            NSSound.beep()
            return
        }
        if AccessibilityPermission.isGranted, FinderPathResolver.raiseWindow(showing: expandedPath) {
            return
        }
        workspace.open(URL(fileURLWithPath: expandedPath, isDirectory: true))
    }

    private func openTerminal(fallbackPath: String, useFrontmostFinder: Bool) {
        let resolvedPath: String
        if useFrontmostFinder, let finderPath = FinderPathResolver.frontmostFinderPath() {
            resolvedPath = finderPath
        } else {
            resolvedPath = NSString(string: fallbackPath).expandingTildeInPath
        }

        guard FileManager.default.fileExists(atPath: resolvedPath),
              let terminalURL = workspace.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
        else {
            NSSound.beep()
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        workspace.open(
            [URL(fileURLWithPath: resolvedPath, isDirectory: true)],
            withApplicationAt: terminalURL,
            configuration: configuration
        )
    }

    private func resolvedApplicationURL(for target: ApplicationTarget) -> URL? {
        if let identifier = target.bundleIdentifier,
           let url = workspace.urlForApplication(withBundleIdentifier: identifier) {
            return url
        }
        let path = NSString(string: target.applicationPath).expandingTildeInPath
        return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
    }


}

private enum SystemShowDesktopShortcut {
    private static let preferencesDomain = "com.apple.symbolichotkeys"
    private static let symbolicHotKeysKey = "AppleSymbolicHotKeys"
    private static let showDesktopID = "36"

    static func perform() -> Bool {
        guard let shortcut = resolveShortcut(),
              let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: shortcut.keyCode,
                  keyDown: true
              ),
              let keyUp = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: shortcut.keyCode,
                  keyDown: false
              )
        else {
            return false
        }

        for event in [keyDown, keyUp] {
            event.flags = shortcut.flags
            event.post(tap: .cghidEventTap)
        }
        return true
    }

    private static func resolveShortcut() -> (keyCode: CGKeyCode, flags: CGEventFlags)? {
        let domain = AppEnvironment.shortcutsDefaults.persistentDomain(forName: preferencesDomain)
        let symbolicHotKeys = domain?[symbolicHotKeysKey] as? [String: Any]
        let showDesktop = symbolicHotKeys?[showDesktopID] as? [String: Any]
        let value = showDesktop?["value"] as? [String: Any]
        let parameters = value?["parameters"] as? [Any]
        let key = parameters.flatMap { $0.count >= 3 ? integer(from: $0[1]) : nil }
        let modifiers = parameters.flatMap { $0.count >= 3 ? integer(from: $0[2]) : nil }
        let plan = aether_desktop_shortcut_plan(showDesktop == nil ? 0 : 1,
            (showDesktop?["enabled"] as? Bool) == false ? 1 : 0,
            key != nil && modifiers != nil ? 1 : 0, Int64(key ?? 0), Int64(modifiers ?? 0), CGEventFlags.maskSecondaryFn.rawValue)
        return plan.enabled == 0 ? nil : (CGKeyCode(plan.key), CGEventFlags(rawValue: plan.flags))
    }

    private static func integer(from value: Any) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let integer = value as? Int { return integer }
        return nil
    }
}

private func applicationLaunchPlan(mode: ApplicationOpenMode, running: Bool, hasURL: Bool,
                                   hasDisplay: Bool, report: WindowMoveReport? = nil) -> AetherApplicationLaunchPlan {
    aether_application_launch_plan(.init(running: running ? 1 : 0, has_url: hasURL ? 1 : 0,
        has_display: hasDisplay ? 1 : 0, new_window: mode == .newWindow ? 1 : 0,
        has_windows: report?.hasWindows == true ? 1 : 0, read_failed: report?.readFailure == nil ? 0 : 1,
        timed_out: report?.timedOut == true ? 1 : 0, display_disconnected: report?.displayDisconnected == true ? 1 : 0))
}
