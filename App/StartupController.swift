import AppKit
import SharedSupport
import ClipboardFeature
import ShortcutsFeature
import Foundation

@MainActor final class StartupController: ObservableObject {
    @Published private(set) var ready = false
    @Published private(set) var message = "正在检查本地数据…"
    @Published private(set) var importing = false
    var onReady: (() -> Void)?
    private static let legacy = LegacyApplication.allCases.map(\.bundleIdentifier)

    func prepare() {
        guard !ready, !importing else { return }
        if AppEnvironment.isResourceProfiling {
            ready = true
            onReady?()
            return
        }
        let running = Self.legacy.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
        if !running.isEmpty {
            message = "请先退出旧应用：\(running.compactMap(\.localizedName).joined(separator: "、"))。如果倒计时或护眼正在运行，请先完成或停止。退出后点击“继续迁移”。原数据和应用会保留。"
            return
        }
        importing = true
        // Capture preferences before copying; disk I/O does not block AppKit.
        let defaults = AppEnvironment.appDefaults
        let timer = defaults.persistentDomain(forName: "com.liyuan.packagecounter") ?? [:]
        let clipboard = defaults.persistentDomain(forName: "com.liyuan07.clipboard") ?? [:]
        let shortcuts = defaults.persistentDomain(forName: "com.liyuan.keypilot") ?? [:]
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let root = AppEnvironment.root
        let preferenceURL = support.appendingPathComponent("ShortcutHelper/preferences.json")
        let preferenceObject = (try? Data(contentsOf: preferenceURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let shortcutLogin = (preferenceObject?["app"] as? [String: Any])?["launchAtLogin"] as? Bool
        let login = MigrationPreferencePolicy.launchAtLogin(existing: defaults.object(forKey: "launchAtLogin") as? Bool,
            timer: timer["launchAtLogin"] as? Bool, clipboard: clipboard["launchAtLogin"] as? Bool, shortcuts: shortcutLogin)
        let sources: [DataMigration.Source]
        do {
            sources = try [
                .init(name: "Timer", directory: nil, preferences: timer),
                .init(name: "Clipboard", directory: support.appendingPathComponent("Clipboard"), preferences: clipboard),
                .init(name: "Shortcuts", directory: support.appendingPathComponent("ShortcutHelper"), preferences: shortcuts),
                .init(name: "General", directory: nil, preferences: ["launchAtLogin": login])
            ]
        } catch {
            importing = false
            message = "无法创建偏好快照：\(error.localizedDescription)"
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try DataMigration(destination: root).run(sources: sources, validate: { root in
                    try ClipboardModule.validateMigration(at: root.appendingPathComponent("Clipboard"))
                    try ShortcutsModule.validateMigration(at: root.appendingPathComponent("Shortcuts"))
                }, applyPreferences: { name, values in
                    let destination: UserDefaults
                    switch MigrationPreferencePolicy.destination(for: name) {
                    case .clipboard: destination = AppEnvironment.clipboardDefaults
                    case .shortcuts: destination = AppEnvironment.shortcutsDefaults
                    case .app: destination = AppEnvironment.appDefaults
                    }
                    for (key, value) in values where MigrationPreferencePolicy.includes(key: key, source: name) {
                        destination.set(value, forKey: key)
                    }
                    destination.synchronize()
                })
                try ClipboardModule.migrateBackground(
                    preferences: clipboard,
                    source: support.appendingPathComponent("Clipboard/Backgrounds"),
                    destination: root.appendingPathComponent("Clipboard/Backgrounds"),
                    defaults: AppEnvironment.clipboardDefaults
                )
                DispatchQueue.main.async {
                    if AppEnvironment.appDefaults.object(forKey: "launchAtLogin") == nil { AppEnvironment.appDefaults.set(login, forKey: "launchAtLogin") }
                    self.importing = false
                    self.message = "迁移已完成 · \(result.importedAt.formatted(date: .abbreviated, time: .shortened))。原应用数据保持不变。"
                    self.ready = true
                    self.onReady?()
                }
            } catch {
                DispatchQueue.main.async {
                    self.importing = false
                    self.message = "迁移未完成：\(error.localizedDescription) 原数据未修改，可以修复后重试。"
                }
            }
        }
    }
}
