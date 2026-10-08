import AppKit
import SharedSupport
import ShortcutCore
import SwiftUI

@MainActor public final class ShortcutsModule {
    public static let shared = ShortcutsModule()
    let runtime = ShortcutsRuntime()
    let navigation = SettingsNavigationModel()
    public var rulesChanged: (() -> Void)?
    private(set) var externalApplication: NSRunningApplication?
    public func captureTarget() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        externalApplication = app
    }
    func sendToCapturedApplication(_ shortcut: KeyCombination) {
        guard let app = externalApplication, !app.isTerminated else {
            runtime.model.reportError("原应用已退出，无法执行快捷键。")
            return
        }
        AppRouter.shared.send(.dismissPanels)
        app.activate()
        Task { @MainActor in
            for _ in 0..<40 {
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
                    SyntheticKeySender.send(shortcut)
                    return
                }
                do { try await Task.sleep(for: .milliseconds(25)) } catch { return }
            }
            runtime.model.reportError("无法激活原应用，快捷键未发送。")
        }
    }
    private init() {}
    public func start() { runtime.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification)) }
    public func stop() { runtime.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)) }
    public func refreshPermissions() { runtime.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification)) }
    public var claimsClipboardHotKey: Bool {
        ShortcutRegistrationPolicy.userRulesClaim(
            KeyCombination(keyCode: 38, modifiers: [.command, .shift]),
            rules: runtime.model.rules
        )
    }

    public func settings() -> AnyView { AnyView(SettingsView(model: runtime.model, navigation: navigation)) }
    public func controls() -> AnyView { AnyView(ShortcutControlsView(model: runtime.model)) }
    public func quickActions() -> AnyView { AnyView(ShortcutActionsView(model: runtime.model, navigation: navigation)) }
}

private struct ShortcutControlsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 12) {
            Toggle("显示实体按钮", isOn: binding(\.showModifierButtons))
            Toggle("屏蔽 ABC 自动切换", isOn: binding(\.blockAutomaticABC))
        }
    }
    private func binding(_ keyPath: WritableKeyPath<AppGeneralPreferences, Bool>) -> Binding<Bool> {
        Binding(get: { model.appPreferences.app[keyPath: keyPath] }, set: { value in
            model.updateAppPreferences { $0.app[keyPath: keyPath] = value }
        })
    }
}

