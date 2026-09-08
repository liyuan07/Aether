import AppKit
import ApplicationServices

enum AccessibilityPermission {
    static var isGranted: Bool {
        AXIsProcessTrusted()
    }

    static func request() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }
}

enum AXHelpers {
    static func value(_ element: AXUIElement, attribute: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value
    }

    static func string(_ element: AXUIElement, attribute: CFString) -> String? {
        value(element, attribute: attribute) as? String
    }

    static func elements(_ element: AXUIElement, attribute: CFString) -> [AXUIElement] {
        value(element, attribute: attribute) as? [AXUIElement] ?? []
    }

    static func bool(_ element: AXUIElement, attribute: CFString) -> Bool {
        value(element, attribute: attribute) as? Bool ?? false
    }

    static func isAttributeSettable(_ element: AXUIElement, attribute: CFString) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute, &settable) == .success
            && settable.boolValue
    }
}

enum ApplicationWindowRestorer {
    static func restoreMinimizedWindows(for application: NSRunningApplication) {
        guard AccessibilityPermission.isGranted else { return }
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        for window in AXHelpers.elements(appElement, attribute: kAXWindowsAttribute as CFString)
        where AXHelpers.bool(window, attribute: kAXMinimizedAttribute as CFString) {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
    }
}

enum ApplicationFrontmostController {
    static func makeFrontmost(_ application: NSRunningApplication) -> Bool {
        guard AccessibilityPermission.isGranted else { return false }
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        return AXUIElementSetAttributeValue(
            appElement,
            kAXFrontmostAttribute as CFString,
            kCFBooleanTrue
        ) == .success
    }
}

enum ApplicationWindowMinimizer {
    static func minimizeFocusedWindow(for application: NSRunningApplication) -> Bool {
        guard AccessibilityPermission.isGranted else { return false }
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        let windowValue = AXHelpers.value(appElement, attribute: kAXFocusedWindowAttribute as CFString)
            ?? AXHelpers.value(appElement, attribute: kAXMainWindowAttribute as CFString)
        guard let windowValue else {
            return AXHelpers.elements(appElement, attribute: kAXWindowsAttribute as CFString).isEmpty
        }
        let window = unsafeBitCast(windowValue, to: AXUIElement.self)
        guard AXHelpers.string(window, attribute: kAXRoleAttribute as CFString) == kAXWindowRole,
              AXHelpers.isAttributeSettable(window, attribute: kAXMinimizedAttribute as CFString)
        else { return false }
        if AXHelpers.bool(window, attribute: kAXMinimizedAttribute as CFString) { return true }
        return AXUIElementSetAttributeValue(
            window,
            kAXMinimizedAttribute as CFString,
            kCFBooleanTrue
        ) == .success
    }

}

enum FinderPathResolver {
    static func frontmostFinderPath() -> String? {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder",
              let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first
        else { return nil }

        let appElement = AXUIElementCreateApplication(finder.processIdentifier)
        guard let window = AXHelpers.value(appElement, attribute: kAXFocusedWindowAttribute as CFString) else {
            return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first?.path
        }
        let windowElement = unsafeBitCast(window, to: AXUIElement.self)
        guard let document = AXHelpers.string(windowElement, attribute: kAXDocumentAttribute as CFString) else {
            return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first?.path
        }
        if let url = URL(string: document), url.isFileURL {
            return url.path
        }
        return document.hasPrefix("/") ? document : nil
    }

    static func raiseWindow(showing path: String) -> Bool {
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else {
            return false
        }
        let expected = URL(fileURLWithPath: path).standardizedFileURL
        let appElement = AXUIElementCreateApplication(finder.processIdentifier)
        for window in AXHelpers.elements(appElement, attribute: kAXWindowsAttribute as CFString) {
            guard let document = AXHelpers.string(window, attribute: kAXDocumentAttribute as CFString),
                  let url = URL(string: document), url.isFileURL,
                  url.standardizedFileURL == expected
            else { continue }
            _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            finder.activate(options: [.activateAllWindows])
            return true
        }
        return false
    }
}
