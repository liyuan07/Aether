import SharedSupport
import AppKit
import ShortcutCore
import SwiftUI
import UniformTypeIdentifiers

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, applications, shortcuts
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "按键与面板"
        case .applications: "应用唤醒"
        case .shortcuts: "快捷键"
        }
    }
    var icon: String {
        switch self {
        case .general: "gearshape"
        case .applications: "app.badge"
        case .shortcuts: "keyboard"
        }
    }
}

@MainActor
final class SettingsNavigationModel: ObservableObject {
    @Published var section: SettingsSection = .general
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var navigation: SettingsNavigationModel

    var body: some View {
        SettingsContent("快捷操作") {
            VStack(spacing: 0) {
                Picker("快捷操作分类", selection: $navigation.section) {
                    ForEach(SettingsSection.allCases) { value in
                        Label(value.title, systemImage: value.icon).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
                switch navigation.section {
                case .general: AppGeneralSettingsView(model: model)
                case .applications: ApplicationShortcutSettingsView(model: model)
                case .shortcuts: ShortcutSettingsView(model: model)
                }
                if let error = model.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange).padding(16)
                }
            }
        }
    }
}

private struct ApplicationShortcutSettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("轻按 Option+首字母打开默认应用；按住后从同首字母应用中选择")
                    .font(.callout).foregroundStyle(.secondary)
                Text("普通窗口移到按键时鼠标所在屏幕；全屏窗口保持原位。需要辅助功能权限。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Toggle("唤起时恢复最小化窗口", isOn: Binding(
                        get: { model.appPreferences.applicationShortcuts.restoreMinimizedWindows },
                        set: { value in model.updateAppPreferences { $0.applicationShortcuts.restoreMinimizedWindows = value } }
                    ))
                    Spacer()
                    Button("恢复上次跨屏布局") { ShortcutsModule.shared.runtime.restoreLastWindowLayout() }
                        .disabled(!model.canRestoreWindowLayout)
                }.padding(.top, 8)
                Text("关闭后，最小化窗口保持原位。布局记录仅在本次 Aether 运行期间有效。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            Divider()
            if model.registeredApplicationGroups.isEmpty {
                ProgressView("正在扫描 Applications…").frame(maxWidth: .infinity, minHeight: 160)
            } else {
                List {
                    ForEach(model.registeredApplicationGroups) { group in
                        Section {
                            if group.applications.count > 1 {
                                HStack {
                                    Text("轻按时默认打开")
                                    Spacer()
                                    Picker("默认应用", selection: defaultBinding(for: group.initial)) {
                                        Text("请选择默认应用").tag("")
                                        ForEach(group.applications) { application in
                                            Text(application.displayName).tag(application.bundleIdentifier)
                                        }
                                    }
                                    .labelsHidden()
                                    .frame(width: 210)
                                }
                            }
                            ForEach(group.applications) { application in
                                HStack(spacing: 10) {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: application.applicationPath))
                                        .resizable().frame(width: 28, height: 28)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(application.displayName)
                                        Text(application.applicationPath)
                                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 12)
                                    Picker("窗口行为", selection: windowBehaviorBinding(for: application.bundleIdentifier)) {
                                        ForEach(ApplicationWindowBehavior.allCases, id: \.self) { behavior in
                                            Text(behavior.title).tag(behavior)
                                        }
                                    }
                                    .labelsHidden()
                                    .frame(width: 170)
                                    .help("此应用的窗口行为，适用于应用快捷键和应用启动器")
                                    Image(systemName: "line.3.horizontal")
                                        .font(.caption).foregroundStyle(.tertiary)
                                        .help("拖动调整 Option+\(group.initial) 选择器中的位置")
                                }
                                .padding(.vertical, 3)
                            }
                            .onMove { offsets, destination in
                                model.moveApplications(
                                    for: group.initial,
                                    fromOffsets: offsets,
                                    toOffset: destination
                                )
                            }
                        } header: {
                            HStack {
                                Text("⌥\(group.initial)")
                                    .font(.system(.headline, design: .monospaced))
                                Text(group.applications.count == 1 ? "无冲突" : "\(group.applications.count) 个应用")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }

            Text("拖动应用可调整同首字母选择器中的展示顺序。中文应用按拼音首字母归类；新安装的应用会追加到对应分组末尾。")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
        }
    }

    private func defaultBinding(for initial: String) -> Binding<String> {
        Binding(
            get: { model.appPreferences.applicationShortcuts.defaultBundleIdentifiers[initial] ?? "" },
            set: { model.setDefaultApplication(bundleIdentifier: $0.isEmpty ? nil : $0, for: initial) }
        )
    }

    private func windowBehaviorBinding(for identifier: String) -> Binding<ApplicationWindowBehavior> {
        Binding(get: { model.appPreferences.applicationShortcuts.windowBehaviorOverrides[identifier] ?? .followGlobal },
                set: { value in
                    model.updateAppPreferences {
                        if value == .followGlobal { $0.applicationShortcuts.windowBehaviorOverrides.removeValue(forKey: identifier) }
                        else { $0.applicationShortcuts.windowBehaviorOverrides[identifier] = value }
                    }
                })
    }
}

private struct AppGeneralSettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle("显示实体按钮", isOn: appBinding(\.showModifierButtons))
            } header: { Text("实体按钮") }
            footer: { Text("在桌面显示可拖动的修饰键、复制与粘贴按钮。") }

            Section {
                Toggle("屏蔽 ABC 自动切换", isOn: appBinding(\.blockAutomaticABC))
            } header: { Text("输入法") }
            footer: { Text("只在按下物理中英键时切换到 ABC，需要输入监控权限。") }

            Section("配置") {
                LabeledContent("快捷操作配置") {
                    HStack {
                        Button("导入…") { importConfiguration() }
                        Button("导出…") { exportConfiguration() }
                    }
                }
            }
        }.formStyle(.grouped)
    }

    private func appBinding<Value>(_ keyPath: WritableKeyPath<AppGeneralPreferences, Value>) -> Binding<Value> {
        Binding(
            get: { model.appPreferences.app[keyPath: keyPath] },
            set: { value in model.updateAppPreferences { $0.app[keyPath: keyPath] = value } }
        )
    }

    private func exportConfiguration() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Aether-Shortcuts.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.exportConfiguration(to: url)
    }

    private func importConfiguration() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.importConfiguration(from: url)
    }
}