private struct ShortcutActionsView: View {
    @Environment(\.panelBackAction) private var back
    @ObservedObject var model: AppModel
    @ObservedObject var navigation: SettingsNavigationModel
    @State private var query = ""
    @State private var showApplications = false
    @State private var applicationShortcuts: [CatalogShortcut] = []
    private var listed: [ShortcutRule] {
        model.rules.filter { rule in
            query.isEmpty ? model.shortcutGuideFavoriteIDs.contains("custom|" + rule.id.uuidString)
                : matches(rule.name) || matches(rule.action.summary)
        }
    }
    private var catalog: [CatalogShortcut] {
        let system = SystemShortcutCatalog.shortcuts.filter {
            query.isEmpty ? model.shortcutGuideFavoriteIDs.contains("favorite|" + $0.id) : matches($0.name)
        }
        let app = ShortcutsModule.shared.externalApplication
        let prefix = "application|" + (app?.bundleIdentifier ?? app?.localizedName ?? "") + "|"
        return system + applicationShortcuts.filter {
            query.isEmpty ? model.shortcutGuideFavoriteIDs.contains(prefix + $0.id) : matches($0.name)
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            PanelToolbar("快捷操作", back: back) {
                Button { open(showApplications ? .applications : .shortcuts) } label: { Image(systemName: "gearshape") }
                    .help("快捷操作设置").accessibilityLabel("快捷操作设置")
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
            TextField(showApplications ? "搜索已安装的应用" : "搜索快捷动作", text: $query).textFieldStyle(.roundedBorder)
            HStack {
                Label(showApplications ? "应用启动器" : "收藏快捷动作", systemImage: showApplications ? "app.badge" : "star")
                Spacer()
                Button("管理") { open(showApplications ? .applications : .shortcuts) }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if showApplications {
                        ForEach(model.registeredApplications.filter { query.isEmpty || matches($0.displayName) }) { app in
                            Button {
                                AppRouter.shared.send(.dismissPanels)
                                ShortcutsModule.shared.runtime.execute(.application(target: ApplicationTarget(displayName: app.displayName, bundleIdentifier: app.bundleIdentifier, applicationPath: app.applicationPath), mode: .activateExisting))
                            } label: { actionRow(app.displayName, detail: app.initial) }
                                .buttonStyle(.plain)
                        }
                    } else {
                        ForEach(listed) { rule in
                            Button {
                                if case let .remap(shortcut) = rule.action { ShortcutsModule.shared.sendToCapturedApplication(shortcut) }
                                else { AppRouter.shared.send(.dismissPanels); ShortcutsModule.shared.runtime.execute(rule.action) }
                            } label: { actionRow(rule.name, detail: rule.source.displayString) }
                                .buttonStyle(.plain).disabled(!model.executableRuleIDs.contains(rule.id))
                        }
                        ForEach(catalog) { item in
                            Button { ShortcutsModule.shared.sendToCapturedApplication(item.shortcut) }
                            label: { actionRow(item.name, detail: item.shortcut.displayString) }
                                .buttonStyle(.plain).disabled(!model.permissionGranted)
                        }
                        if listed.isEmpty && catalog.isEmpty {
                            Text(query.isEmpty ? "在快捷键提示面板中收藏常用动作，便可在这里一键执行。" : "没有匹配的快捷动作")
                                .foregroundStyle(.secondary).padding(.vertical, 20)
                        }
                    }
                }
            }
            if let error = model.lastError { Text(error).font(.caption).foregroundStyle(.orange) }
            Divider()
            Button {
                AppRouter.shared.send(.dismissPanels)
                ShortcutsModule.shared.runtime.restoreLastWindowLayout()
            } label: { Label("恢复上次跨屏布局", systemImage: "arrow.uturn.backward") }
                .disabled(!model.canRestoreWindowLayout)
            Button { query = ""; showApplications.toggle() } label: {
                Label(showApplications ? "返回收藏动作" : "打开应用启动器", systemImage: showApplications ? "star" : "app.badge")
            }
            Button { open(.general) } label: { Label("实体按钮与按键设置", systemImage: "keyboard") }
            }.padding(12)
        }
        .onAppear {
            guard model.permissionGranted, let app = ShortcutsModule.shared.externalApplication else { return }
            ApplicationShortcutCatalogProvider.shared.load(for: app) { applicationShortcuts = $0.shortcuts }
        }
    }
    private func matches(_ value: String) -> Bool { value.localizedCaseInsensitiveContains(query) }
    private func actionRow(_ title: String, detail: String) -> some View {
        HStack {
            Text(title).lineLimit(1)
            Spacer()
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 10).frame(maxWidth: .infinity)
            .overlay(alignment: .bottom) { Divider().frame(height: 1) }
    }
    private func open(_ section: SettingsSection) {
        navigation.section = section
        AppRouter.shared.send(.settings(.shortcuts))
    }
}

extension ShortcutsModule {
    nonisolated public static func validateMigration(at root: URL) throws {
        let rules = root.appendingPathComponent("shortcuts.json")
        if FileManager.default.fileExists(atPath: rules.path) { _ = try ShortcutRuleStore(fileURL: rules).load() }
        let preferences = root.appendingPathComponent("preferences.json")
        let legacy = root.appendingPathComponent("input-automation.json")
        if FileManager.default.fileExists(atPath: preferences.path) || FileManager.default.fileExists(atPath: legacy.path) {
            _ = try AppPreferencesStore(fileURL: preferences, legacyFileURL: legacy).load()
        }
    }
}
