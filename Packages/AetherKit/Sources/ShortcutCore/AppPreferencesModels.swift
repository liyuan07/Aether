import CAetherCore
import Foundation

public struct AppGeneralPreferences: Codable, Hashable, Sendable {
    public var launchAtLogin = RustPreferences.defaults.launch != 0
    public var blockAutomaticABC = RustPreferences.defaults.block != 0
    public var showModifierButtons = RustPreferences.defaults.show != 0

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case launchAtLogin, blockAutomaticABC, showModifierButtons
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? launchAtLogin
        blockAutomaticABC = try container.decodeIfPresent(Bool.self, forKey: .blockAutomaticABC) ?? blockAutomaticABC
        showModifierButtons = try container.decodeIfPresent(
            Bool.self,
            forKey: .showModifierButtons
        ) ?? showModifierButtons
    }
}

public struct ApplicationShortcutPreferences: Codable, Hashable, Sendable {
    public var defaultBundleIdentifiers: [String: String] = [:]
    public var orderedBundleIdentifiers: [String: [String]] = [:]
    public var holdDuration: TimeInterval = RustPreferences.defaults.hold
    public var restoreMinimizedWindows = RustPreferences.defaults.restore != 0
    public var windowBehaviorOverrides: [String: ApplicationWindowBehavior] = [:]

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case defaultBundleIdentifiers, orderedBundleIdentifiers, holdDuration, restoreMinimizedWindows, windowBehaviorOverrides
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        defaultBundleIdentifiers = try container.decodeIfPresent(
            [String: String].self,
            forKey: .defaultBundleIdentifiers
        ) ?? defaultBundleIdentifiers
        orderedBundleIdentifiers = try container.decodeIfPresent(
            [String: [String]].self,
            forKey: .orderedBundleIdentifiers
        ) ?? orderedBundleIdentifiers
        holdDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .holdDuration) ?? holdDuration
        restoreMinimizedWindows = try container.decodeIfPresent(Bool.self, forKey: .restoreMinimizedWindows) ?? (RustPreferences.defaults.restore != 0)
        windowBehaviorOverrides = try container.decodeIfPresent([String: ApplicationWindowBehavior].self,
                                                               forKey: .windowBehaviorOverrides) ?? [:]
    }

    public func normalizedHoldDuration() -> TimeInterval {
        aether_preferences_hold(holdDuration)
    }

    public func windowBehavior(for identifier: String?) -> (moveWindows: Bool, restoreMinimized: Bool) {
        let behavior = identifier.flatMap { windowBehaviorOverrides[$0] } ?? .followGlobal
        let tag: UInt8
        switch behavior { case .followGlobal: tag = 0; case .keepMinimized: tag = 1; case .restoreMinimized: tag = 2; case .activateOnly: tag = 3 }
        let result = aether_preferences_window(tag, restoreMinimizedWindows ? 1 : 0)
        return (result & 1 != 0, result & 2 != 0)
    }
}

public enum ApplicationWindowBehavior: String, Codable, CaseIterable, Sendable {
    case followGlobal, keepMinimized, restoreMinimized, activateOnly

    public var title: String {
        switch self {
        case .followGlobal: "跟随全局设置"
        case .keepMinimized: "保留最小化窗口"
        case .restoreMinimized: "恢复最小化窗口"
        case .activateOnly: "仅激活，不移动"
        }
    }
}

public struct RegisteredApplication: Identifiable, Hashable, Sendable {
    public var bundleIdentifier: String
    public var displayName: String
    public var applicationPath: String
    public var initial: String

    public var id: String { bundleIdentifier + "|" + applicationPath }

    public init(bundleIdentifier: String, displayName: String, applicationPath: String, initial: String? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.applicationPath = applicationPath
        self.initial = initial ?? ApplicationInitialResolver.initial(for: displayName) ?? ""
    }
}

public struct RegisteredApplicationGroup: Identifiable, Hashable, Sendable {
    public var initial: String
    public var applications: [RegisteredApplication]

    public var id: String { initial }

    public init(initial: String, applications: [RegisteredApplication]) {
        self.initial = initial
        self.applications = applications
    }
}

public enum ApplicationOrderResolver {
    public static func ordered(
        _ applications: [RegisteredApplication],
        preferredBundleIdentifiers: [String]
    ) -> [RegisteredApplication] {
        RustApplicationOrder.ordered(applications, preferences: preferredBundleIdentifiers)
    }

    public static func updatingPreference(
        _ existingPreference: [String],
        availableApplications: [RegisteredApplication],
        moving offsets: IndexSet,
        toOffset destination: Int
    ) -> [String]? {
        RustApplicationOrder.move(existingPreference, applications: availableApplications, offsets: offsets, destination: destination)
    }
}

public enum ApplicationInitialResolver {
    public static func initial(for displayName: String) -> String? {
        let mutable = NSMutableString(string: displayName)
        CFStringTransform(mutable, nil, kCFStringTransformToLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)
        return String(mutable).uppercased().first(where: { $0 >= "A" && $0 <= "Z" }).map(String.init)
    }
}

