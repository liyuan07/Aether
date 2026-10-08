import AppKit
import ApplicationServices
import CoreGraphics
import ServiceManagement
import SwiftUI
import SharedSupport
import ClipboardFeature
import ShortcutsFeature
import TimerFeature
import PromptFeature
import PortsFeature

@MainActor final class LoginService: ObservableObject {
    static let shared = LoginService()
    @Published private(set) var enabled = AppEnvironment.appDefaults.bool(forKey: "launchAtLogin")
    @Published private(set) var error: String?
    var status: String {
        if AppEnvironment.isResourceProfiling { return enabled ? "已启用" : "未启用" }
        return switch SMAppService.mainApp.status {
        case .enabled: "已启用"
        case .requiresApproval: "需要在系统设置的登录项中允许"
        case .notRegistered: "未启用"
        case .notFound: "请从 Applications 中运行正式副本"
        @unknown default: "未知状态"
        }
    }
    func synchronize() { set(AppEnvironment.appDefaults.bool(forKey: "launchAtLogin")) }
    func set(_ value: Bool) {
        if AppEnvironment.isResourceProfiling {
            enabled = value
            AppEnvironment.appDefaults.set(value, forKey: "launchAtLogin")
            return
        }
        do {
            if value, SMAppService.mainApp.status != .enabled && SMAppService.mainApp.status != .requiresApproval { try SMAppService.mainApp.register() }
            else if !value, SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval { try SMAppService.mainApp.unregister() }
            enabled = value
            AppEnvironment.appDefaults.set(value, forKey: "launchAtLogin")
            error = nil
        } catch { self.error = "无法更新登录项：\(error.localizedDescription)" }
    }
}

@MainActor private final class SettingsSelection: ObservableObject {
    @Published var page: SharedSupport.SettingsPage = .general { didSet { changed?() } }
    var changed: (() -> Void)?
}

@MainActor final class AetherSettingsController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let navigation = SettingsSelection()
    private let startup: StartupController
    init(startup: StartupController) {
        self.startup = startup
        super.init()
        navigation.changed = { [weak self] in self?.updatePortVisibility() }
    }
    private func updatePortVisibility() {
        PortsModule.shared.setDetailsVisible(window?.isVisible == true && window?.isMiniaturized != true && window?.occlusionState.contains(.visible) == true && navigation.page == .ports)
    }
    func windowWillClose(_ notification: Notification) { PortsModule.shared.setDetailsVisible(false) }
    func windowDidChangeOcclusionState(_ notification: Notification) { updatePortVisibility() }
    func windowDidMiniaturize(_ notification: Notification) { PortsModule.shared.setDetailsVisible(false) }
    func windowDidDeminiaturize(_ notification: Notification) { updatePortVisibility() }
    var isVisible: Bool { window?.isVisible == true }
    func show(_ page: SharedSupport.SettingsPage) {
        navigation.page = page
        if window == nil {
            let controller = NSHostingController(rootView: AetherSettingsView(navigation: navigation, startup: startup))
            let window = NSWindow(contentViewController: controller)
            window.delegate = self
            window.title = "Aether 设置"
            window.setContentSize(NSSize(width: 900, height: 640))
            window.contentMinSize = NSSize(width: 820, height: 560)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.center()
            window.setFrameAutosaveName("AetherSettingsWindow")
            window.setFrameUsingName("AetherSettingsWindow")
            self.window = window
        }
        if let window {
            let screens = NSScreen.screens
            let screen = screens.max { a, b in
                let ai = a.visibleFrame.intersection(window.frame)
                let bi = b.visibleFrame.intersection(window.frame)
                return (ai.isNull ? 0 : ai.width * ai.height) < (bi.isNull ? 0 : bi.width * bi.height)
            } ?? NSScreen.main
            if let screen { window.setFrame(SettingsWindowGeometry.fitting(window.frame, in: screen.visibleFrame), display: true) }
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
        updatePortVisibility()
    }
}

