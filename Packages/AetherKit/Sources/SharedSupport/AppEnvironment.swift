import AppKit
import Foundation

/// Immutable storage configuration, installed before any feature is initialized.
public enum AppEnvironment {
    private static let testing = ProcessInfo.processInfo.processName.contains("xctest") || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    private static let testID = UUID().uuidString
    public static let resourceProfile: ResourceProfile? = {
        if testing { return nil }
        do { return try ResourceProfile.load(path: ProcessInfo.processInfo.environment["AETHER_RESOURCE_PROFILE"]) }
        catch { fatalError("Invalid Aether resource profile; user storage was not selected") }
    }()
    public static var isResourceProfiling: Bool { resourceProfile != nil }
    public static var root: URL = resourceProfile?.dataRoot ?? (testing
        ? FileManager.default.temporaryDirectory.appendingPathComponent("AetherTests-" + testID)
        : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Aether", isDirectory: true))
    private static func preferences(_ feature: String) -> UserDefaults {
        if let profile = resourceProfile {
            let domain = profile.domainPrefix + "." + feature
            let defaults = UserDefaults(suiteName: domain)!
            defaults.setPersistentDomain(profile.preferences(feature: feature), forName: domain)
            return defaults
        }
        if testing { return UserDefaults(suiteName: "AetherTests." + feature + "." + testID)! }
        switch feature {
        case "clipboard": return UserDefaults(suiteName: "com.liyuan.aether.clipboard")!
        case "shortcuts": return UserDefaults(suiteName: "com.liyuan.aether.shortcuts")!
        default: return .standard
        }
    }
    public static var clipboardDefaults = preferences("clipboard")
    public static var shortcutsDefaults = preferences("shortcuts")
    public static var appDefaults = preferences("app")
    public static var controlCenterDefaults = preferences("control-center")
    public static var clipboardPasteboard: NSPasteboard = {
        if let profile = resourceProfile {
            let board = NSPasteboard(name: .init(profile.domainPrefix + ".pasteboard"))
            board.clearContents()
            return board
        }
        if testing { return NSPasteboard(name: .init("AetherTests.pasteboard." + testID)) }
        return .general
    }()
    public static func directory(_ feature: String) -> URL { root.appendingPathComponent(feature, isDirectory: true) }
}

public enum SettingsPage: String, CaseIterable, Identifiable {
    case general, clipboard, shortcuts, timer, prompt, ports, permissions
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .general: "通用"
        case .clipboard: "剪贴板"
        case .shortcuts: "快捷操作"
        case .timer: "计时与护眼"
        case .prompt: "提示词优化"
        case .ports: "端口"
        case .permissions: "权限"
        }
    }
    public var symbol: String {
        switch self {
        case .general: "gearshape"
        case .clipboard: "doc.on.clipboard"
        case .shortcuts: "command"
        case .timer: "timer"
        case .prompt: "wand.and.stars"
        case .ports: "cable.connector"
        case .permissions: "hand.raised"
        }
    }
}

public extension SettingsPage {
    /// Permission deep links still work; startup and permissions now share one page.
    var navigationPage: SettingsPage { self == .permissions ? .general : self }
    static var navigationPages: [SettingsPage] { [.general, .clipboard, .shortcuts, .timer, .prompt, .ports] }
}

public enum AppRoute: Equatable {
    case overview, clipboard, prompt, settings(SettingsPage), dismissPanels
}

/// Features publish typed intents; only the application owns window presentation.
@MainActor public final class AppRouter {
    public static let shared = AppRouter()
    public var handler: ((AppRoute) -> Void)?
    public func send(_ route: AppRoute) { handler?(route) }
    private init() {}
}
