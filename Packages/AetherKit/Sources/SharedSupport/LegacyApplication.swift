import Foundation

/// Known predecessors are routed inside Aether; unrelated applications retain
/// their original launch behavior. Stored user rules are never rewritten.
public enum LegacyApplication: String, CaseIterable {
    case timer, clipboard, shortcuts
    public var bundleIdentifier: String {
        switch self {
        case .timer: "com.liyuan.packagecounter"
        case .clipboard: "com.liyuan07.clipboard"
        case .shortcuts: "com.liyuan.keypilot"
        }
    }
    public var path: String {
        switch self {
        case .timer: "/Applications/package counter.app"
        case .clipboard: "/Applications/Clipboard.app"
        case .shortcuts: "/Applications/KeyPilot.app"
        }
    }
    public var route: AppRoute {
        switch self {
        case .timer: .overview
        case .clipboard: .clipboard
        case .shortcuts: .settings(.shortcuts)
        }
    }
    public static func route(identifier: String?, path: String) -> AppRoute? {
        allCases.first { app in
            if let identifier { return identifier == app.bundleIdentifier }
            return path == app.path
        }?.route
    }
}
