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

    @Published private(set) var rules: [ShortcutRule] {
        didSet { cachedRuleAnalysis = nil; cachedExecutableIDs = nil; cachedApplicationCatalog = nil; cachedRuleIndex = nil }
    }
    @Published private(set) var appPreferences: AppPreferencesConfiguration {
        didSet {
            if oldValue.applicationShortcuts.defaultBundleIdentifiers != appPreferences.applicationShortcuts.defaultBundleIdentifiers
                || oldValue.applicationShortcuts.orderedBundleIdentifiers != appPreferences.applicationShortcuts.orderedBundleIdentifiers {
                cachedApplicationCatalog = nil
            }
        }
    }
    @Published private(set) var registeredApplications: [RegisteredApplication] = [] {
        didSet { cachedApplicationCatalog = nil }
    }
    @Published private(set) var hasLoadedApplicationInventory = false
    @Published var selectedRuleID: UUID?
    @Published var permissionGranted = false
    @Published var inputMonitoringGranted = false
    @Published var canRestoreWindowLayout = false
    @Published private(set) var shortcutGuideHoldDuration: TimeInterval
    @Published private(set) var shortcutGuideFavoriteIDs: Set<String>
    @Published private(set) var externalConflicts: [UUID: [ConflictFinding]] = [:]
    @Published private(set) var isScanningConflicts = false
    @Published private(set) var lastError: String?

    var onExecutableRulesChanged: (([ShortcutRule]) -> Void)?
    var onConflictScanRequested: (([ShortcutRule]) -> Void)?
    var onAppPreferencesChanged: ((AppPreferencesConfiguration) -> Void)?

    private let persistence: ShortcutConfigurationPersistence
    private let preferences: UserDefaults
    private var saveWorkItem: DispatchWorkItem?
    private var preferencesSaveWorkItem: DispatchWorkItem?
    private var isRecordingShortcut = false
    private var legacyApplicationTargets: [ApplicationTarget] = []
    private var cachedRuleAnalysis: ShortcutRuleAnalysis?
    private var cachedExecutableIDs: (monitoring: Bool, ids: Set<UUID>)?

    private var cachedRuleIndex: ShortcutRuleIndex?
    var ruleIndex: ShortcutRuleIndex {
        if let cachedRuleIndex { return cachedRuleIndex }
        let index = ShortcutRuleIndex(rules)
        cachedRuleIndex = index
        return index
    }

    private var cachedApplicationCatalog: ApplicationCatalog?
    var applicationCatalog: ApplicationCatalog {
        if let cachedApplicationCatalog { return cachedApplicationCatalog }
        let catalog = ApplicationCatalog(applications: registeredApplications, preferences: appPreferences.applicationShortcuts,
            legacyTargets: legacyApplicationTargets, rules: rules)
        cachedApplicationCatalog = catalog
        return catalog
    }

    var ruleAnalysis: ShortcutRuleAnalysis {
        if let cachedRuleAnalysis { return cachedRuleAnalysis }
        let analysis = ShortcutRuleAnalysis(rules: rules)
        cachedRuleAnalysis = analysis
        return analysis
    }

    init(
        store: ShortcutRuleStore = ShortcutRuleStore(fileURL: AppEnvironment.directory("Shortcuts").appendingPathComponent("shortcuts.json")),
        appPreferencesStore: AppPreferencesStore = AppPreferencesStore(fileURL: AppEnvironment.directory("Shortcuts").appendingPathComponent("preferences.json"), legacyFileURL: AppEnvironment.directory("Shortcuts").appendingPathComponent("input-automation.json")),
        preferences: UserDefaults = AppEnvironment.shortcutsDefaults
    ) {
        let persistence = ShortcutConfigurationPersistence(rules: store, preferences: appPreferencesStore)
        self.persistence = persistence
        self.preferences = preferences
        let startup = loadShortcutStartup(store: store, preferencesStore: appPreferencesStore,
            persistence: persistence, preferences: preferences, keys: .init(migration: Self.shortcutMigrationVersionKey,
                holdDuration: Self.shortcutGuideHoldDurationKey, favorites: Self.shortcutGuideFavoriteIDsKey))
        appPreferences = startup.preferences
        rules = startup.rules
        legacyApplicationTargets = startup.legacyTargets
        shortcutGuideHoldDuration = startup.holdDuration
        shortcutGuideFavoriteIDs = startup.favorites
        lastError = startup.error
        selectedRuleID = nil
    }

    func rule(withID id: UUID?) -> ShortcutRule? {
        guard let id else { return nil }
        guard let position = ruleIndex.position(of: id) else { return nil }
        return rules[position]
    }

    func update(_ rule: ShortcutRule) {
        let decision = ruleIndex.updating(rule)
        guard let index = decision.index else { return }
        rules[index] = rule
        configurationDidChange(rescan: decision.requiresConflictScan)
    }

    func setEnabled(_ isEnabled: Bool, for id: UUID) {
        guard var rule = rule(withID: id) else { return }
        rule.isEnabled = isEnabled
        update(rule)
    }

    @discardableResult
    func addRule() -> UUID {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first?.path ?? "~/Desktop"
        let rule = ShortcutRuleIndex.newRule(desktopPath: desktop)
        rules.append(rule)
        selectedRuleID = rule.id
        configurationDidChange(rescan: false)
        return rule.id
    }

    func removeRule(id: UUID) {
        let decision = ruleIndex.removing(id)
        guard let index = decision.index else { return }
        rules.remove(at: index)
        selectedRuleID = decision.selection.map { rules[$0].id }
        externalConflicts[id] = nil
        configurationDidChange(rescan: decision.requiresConflictScan)
    }

    func moveRules(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        guard let reordered = ShortcutRuleIndex.moving(rules, offsets: offsets, destination: destination) else { return }
        rules = reordered
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
        if let cachedExecutableIDs, cachedExecutableIDs.monitoring == inputMonitoringGranted { return cachedExecutableIDs.ids }
        let ids = ruleAnalysis.executableRuleIDs(inputMonitoringGranted: inputMonitoringGranted)
        cachedExecutableIDs = (inputMonitoringGranted, ids)
        return ids
    }

    func localFindings(for ruleID: UUID) -> [ConflictFinding] {
        var findings: [ConflictFinding] = ruleAnalysis.issues.compactMap { issue in
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
        let executable = ruleAnalysis.executableRules(permissionGranted: permissionGranted,
            inputMonitoringGranted: inputMonitoringGranted, isRecording: isRecordingShortcut)
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

    var registeredApplicationGroups: [RegisteredApplicationGroup] { applicationCatalog.groups }

    func applications(for initial: String) -> [RegisteredApplication] { applicationCatalog.applications(for: initial) }

    func defaultApplication(for initial: String) -> RegisteredApplication? { applicationCatalog.defaultApplication(for: initial) }

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
        hasLoadedApplicationInventory = true
        registeredApplications = applications
        seedApplicationDefaultsFromExistingRules()
    }

    func exportConfiguration(to url: URL) {
        do {
            let archive = KeyPilotConfigurationArchive(shortcuts: rules, preferences: appPreferences)
            try ShortcutConfigurationJSON.encode(archive).write(to: url, options: .atomic)
        } catch {
            lastError = "导出配置失败：\(error.localizedDescription)"
        }
    }

    func importConfiguration(from url: URL) {
        do {
            let archive = try ShortcutConfigurationJSON.decode(Data(contentsOf: url))
            guard ShortcutConfigurationJSON.isSupported(archive)
            else { throw CocoaError(.coderReadCorrupt) }
            try persistence.replace(rules: archive.shortcuts, preferences: archive.preferences)
            saveWorkItem?.cancel()
            saveWorkItem = nil
            preferencesSaveWorkItem?.cancel()
            preferencesSaveWorkItem = nil
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
            try persistence.replace(rules: rules, preferences: appPreferences)
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
        let persistence = persistence
        let generation = persistence.reserveRulesSave()
        let workItem = DispatchWorkItem { [weak self] in
            do {
                try persistence.saveRules(rulesSnapshot, generation: generation)
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
        let persistence = persistence
        let generation = persistence.reservePreferencesSave()
        let workItem = DispatchWorkItem { [weak self] in
            do {
                try persistence.savePreferences(configuration, generation: generation)
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
        let additions = applicationCatalog.seedAdditions
        guard !additions.isEmpty else { return }
        updateAppPreferences { configuration in
            configuration.applicationShortcuts.defaultBundleIdentifiers.merge(additions) { current, _ in current }
        }
    }

}
