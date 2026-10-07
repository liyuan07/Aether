import AppKit
import SharedSupport
import SwiftUI

@MainActor public final class ClipboardModule: ObservableObject {
    public static let shared = ClipboardModule()
    @Published public var hotKeyError: String?
    public var builtInHotKeyAllowed = true
    private init() {}
    public func start() {
        PreferenceKeys.registerDefaults()
        _ = ClipboardStore.shared
        if AppEnvironment.clipboardDefaults.bool(forKey: PreferenceKeys.monitoringEnabled) {
            ClipboardStore.shared.startMonitoring()
        }
        refreshHotKey()
    }
    public func stop() {
        AccessibilityPermissionMonitor.shared.stop()
        ClipboardStore.shared.stopMonitoring()
        ClipboardStore.shared.flushArchive()
        HotKeyManager.shared.unregister()
    }
    public func refreshHotKey() {
        guard builtInHotKeyAllowed else {
            HotKeyManager.shared.unregister()
            hotKeyError = "⇧⌘J 已由你的自定义快捷键占用；剪贴板内置快捷键暂未注册。"
            return
        }
        hotKeyError = nil
        HotKeyManager.shared.refresh()
    }
    public func captureTarget() { PasteCoordinator.shared.captureCurrentApplication() }
    public func showWindow() { ClipboardPanelController.shared.togglePanel() }
    public func presentWindow() { ClipboardPanelController.shared.presentPanel() }
    public func hideWindow() { ClipboardPanelController.shared.hidePanel() }
    public func settings() -> AnyView { AnyView(ClipboardSettingsView()) }
    public func compactPanel() -> AnyView { AnyView(CompactClipboardView()) }
    public func monitoringControl() -> AnyView { AnyView(ClipboardMonitoringControl()) }
}

private struct ClipboardMonitoringControl: View {
    @AppStorage(PreferenceKeys.monitoringEnabled, store: AppEnvironment.clipboardDefaults) private var enabled = true
    var body: some View {
        Toggle("记录剪贴板历史", isOn: $enabled)
            .onChange(of: enabled) { _, _ in
                NotificationCenter.default.post(name: .clipboardPreferencesDidChange, object: nil)
            }
    }
}

private struct CompactClipboardView: View {
    @StateObject private var model = ClipboardPanelViewModel()
    @StateObject private var search = ClipboardSearchModel()
    @State private var tab: ClipboardTab = .all
    @State private var error: String?
    var body: some View {
        VStack(spacing: 12) {
            TextField("搜索剪贴板", text: $search.text)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("AetherClipboardSearch")
            Picker("分类", selection: $tab) {
                Text("历史").tag(ClipboardTab.all)
                Text("收藏").tag(ClipboardTab.favorites)
                Text("分组").tag(ClipboardTab.groups)
            }.pickerStyle(.segmented)
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            ScrollView {
                LazyVStack(spacing: 6) {
                    if model.state.isSearching { ProgressView().controlSize(.small) }
                    if tab == .groups {
                        ForEach(model.state.groups) { group in
                            row(title: group.title, detail: group.preview, icon: "square.stack") {
                                guard ClipboardStore.shared.activateGroup(group) else { error = "无法读取这组内容。"; return }
                                paste { PasteCoordinator.shared.pasteGroupIntoCapturedApplication(group) }
                            }
                        }
                    } else {
                        ForEach(model.state.items) { item in
                            row(title: item.displayPreview, detail: item.type.displayName, icon: item.type.icon) {
                                guard ClipboardStore.shared.activateItem(item) else { error = "无法读取这条内容。"; return }
                                paste { PasteCoordinator.shared.pasteIntoCapturedApplication() }
                            }
                        }
                    }
                    if !model.state.isSearching && model.state.items.isEmpty && model.state.groups.isEmpty {
                        ContentUnavailableView("暂无内容", systemImage: "doc.on.clipboard", description: Text("复制内容后会显示在这里"))
                    }
                }
            }
            Divider()
            Button("打开完整剪贴板  ⇧⌘J") { AppRouter.shared.send(.clipboard) }
                .frame(maxWidth: .infinity)
        }
        .padding(14)
        .onChange(of: search.query) { _, value in model.updateQuery(value) }
        .onChange(of: tab) { _, value in model.selectTab(value) }
    }
    private func paste(_ action: () -> Void) {
        guard AccessibilityController.isTrusted else {
            error = "已复制到剪贴板；自动粘贴需要辅助功能权限。"
            return
        }
        action()
    }
    private func row(title: String, detail: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundStyle(.tint).frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Image(systemName: "return").font(.caption).foregroundStyle(.tertiary)
            }.padding(10).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain)
    }
}

extension ClipboardModule {
    nonisolated public static func validateMigration(at root: URL) throws {
        let url = root.appendingPathComponent("history.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let archive = try JSONDecoder().decode(ClipboardArchive.self, from: Data(contentsOf: url))
        let items = archive.history + archive.pinnedItems + (archive.groups ?? []).flatMap(\.items)
        for item in items {
            for name in [item.imageFileName, item.rtfFileName].compactMap({ $0 }) {
                guard name == (name as NSString).lastPathComponent, name != "..", name != "." else { throw CocoaError(.fileReadCorruptFile) }
            }
        }
    }
}
