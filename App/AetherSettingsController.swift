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
            window.setContentSize(SettingsLayout.defaultSize)
            window.contentMinSize = SettingsLayout.minimumSize
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.center()
            if !AppEnvironment.isResourceProfiling {
                window.setFrameAutosaveName("AetherSettingsWindow")
                window.setFrameUsingName("AetherSettingsWindow")
            }
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
            sidebar
            Divider()
            Group {
                if !startup.ready && navigation.page != .permissions {
                    setup
                } else {
                    switch navigation.page {
                    case .general, .permissions: GeneralSettingsView(focusPermissions: navigation.page == .permissions)
                    case .clipboard: ClipboardModule.shared.settings()
                    case .shortcuts: ShortcutsModule.shared.settings()
                    case .timer: TimerModule.shared.settings()
                    case .prompt: PromptModule.shared.settings()
                    case .ports: PortsModule.shared.details()
                    }
                }
            }
            .id(navigation.page)
            .accessibilityIdentifier("AetherSettingsPage." + navigation.page.rawValue)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }.tint(.indigo)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "square.3.layers.3d")
                    .font(.system(size: 24, weight: .medium)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Aether").font(.system(size: 17, weight: .semibold))
                    Text("设置").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 18).padding(.vertical, 24)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    navigationRow(.general, title: "启动与权限")
                    Text("功能设置").font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary).padding(.leading, 12).padding(.top, 18).padding(.bottom, 4)
                    ForEach([SharedSupport.SettingsPage.clipboard, .shortcuts, .timer, .prompt]) { page in
                        navigationRow(page, title: page.title)
                    }
                    Text("硬件").font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary).padding(.leading, 12).padding(.top, 18).padding(.bottom, 4)
                    navigationRow(.ports, title: "端口与设备")
                }.padding(.horizontal, 10)
            }
            Text("版本 " + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"))
                .font(.system(size: 12)).foregroundStyle(.secondary).padding(20)
        }
        .frame(width: SettingsLayout.sidebarWidth)
        .background(.regularMaterial)
    }
    private func navigationRow(_ page: SharedSupport.SettingsPage, title: String) -> some View {
        let selected = navigation.page.navigationPage == page
        return Button { navigation.page = page } label: {
            HStack(spacing: 10) {
                Image(systemName: page == .general ? "slider.horizontal.3" : page.symbol)
                    .font(.system(size: 16)).frame(width: 22)
                Text(title).font(.system(size: 14, weight: selected ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).frame(minHeight: 42)
            .foregroundStyle(selected ? Color.accentColor : Color.primary)
            .background(selected ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.navigation." + page.rawValue)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
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
    let focusPermissions: Bool
    @ObservedObject private var login = LoginService.shared
    var body: some View {
        SettingsContent("启动与权限", subtitle: "管理启动方式、系统授权和本机数据。") {
            SettingsForm(initialFocus: focusPermissions ? "permissions" : nil) {
                SettingsGroup("启动方式") {
                    SettingsToggleRow("登录时启动 Aether", description: login.status,
                                      isOn: Binding(get: { login.enabled }, set: login.set))
                    if let error = login.error {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).padding(.vertical, 8)
                    }
                }
                PermissionSettingsView().id("permissions")
                SettingsGroup("本机数据") {
                    SettingsRow("数据文件夹", description: "查看剪贴板、备忘录与配置的本地存储。") {
                        Button("在访达中打开", systemImage: "folder") {
                            NSWorkspace.shared.activateFileViewerSelecting([AppEnvironment.root])
                        }
                    }
                }
            }
        }
    }
}

private struct PermissionSettingsView: View {
    @State private var accessibility = AXIsProcessTrusted()
    @State private var monitoring = CGPreflightListenEventAccess()
    var body: some View {
        SettingsGroup("系统权限") {
            permissionGroup("辅助功能", granted: accessibility,
                            purpose: "粘贴到其他应用、映射快捷键、移动窗口。",
                            anchor: "Privacy_Accessibility")
            permissionGroup("输入监控", granted: monitoring,
                            purpose: "识别左右修饰键与物理中英键，显示快捷键提示。",
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
        SettingsRow(title, description: purpose) {
            Label(granted ? "已授权" : "未授权", systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(granted ? Color.secondary : Color.orange)
            Button(granted ? "查看权限" : "前往授权") { open(anchor) }
        }
    }
    private func open(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + anchor) { NSWorkspace.shared.open(url) }
    }
}