private struct AetherSettingsView: View {
    @ObservedObject var navigation: SettingsSelection
    @ObservedObject var startup: StartupController
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Label("Aether", systemImage: "square.3.layers.3d")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 16).padding(.vertical, 16)
                List(selection: $navigation.page) {
                    Section("通用") { navigationRow(.general) }
                    Section("功能") {
                        navigationRow(.clipboard)
                        navigationRow(.shortcuts)
                        navigationRow(.timer)
                        navigationRow(.prompt)
                    }
                    Section("系统") {
                        navigationRow(.ports)
                        navigationRow(.permissions)
                    }
                }.listStyle(.sidebar)
            }.frame(width: 168)
            Divider()
            Group {
                if !startup.ready && navigation.page != .permissions {
                    setup
                } else {
                    switch navigation.page {
                    case .general: SettingsContent("通用") { GeneralSettingsView() }
                    case .clipboard: ClipboardModule.shared.settings()
                    case .shortcuts: ShortcutsModule.shared.settings()
                    case .timer: TimerModule.shared.settings()
                    case .prompt: PromptModule.shared.settings()
                    case .ports: PortsModule.shared.details()
                    case .permissions: SettingsContent("权限") { PermissionSettingsView() }
                    }
                }
            }
            .id(navigation.page)
            .accessibilityIdentifier("AetherSettingsPage." + navigation.page.rawValue)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }.tint(.indigo)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    private func navigationRow(_ page: SharedSupport.SettingsPage) -> some View {
        Label(page.title, systemImage: page.symbol)
            .font(.system(size: 13)).tag(page).padding(.vertical, 2)
    }
    private var setup: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("迁移现有数据", systemImage: "tray.and.arrow.down").font(.title2.bold())
            Text(startup.message).foregroundStyle(.secondary)
            if startup.importing { ProgressView("正在复制并校验本地数据…") }
            else { Button("继续迁移") { startup.prepare() }.buttonStyle(.borderedProminent) }
        }.padding(32)
    }

}

private struct GeneralSettingsView: View {
    @ObservedObject private var login = LoginService.shared
    var body: some View {
        SettingsForm {
            SettingsGroup {
                SettingsRow("登录时启动 Aether") { Toggle("登录时启动 Aether", isOn: Binding(get: { login.enabled }, set: login.set)).labelsHidden() }
                LabeledContent("系统登录项状态", value: login.status)
                if let error = login.error { Text(error).foregroundStyle(.red) }
            } header: { Text("启动") }

        }
    }
}

private struct PermissionSettingsView: View {
    @State private var accessibility = AXIsProcessTrusted()
    @State private var monitoring = CGPreflightListenEventAccess()
    var body: some View {
        SettingsForm {
            permissionGroup("辅助功能", granted: accessibility,
                            purpose: "自动粘贴、快捷键映射、应用操作及系统时钟镜像。",
                            anchor: "Privacy_Accessibility")
            permissionGroup("输入监控", granted: monitoring,
                            purpose: "识别左右修饰键和物理中英键、快捷键提示及 ABC 自动切换防护。",
                            anchor: "Privacy_ListenEvent")
            DisclosureGroup("了解详情") {
                Text("未授权时仍可记录和复制剪贴板、使用本地计时。若系统要求重新打开应用，请使用菜单栏右键的“重新启动”。系统时钟镜像受 macOS 版本及系统接口限制。")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
            }
        }
        .task {
            while !Task.isCancelled {
                accessibility = AXIsProcessTrusted()
                monitoring = CGPreflightListenEventAccess()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }
    private func permissionGroup(_ title: String, granted: Bool, purpose: String, anchor: String) -> some View {
        SettingsGroup(title) {
            SettingsRow("授权状态") {
                Label(granted ? "已授权" : "未授权", systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(granted ? Color.secondary : Color.orange)
                Button("前往授权") { open(anchor) }
            }
            Text(purpose).font(.caption).foregroundStyle(.secondary)
        }
    }
    private func open(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + anchor) { NSWorkspace.shared.open(url) }
    }
}
