import AppKit
import Foundation

/// Immutable storage configuration, installed before any feature is initialized.
public enum AppEnvironment {
    private static let testing = ProcessInfo.processInfo.processName.contains("xctest") || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    private static let testID = UUID().uuidString
    public static var root: URL = testing
        ? FileManager.default.temporaryDirectory.appendingPathComponent("AetherTests-" + testID)
        : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Aether", isDirectory: true)
    public static var clipboardDefaults = UserDefaults(suiteName: testing ? "AetherTests.clipboard." + testID : "com.liyuan.aether.clipboard")!
    public static var shortcutsDefaults = UserDefaults(suiteName: testing ? "AetherTests.shortcuts." + testID : "com.liyuan.aether.shortcuts")!
    public static var appDefaults = testing
        ? UserDefaults(suiteName: "AetherTests.app." + testID)!
        : .standard
    public static var controlCenterDefaults = testing
        ? UserDefaults(suiteName: "AetherTests.control-center." + testID)!
        : .standard
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
        case .prompt: "Prompt 优化"
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
