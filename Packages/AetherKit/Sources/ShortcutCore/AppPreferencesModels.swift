import Foundation

public struct AppGeneralPreferences: Codable, Hashable, Sendable {
    public var launchAtLogin = false
    public var blockAutomaticABC = false
    public var showModifierButtons = true

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
    public var holdDuration: TimeInterval = 0.5
    public var restoreMinimizedWindows = true
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
        restoreMinimizedWindows = try container.decodeIfPresent(Bool.self, forKey: .restoreMinimizedWindows) ?? true
        windowBehaviorOverrides = try container.decodeIfPresent([String: ApplicationWindowBehavior].self,
                                                               forKey: .windowBehaviorOverrides) ?? [:]
    }

    public func normalizedHoldDuration() -> TimeInterval {
        min(max(holdDuration, 0.3), 1.5)
    }

    public func windowBehavior(for identifier: String?) -> (moveWindows: Bool, restoreMinimized: Bool) {
        switch identifier.flatMap({ windowBehaviorOverrides[$0] }) ?? .followGlobal {
        case .followGlobal: (true, restoreMinimizedWindows)
        case .keepMinimized: (true, false)
        case .restoreMinimized: (true, true)
        case .activateOnly: (false, false)
        }
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
        var applicationsByBundleIdentifier: [String: RegisteredApplication] = [:]
        for application in applications where applicationsByBundleIdentifier[application.bundleIdentifier] == nil {
            applicationsByBundleIdentifier[application.bundleIdentifier] = application
        }
        let preferred = preferredBundleIdentifiers.compactMap { applicationsByBundleIdentifier[$0] }
        let preferredIdentifiers = Set(preferred.map(\.bundleIdentifier))
        var appendedIdentifiers = preferredIdentifiers
        return preferred + applications.filter { appendedIdentifiers.insert($0.bundleIdentifier).inserted }
    }

    public static func updatingPreference(
        _ existingPreference: [String],
        availableApplications: [RegisteredApplication],
        moving offsets: IndexSet,
        toOffset destination: Int
    ) -> [String]? {
        let orderedApplications = ordered(
            availableApplications,
            preferredBundleIdentifiers: existingPreference
        )
        guard !offsets.isEmpty,
              offsets.allSatisfy(orderedApplications.indices.contains),
              destination >= 0,
              destination <= orderedApplications.count
        else { return nil }

        var reordered = orderedApplications.map(\.bundleIdentifier)
        let movingIdentifiers = offsets.map { reordered[$0] }
        let removedBeforeDestination = offsets.filter { $0 < destination }.count
        let insertionIndex = destination - removedBeforeDestination
        for index in offsets.reversed() { reordered.remove(at: index) }
        reordered.insert(contentsOf: movingIdentifiers, at: insertionIndex)

        var seen = Set<String>()
        let normalizedPreference = existingPreference.filter { seen.insert($0).inserted }
        let availableIdentifiers = Set(reordered)
        var reorderedIterator = reordered.makeIterator()
        var result = normalizedPreference.map { identifier in
            availableIdentifiers.contains(identifier) ? reorderedIterator.next()! : identifier
        }
        let existingIdentifiers = Set(normalizedPreference)
        result.append(contentsOf: reordered.filter { !existingIdentifiers.contains($0) })
        return result
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
    private static let lettersByKeyCode: [UInt16: String] = [
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G",
        4: "H", 34: "I", 38: "J", 40: "K", 37: "L", 46: "M", 45: "N",
        31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U",
        9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z"
    ]

    public static func letter(for keyCode: UInt16) -> String? { lettersByKeyCode[keyCode] }
    public static func keyCode(for letter: String) -> UInt16? {
        lettersByKeyCode.first { $0.value == letter.uppercased() }?.key
    }
}

public enum ABCSwitchDecision: Equatable, Sendable {
    case ignore
    case allowManualSwitch
    case restoreDoubao
}

public enum PhysicalInputSwitchKey {
    public static func matches(keyCode: UInt16) -> Bool {
        switch keyCode {
        case 57, 63, 102, 104: true // Caps Lock/中英、Globe/Fn、日文英数、日文假名
        default: false
        }
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
        guard switchedToABC else {
            isManualABCSessionActive = false
            physicalInputSwitchKeyPressedAt = nil
            return .ignore
        }
        guard blockAutomaticABC, canObservePhysicalKey else { return .ignore }
        if isManualABCSessionActive { return .allowManualSwitch }
        if let pressedAt = physicalInputSwitchKeyPressedAt,
           uptime >= pressedAt,
           uptime - pressedAt <= Self.manualAuthorizationDuration {
            physicalInputSwitchKeyPressedAt = nil
            isManualABCSessionActive = true
            return .allowManualSwitch
        }
        physicalInputSwitchKeyPressedAt = nil
        return .restoreDoubao
    }

    public mutating func reset() {
        isManualABCSessionActive = false
        physicalInputSwitchKeyPressedAt = nil
    }
}

public struct AppPreferencesConfiguration: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 9

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
            if !container.contains(.app) {
                app.launchAtLogin = try legacy.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? app.launchAtLogin
            }
            app.blockAutomaticABC = try legacy.decodeIfPresent(Bool.self, forKey: .blockAutomaticABC) ?? app.blockAutomaticABC
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
    public static let currentSchemaVersion = 2

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
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
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