public enum ApplicationLetterKey {
    public static func letter(for keyCode: UInt16) -> String? {
        let letter = aether_application_letter(keyCode)
        return letter == 0 ? nil : String(UnicodeScalar(letter))
    }
    public static func keyCode(for letter: String) -> UInt16? {
        var upper = letter.uppercased().precomposedStringWithCanonicalMapping
        let key = upper.withUTF8 { aether_application_letter_key($0.baseAddress,$0.count) }
        return key < 0 ? nil : UInt16(key)
    }
}

public enum ABCSwitchDecision: Equatable, Sendable {
    case ignore
    case allowManualSwitch
    case restoreDoubao
}

public enum PhysicalInputSwitchKey {
    public static func matches(keyCode: UInt16) -> Bool {
        aether_physical_input_switch(keyCode) != 0
    }
}

public struct ABCSwitchGuardState: Equatable, Sendable {
    public static let manualAuthorizationDuration: TimeInterval = 5

    public private(set) var isManualABCSessionActive = false
    private var physicalInputSwitchKeyPressedAt: TimeInterval?

    public init() {}

    public mutating func physicalInputSwitchKeyWasPressed(at uptime: TimeInterval) {
        physicalInputSwitchKeyPressedAt = uptime
    }

    public mutating func decision(
        blockAutomaticABC: Bool,
        switchedToABC: Bool,
        canObservePhysicalKey: Bool,
        uptime: TimeInterval
    ) -> ABCSwitchDecision {
        let result = aether_abc_decide(.init(pressed: physicalInputSwitchKeyPressedAt ?? 0,
            has_pressed: physicalInputSwitchKeyPressedAt == nil ? 0 : 1, manual: isManualABCSessionActive ? 1 : 0, decision: 0),
            blockAutomaticABC ? 1 : 0, switchedToABC ? 1 : 0, canObservePhysicalKey ? 1 : 0, uptime, Self.manualAuthorizationDuration)
        physicalInputSwitchKeyPressedAt = result.has_pressed != 0 ? result.pressed : nil
        isManualABCSessionActive = result.manual != 0
        return result.decision == 1 ? .allowManualSwitch : result.decision == 2 ? .restoreDoubao : .ignore
    }

    public mutating func reset() {
        isManualABCSessionActive = false
        physicalInputSwitchKeyPressedAt = nil
    }
}

public struct AppPreferencesConfiguration: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = Int(RustPreferences.defaults.version)

    public var schemaVersion = currentSchemaVersion
    public var app = AppGeneralPreferences()
    public var applicationShortcuts = ApplicationShortcutPreferences()

    public init() {}

    private enum CodingKeys: String, CodingKey { case schemaVersion, app, general, applicationShortcuts }
    private enum LegacyGeneralKeys: String, CodingKey { case launchAtLogin, blockAutomaticABC }

    public init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let storedApp = try container.decodeIfPresent(AppGeneralPreferences.self, forKey: .app) {
            app = storedApp
        }
        applicationShortcuts = try container.decodeIfPresent(
            ApplicationShortcutPreferences.self,
            forKey: .applicationShortcuts
        ) ?? applicationShortcuts
        if container.contains(.general) {
            let legacy = try container.nestedContainer(keyedBy: LegacyGeneralKeys.self, forKey: .general)
            let hasApp = container.contains(.app)
            let launch = aether_preferences_legacy_launch(hasApp ? 1 : 0) != 0
                ? try legacy.decodeIfPresent(Bool.self, forKey: .launchAtLogin) : nil
            let block = try legacy.decodeIfPresent(Bool.self, forKey: .blockAutomaticABC)
            let migrated = aether_preferences_migrate(.init(launch: app.launchAtLogin ? 1 : 0,
                block: app.blockAutomaticABC ? 1 : 0, show: app.showModifierButtons ? 1 : 0),
                hasApp ? 1 : 0, launch == true ? 1 : 0, launch == nil ? 0 : 1,
                block == true ? 1 : 0, block == nil ? 0 : 1)
            app.launchAtLogin = migrated.launch != 0
            app.blockAutomaticABC = migrated.block != 0
            app.showModifierButtons = migrated.show != 0
        }
        schemaVersion = Self.currentSchemaVersion
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(app, forKey: .app)
        try container.encode(applicationShortcuts, forKey: .applicationShortcuts)
    }
}

public struct KeyPilotConfigurationArchive: Codable, Sendable {
    public static let currentSchemaVersion = Int(RustPreferences.defaults.archive_version)

    public var schemaVersion = currentSchemaVersion
    public var shortcuts: [ShortcutRule]
    public var preferences: AppPreferencesConfiguration

    public init(shortcuts: [ShortcutRule], preferences: AppPreferencesConfiguration) {
        self.shortcuts = shortcuts
        self.preferences = preferences
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, shortcuts, preferences, inputAutomation }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Int(RustPreferences.defaults.archive_default)
        shortcuts = try container.decode([ShortcutRule].self, forKey: .shortcuts)
        preferences = try container.decodeIfPresent(AppPreferencesConfiguration.self, forKey: .preferences)
            ?? container.decode(AppPreferencesConfiguration.self, forKey: .inputAutomation)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(shortcuts, forKey: .shortcuts)
        try container.encode(preferences, forKey: .preferences)
    }
}
