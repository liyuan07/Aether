import SharedSupport
import AppKit
import ShortcutCore

@MainActor
final class ActionExecutor {
    private let workspace = NSWorkspace.shared
    private let windowMover = ApplicationWindowMover()

    func execute(_ action: ShortcutAction, targetDisplay: ShortcutDisplayContext? = nil) {
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
        windowMover.cancelPendingActivations()
        let resolvedURL = resolvedApplicationURL(for: target)
        let identifier = resolvedURL.flatMap { Bundle(url: $0)?.bundleIdentifier } ?? target.bundleIdentifier
        let findApplication: @MainActor () -> NSRunningApplication? = {
            if let identifier {
                return NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first
            }
            guard let resolvedURL else { return nil }
            return NSWorkspace.shared.runningApplications.first { $0.bundleURL?.standardizedFileURL == resolvedURL.standardizedFileURL }
        }
        let runningApplication = findApplication()
        if let runningApplication {
            let activate: (Bool) -> Void = { [self] hasWindows in
                guard !runningApplication.isTerminated else { return }
                if runningApplication.isHidden { runningApplication.unhide() }
                if display == nil { ApplicationWindowRestorer.restoreMinimizedWindows(for: runningApplication) }
                if mode == .activateExisting, !hasWindows, let applicationURL = resolvedURL {
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.activates = true
                    workspace.openApplication(at: applicationURL, configuration: configuration) { _, _ in }
                } else {
                    runningApplication.activate(options: [.activateAllWindows])
                    if mode == .newWindow { sendNewWindow(after: 0.12) }
                }
            }
            if let display {
                let key = identifier ?? resolvedURL?.standardizedFileURL.path ?? target.applicationPath
                windowMover.start(key: key, display: display, application: findApplication, beforeActivation: activate)
            } else {
                activate(false)
            }
            return
        }

        guard let applicationURL = resolvedURL else {
            NSSound.beep()
            return
        }
        if let display {
            let key = identifier ?? applicationURL.standardizedFileURL.path
            windowMover.start(key: key, display: display, application: findApplication)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        workspace.openApplication(at: applicationURL, configuration: configuration) { _, _ in
            guard mode == .newWindow else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                self.sendNewWindow(after: 0)
            }
        }
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

    private func sendNewWindow(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            SyntheticKeySender.send(KeyCombination(keyCode: 45, modifiers: [.command]))
        }
    }
}

private enum SystemShowDesktopShortcut {
    private static let preferencesDomain = "com.apple.symbolichotkeys"
    private static let symbolicHotKeysKey = "AppleSymbolicHotKeys"
    private static let showDesktopID = "36"
    private static let defaultF11KeyCode: CGKeyCode = 103

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
        guard let domain = AppEnvironment.shortcutsDefaults.persistentDomain(forName: preferencesDomain),
              let symbolicHotKeys = domain[symbolicHotKeysKey] as? [String: Any],
              let showDesktop = symbolicHotKeys[showDesktopID] as? [String: Any]
        else {
            return (defaultF11KeyCode, .maskSecondaryFn)
        }

        if let enabled = showDesktop["enabled"] as? Bool, !enabled {
            return nil
        }
        guard let value = showDesktop["value"] as? [String: Any],
              let parameters = value["parameters"] as? [Any],
              parameters.count >= 3,
              let keyCodeValue = integer(from: parameters[1]),
              let modifierValue = integer(from: parameters[2]),
              keyCodeValue >= 0,
              keyCodeValue <= Int(UInt16.max),
              modifierValue >= 0
        else {
            return (defaultF11KeyCode, .maskSecondaryFn)
        }

        return (
            CGKeyCode(keyCodeValue),
            CGEventFlags(rawValue: UInt64(modifierValue))
        )
    }

    private static func integer(from value: Any) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let integer = value as? Int { return integer }
        return nil
    }
}
