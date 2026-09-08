import SharedSupport
import AppKit
import ApplicationServices
import ShortcutCore

enum WindowLayoutManager {
    static func apply(_ layout: WindowLayout) -> Bool {
        guard AccessibilityPermission.isGranted,
              let application = NSWorkspace.shared.frontmostApplication,
              application.bundleIdentifier != Bundle.main.bundleIdentifier
        else { return false }

        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        guard let windowValue = AXHelpers.value(
                  applicationElement,
                  attribute: kAXFocusedWindowAttribute as CFString
              )
        else { return false }
        let window = unsafeBitCast(windowValue, to: AXUIElement.self)
        guard !AXHelpers.bool(window, attribute: "AXFullScreen" as CFString),
              let menuBarValue = AXHelpers.value(
                  applicationElement,
                  attribute: kAXMenuBarAttribute as CFString
              )
        else { return false }

        let menuBar = unsafeBitCast(menuBarValue, to: AXUIElement.self)
        guard let menuItem = menuItem(in: menuBar, identifier: layout.nativeMenuIdentifier) else {
            return false
        }
        return AXUIElementPerformAction(menuItem, kAXPressAction as CFString) == .success
    }

    private static func menuItem(
        in element: AXUIElement,
        identifier: String,
        remainingDepth: Int = 6
    ) -> AXUIElement? {
        if AXHelpers.string(element, attribute: "AXIdentifier" as CFString) == identifier {
            return element
        }
        guard remainingDepth > 0 else { return nil }
        for child in AXHelpers.elements(element, attribute: kAXChildrenAttribute as CFString) {
            if let result = menuItem(
                in: child,
                identifier: identifier,
                remainingDepth: remainingDepth - 1
            ) {
                return result
            }
        }
        return nil
    }
}

private extension WindowLayout {
    var nativeMenuIdentifier: String {
        switch self {
        case .leftHalf: "_zoomLeft:"
        case .rightHalf: "_zoomRight:"
        case .topHalf: "_zoomTop:"
        case .bottomHalf: "_zoomBottom:"
        case .topLeft: "_zoomTopLeft:"
        case .topRight: "_zoomTopRight:"
        case .bottomLeft: "_zoomBottomLeft:"
        case .bottomRight: "_zoomBottomRight:"
        }
    }
}
