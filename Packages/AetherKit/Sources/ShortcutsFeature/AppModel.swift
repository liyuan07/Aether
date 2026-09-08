import SharedSupport
import AppKit
import Combine
import ShortcutCore

struct ConflictFinding: Identifiable, Hashable {
    enum Confidence: Int, Comparable {
        case possible = 0
        case likely = 1
        case confirmed = 2

        static func < (lhs: Confidence, rhs: Confidence) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        var displayName: String {
            switch self {
            case .possible: "可能冲突"
            case .likely: "较可能冲突"
            case .confirmed: "确定冲突"
            }
        }
    }

    let id = UUID()
    let confidence: Confidence
    let message: String
}

@MainActor
final class AppModel: ObservableObject {
    private static let shortcutMigrationVersionKey = "defaultShortcutMigrationVersion"
    private static let shortcutGuideHoldDurationKey = "shortcutGuideHoldDuration"
    private static let shortcutGuideFavoriteIDsKey = "shortcutGuideFavoriteIDs"

    @Published private(set) var rules: [ShortcutRule]
    @Published private(set) var appPreferences: AppPreferencesConfiguration
    @Published private(set) var registeredApplications: [RegisteredApplication] = []
    @Published var selectedRuleID: UUID?
    @Published var permissionGranted = false
    @Published var inputMonitoringGranted = false
    @Published private(set) var shortcutGuideHoldDuration: TimeInterval
    @Published private(set) var shortcutGuideFavoriteIDs: Set<String>
    @Published private(set) var externalConflicts: [UUID: [ConflictFinding]] = [:]
    @Published private(set) var isScanningConflicts = false
    @Published private(set) var lastError: String?

    var onExecutableRulesChanged: (([ShortcutRule]) -> Void)?
    var onConflictScanRequested: (([ShortcutRule]) -> Void)?
    var onAppPreferencesChanged: ((AppPreferencesConfiguration) -> Void)?

    private let store: ShortcutRuleStore
    private let appPreferencesStore: AppPreferencesStore
    private let preferences: UserDefaults
    private var saveWorkItem: DispatchWorkItem?
    private var preferencesSaveWorkItem: DispatchWorkItem?
    private var isRecordingShortcut = false
    private var legacyApplicationTargets: [ApplicationTarget] = []

    init(
        store: ShortcutRuleStore = ShortcutRuleStore(fileURL: AppEnvironment.directory("Shortcuts").appendingPathComponent("shortcuts.json")),
        appPreferencesStore: AppPreferencesStore = AppPreferencesStore(fileURL: AppEnvironment.directory("Shortcuts").appendingPathComponent("preferences.json"), legacyFileURL: AppEnvironment.directory("Shortcuts").appendingPathComponent("input-automation.json")),
        preferences: UserDefaults = AppEnvironment.shortcutsDefaults
    ) {
        self.store = store
        self.appPreferencesStore = appPreferencesStore
        self.preferences = preferences
        if let stored = try? appPreferencesStore.load(persistingMigrations: true) {
            appPreferences = stored
        } else {
            let defaultConfiguration = AppPreferencesConfiguration()
            appPreferences = defaultConfiguration
            do {
                try appPreferencesStore.save(defaultConfiguration)
            } catch {
                lastError = "创建应用配置失败：\(error.localizedDescription)"
            }
        }
        shortcutGuideHoldDuration = ShortcutGuideConfiguration.normalizedHoldDuration(
            preferences.object(forKey: Self.shortcutGuideHoldDurationKey) as? TimeInterval
                ?? ShortcutGuideConfiguration.defaultHoldDuration
        )
        shortcutGuideFavoriteIDs = Set(
            preferences.stringArray(forKey: Self.shortcutGuideFavoriteIDsKey) ?? []
        )
        if let storedRules = try? store.load(), !storedRules.isEmpty {
            legacyApplicationTargets = storedRules.compactMap { rule in
                guard case let .application(target, _) = rule.action else { return nil }
                return target
            }
            let storedVersion = preferences.integer(forKey: Self.shortcutMigrationVersionKey)
            if storedVersion < DefaultShortcutRules.currentMigrationVersion {
                let migratedRules = DefaultShortcutRules.migrate(
                    storedRules,
                    fromVersion: storedVersion
                )
                do {
                    try store.save(migratedRules)
                    preferences.set(
                        DefaultShortcutRules.currentMigrationVersion,
                        forKey: Self.shortcutMigrationVersionKey
                    )
                    rules = migratedRules
                } catch {
                    rules = storedRules
                    lastError = "升级默认快捷键失败：\(error.localizedDescription)"
                }
            } else {
                rules = storedRules
            }
        } else {
            rules = DefaultShortcutRules.make()
            do {
                try store.save(rules)
                preferences.set(
                    DefaultShortcutRules.currentMigrationVersion,
                    forKey: Self.shortcutMigrationVersionKey
                )
            } catch {
                lastError = "保存默认快捷键失败：\(error.localizedDescription)"
            }
        }
        selectedRuleID = rules.first?.id
    }

