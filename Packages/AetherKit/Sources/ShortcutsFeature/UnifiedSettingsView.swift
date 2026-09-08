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
        case .general: "通用"
        case .applications: "应用唤醒"
        case .shortcuts: "系统与自定义"
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
        HStack(spacing: 0) {
            List(selection: $navigation.section) {
                Section("快捷操作") {
                    ForEach(SettingsSection.allCases) { value in
                        Label(value.title, systemImage: value.icon).tag(value)
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(width: 184)
            Divider()
            switch navigation.section {
            case .general: AppGeneralSettingsView(model: model)
            case .applications: ApplicationShortcutSettingsView(model: model)
            case .shortcuts: ShortcutSettingsView(model: model)
            }
        }
        .frame(minWidth: 650, minHeight: 500)
    }
}

private struct ApplicationShortcutSettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("应用唤醒").font(.title2.weight(.semibold))
                Text("轻按 Option+首字母打开默认应用；按住后从同首字母应用中选择")
                    .font(.callout).foregroundStyle(.secondary)
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
}

private struct AppGeneralSettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        SettingsPage("通用设置", subtitle: "应用唤醒、按键与配置") {
            VStack(spacing: 8) {
                SettingsRow(
                    "显示实体按钮",
                    detail: "显示可拖动的右 Option、双 Shift、复制和粘贴按钮"
                ) {
                    Toggle("", isOn: appBinding(\.showModifierButtons)).labelsHidden().toggleStyle(.switch)
                }
                Divider()
                SettingsRow(
                    "屏蔽 ABC 自动切换",
                    detail: "仅允许亲自按下物理中英键进入 ABC；需要输入监控权限"
                ) {
                    Toggle("", isOn: appBinding(\.blockAutomaticABC)).labelsHidden().toggleStyle(.switch)
                }
            }.compactSettingsGroup()

            HStack {
                Text("配置导入导出")
                Spacer()
                Button("导出…") { exportConfiguration() }
                Button("导入…") { importConfiguration() }
            }.compactSettingsGroup()
        }
    }

    private func appBinding<Value>(_ keyPath: WritableKeyPath<AppGeneralPreferences, Value>) -> Binding<Value> {
        Binding(
            get: { model.appPreferences.app[keyPath: keyPath] },
            set: { value in model.updateAppPreferences { $0.app[keyPath: keyPath] = value } }
        )
    }

    private func exportConfiguration() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "KeyPilot-Configuration.json"
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

struct SettingsPage<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    init(_ title: String, subtitle: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.title2.weight(.semibold))
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
                content
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

struct SettingsRow<Control: View>: View {
    let title: String
    let detail: String?
    @ViewBuilder let control: Control

    init(_ title: String, detail: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 20)
            control
        }
        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
    }
}

extension View {
    func compactSettingsGroup() -> some View {
        self
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor).opacity(0.45)))
    }
}