    func rule(withID id: UUID?) -> ShortcutRule? {
        guard let id else { return nil }
        return rules.first { $0.id == id }
    }

    func update(_ rule: ShortcutRule) {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        let previous = rules[index]
        rules[index] = rule
        let conflictRelevantChange = previous.source != rule.source || previous.isEnabled != rule.isEnabled
        configurationDidChange(rescan: conflictRelevantChange)
    }

    func setEnabled(_ isEnabled: Bool, for id: UUID) {
        guard var rule = rule(withID: id) else { return }
        rule.isEnabled = isEnabled
        update(rule)
    }

    @discardableResult
    func addRule() -> UUID {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first?.path ?? "~/Desktop"
        let rule = ShortcutRule(
            name: "新快捷键",
            source: KeyCombination(keyCode: 45, modifiers: [.option, .shift]),
            action: .finderFolder(path: desktop),
            isEnabled: false
        )
        rules.append(rule)
        selectedRuleID = rule.id
        configurationDidChange(rescan: false)
        return rule.id
    }

    func removeRule(id: UUID) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        rules.remove(at: index)
        selectedRuleID = rules.indices.contains(index) ? rules[index].id : rules.last?.id
        externalConflicts[id] = nil
        configurationDidChange(rescan: true)
    }

    func moveRules(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        guard !offsets.isEmpty,
              offsets.allSatisfy(rules.indices.contains),
              destination >= 0,
              destination <= rules.count
        else { return }

        let movingRules = offsets.map { rules[$0] }
        let removedBeforeDestination = offsets.filter { $0 < destination }.count
        let insertionIndex = destination - removedBeforeDestination

        for index in offsets.reversed() {
            rules.remove(at: index)
        }
        rules.insert(contentsOf: movingRules, at: insertionIndex)
        scheduleSave()
    }

    func setShortcutGuideHoldDuration(_ duration: TimeInterval) {
        let normalized = ShortcutGuideConfiguration.normalizedHoldDuration(duration)
        guard normalized != shortcutGuideHoldDuration else { return }
        shortcutGuideHoldDuration = normalized
        preferences.set(normalized, forKey: Self.shortcutGuideHoldDurationKey)
    }

    @discardableResult
    func toggleShortcutGuideFavorite(_ id: String) -> Bool {
        let isFavorite: Bool
        if shortcutGuideFavoriteIDs.contains(id) {
            shortcutGuideFavoriteIDs.remove(id)
            isFavorite = false
        } else {
            shortcutGuideFavoriteIDs.insert(id)
            isFavorite = true
        }
        preferences.set(
            shortcutGuideFavoriteIDs.sorted(),
            forKey: Self.shortcutGuideFavoriteIDsKey
        )
        return isFavorite
    }

    var executableRuleIDs: Set<UUID> {
        let invalidIDs = Set(ShortcutRuleValidator.issues(in: rules).flatMap(\.affectedRuleIDs))
        return Set(rules.compactMap { rule in
            guard rule.isEnabled,
                  !invalidIDs.contains(rule.id),
                  rule.source.physicalModifiers.isEmpty || inputMonitoringGranted
            else { return nil }
            return rule.id
        })
    }

    func localFindings(for ruleID: UUID) -> [ConflictFinding] {
        var findings: [ConflictFinding] = ShortcutRuleValidator.issues(in: rules).compactMap { issue in
            guard issue.affectedRuleIDs.contains(ruleID) else { return nil }
            switch issue {
            case .missingModifier:
                return ConflictFinding(confidence: .confirmed, message: "触发快捷键必须包含至少一个修饰键")
            case let .duplicateShortcut(ruleIDs, shortcut):
                let conflictingNames = rules
                    .filter { ruleIDs.contains($0.id) && $0.id != ruleID }
                    .map(\.name)
                let targets = conflictingNames.map { "“\($0)”" }.joined(separator: "、")
                return ConflictFinding(
                    confidence: .confirmed,
                    message: "与 KeyPilot 规则\(targets)重复使用 \(shortcut.displayString)"
                )
            case let .remapCycle(ruleIDs):
                let conflictingNames = rules
                    .filter { ruleIDs.contains($0.id) && $0.id != ruleID }
                    .map(\.name)
                let targets = conflictingNames.map { "“\($0)”" }.joined(separator: "、")
                return ConflictFinding(
                    confidence: .confirmed,
                    message: "与 KeyPilot 规则\(targets)形成快捷键映射环路"
                )
            }
        }
        if let rule = rule(withID: ruleID),
           !rule.source.physicalModifiers.isEmpty,
           !inputMonitoringGranted {
            findings.append(
                ConflictFinding(
                    confidence: .confirmed,
                    message: "物理修饰键组合需要开启输入监控权限"
                )
            )
        }
        return findings
    }

    func findings(for ruleID: UUID) -> [ConflictFinding] {
        (localFindings(for: ruleID) + (externalConflicts[ruleID] ?? []))
            .sorted { $0.confidence > $1.confidence }
    }

    func setShortcutRecording(_ recording: Bool) {
        isRecordingShortcut = recording
        notifyEngine()
    }

    func notifyEngine() {
        guard !isRecordingShortcut, permissionGranted else {
            onExecutableRulesChanged?([])
            return
        }
        let executableIDs = executableRuleIDs
        let executable = rules.filter { executableIDs.contains($0.id) }
        onExecutableRulesChanged?(executable)
    }

    func notifyAppPreferences() {
        onAppPreferencesChanged?(appPreferences)
    }

    func updateAppPreferences(_ update: (inout AppPreferencesConfiguration) -> Void) {
        var configuration = appPreferences
        update(&configuration)
        guard configuration != appPreferences else { return }
        appPreferences = configuration
        schedulePreferencesSave()
        notifyAppPreferences()
    }

    var registeredApplicationGroups: [RegisteredApplicationGroup] {
        Set(registeredApplications.map(\.initial)).sorted().map {
            RegisteredApplicationGroup(initial: $0, applications: applications(for: $0))
        }
    }

    func applications(for initial: String) -> [RegisteredApplication] {
        ApplicationOrderResolver.ordered(
            registeredApplications.filter { $0.initial == initial },
            preferredBundleIdentifiers: appPreferences.applicationShortcuts.orderedBundleIdentifiers[initial] ?? []
        )
    }

    func defaultApplication(for initial: String) -> RegisteredApplication? {
        let applications = applications(for: initial)
        if applications.count == 1 { return applications[0] }
        guard let bundleIdentifier = appPreferences.applicationShortcuts.defaultBundleIdentifiers[initial] else {
            return nil
        }
        return applications.first { $0.bundleIdentifier == bundleIdentifier }
    }

    func setDefaultApplication(bundleIdentifier: String?, for initial: String) {
        updateAppPreferences { configuration in
            if let bundleIdentifier {
                configuration.applicationShortcuts.defaultBundleIdentifiers[initial] = bundleIdentifier
            } else {
                configuration.applicationShortcuts.defaultBundleIdentifiers.removeValue(forKey: initial)
            }
        }
    }

    func moveApplications(for initial: String, fromOffsets offsets: IndexSet, toOffset destination: Int) {
        let existingPreference = appPreferences.applicationShortcuts.orderedBundleIdentifiers[initial] ?? []
        guard let updatedPreference = ApplicationOrderResolver.updatingPreference(
            existingPreference,
            availableApplications: registeredApplications.filter { $0.initial == initial },
            moving: offsets,
            toOffset: destination
        ) else { return }
        updateAppPreferences {
            $0.applicationShortcuts.orderedBundleIdentifiers[initial] = updatedPreference
        }
    }

    func setRegisteredApplications(_ applications: [RegisteredApplication]) {
        registeredApplications = applications
        seedApplicationDefaultsFromExistingRules()
    }

    func exportConfiguration(to url: URL) {
        do {
            let archive = KeyPilotConfigurationArchive(shortcuts: rules, preferences: appPreferences)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(archive).write(to: url, options: .atomic)
        } catch {
            lastError = "导出配置失败：\(error.localizedDescription)"
        }
    }

    func importConfiguration(from url: URL) {
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let archive = try decoder.decode(KeyPilotConfigurationArchive.self, from: Data(contentsOf: url))
            guard archive.schemaVersion <= KeyPilotConfigurationArchive.currentSchemaVersion,
                  archive.preferences.schemaVersion <= AppPreferencesConfiguration.currentSchemaVersion
            else { throw CocoaError(.coderReadCorrupt) }
            try store.save(archive.shortcuts)
            try appPreferencesStore.save(archive.preferences)
            rules = archive.shortcuts
            appPreferences = archive.preferences
            selectedRuleID = rules.first?.id
            notifyEngine()
            notifyAppPreferences()
            rescanConflicts()
        } catch {
            lastError = "导入配置失败：\(error.localizedDescription)"
        }
    }

    func reportError(_ message: String) { lastError = message }

    func rescanConflicts() {
        isScanningConflicts = true
        onConflictScanRequested?(rules.filter(\.isEnabled))
    }

    func finishConflictScan(_ findings: [UUID: [ConflictFinding]]) {
        externalConflicts = findings
        isScanningConflicts = false
    }

    func flushSave() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        preferencesSaveWorkItem?.cancel()
        preferencesSaveWorkItem = nil
        do {
            try store.save(rules)
            try appPreferencesStore.save(appPreferences)
        } catch {
            lastError = "保存配置失败：\(error.localizedDescription)"
        }
    }

    private func configurationDidChange(rescan: Bool) {
        notifyEngine()
        scheduleSave()
        if rescan { rescanConflicts() }
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let rulesSnapshot = rules
        let store = store
        let workItem = DispatchWorkItem { [weak self] in
            do {
                try store.save(rulesSnapshot)
            } catch {
                DispatchQueue.main.async {
                    self?.lastError = "保存配置失败：\(error.localizedDescription)"
                }
            }
        }
        saveWorkItem = workItem
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25, execute: workItem)
    }

    private func schedulePreferencesSave() {
        preferencesSaveWorkItem?.cancel()
        let configuration = appPreferences
        let store = appPreferencesStore
        let workItem = DispatchWorkItem { [weak self] in
            do {
                try store.save(configuration)
            } catch {
                DispatchQueue.main.async {
                    self?.lastError = "保存应用配置失败：\(error.localizedDescription)"
                }
            }
        }
        preferencesSaveWorkItem = workItem
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25, execute: workItem)
    }

    private func seedApplicationDefaultsFromExistingRules() {
        let groups = registeredApplicationGroups.filter { $0.applications.count > 1 }
        var additions: [String: String] = [:]
        for group in groups where appPreferences.applicationShortcuts.defaultBundleIdentifiers[group.initial] == nil {
            let configuredTargets = legacyApplicationTargets + rules.compactMap { rule -> ApplicationTarget? in
                guard rule.isEnabled, case let .application(target, _) = rule.action else { return nil }
                return target
            }
            guard let target = configuredTargets.first(where: { target in
                group.applications.contains {
                    $0.bundleIdentifier == target.bundleIdentifier || $0.applicationPath == target.applicationPath
                }
            }),
            let application = group.applications.first(where: {
                $0.bundleIdentifier == target.bundleIdentifier || $0.applicationPath == target.applicationPath
            }) else { continue }
            additions[group.initial] = application.bundleIdentifier
        }
        guard !additions.isEmpty else { return }
        updateAppPreferences { configuration in
            configuration.applicationShortcuts.defaultBundleIdentifiers.merge(additions) { current, _ in current }
        }
    }

}
