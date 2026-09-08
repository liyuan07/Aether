import AppKit
import ApplicationServices
import CoreGraphics
import ServiceManagement
import SwiftUI
import SharedSupport
import ClipboardFeature
import ShortcutsFeature
import TimerFeature

@MainActor final class LoginService: ObservableObject {
    static let shared = LoginService()
    @Published private(set) var enabled = UserDefaults.standard.bool(forKey: "launchAtLogin")
    @Published private(set) var error: String?
    var status: String {
        switch SMAppService.mainApp.status {
        case .enabled: "已启用"
        case .requiresApproval: "需要在系统设置的登录项中允许"
        case .notRegistered: "未启用"
        case .notFound: "请从 Applications 中运行正式副本"
        @unknown default: "未知状态"
        }
    }
    func synchronize() { set(UserDefaults.standard.bool(forKey: "launchAtLogin")) }
    func set(_ value: Bool) {
        do {
            if value, SMAppService.mainApp.status != .enabled && SMAppService.mainApp.status != .requiresApproval { try SMAppService.mainApp.register() }
            else if !value, SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval { try SMAppService.mainApp.unregister() }
            enabled = value
            UserDefaults.standard.set(value, forKey: "launchAtLogin")
            error = nil
        } catch { self.error = "无法更新登录项：\(error.localizedDescription)" }
    }
}

@MainActor private final class SettingsSelection: ObservableObject {
    @Published var page: SharedSupport.SettingsPage = .general
}

@MainActor final class AetherSettingsController {
    private var window: NSWindow?
    private let navigation = SettingsSelection()
    private let startup: StartupController
    init(startup: StartupController) { self.startup = startup }
    var isVisible: Bool { window?.isVisible == true }
    func show(_ page: SharedSupport.SettingsPage) {
        navigation.page = page
        if window == nil {
            let controller = NSHostingController(rootView: AetherSettingsView(navigation: navigation, startup: startup))
            let window = NSWindow(contentViewController: controller)
            window.title = "Aether 设置"
            window.setFrameAutosaveName("AetherSettingsWindow")
            window.setContentSize(NSSize(width: 960, height: 680))
            window.minSize = NSSize(width: 860, height: 580)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct AetherSettingsView: View {
    @ObservedObject var navigation: SettingsSelection
    @ObservedObject var startup: StartupController
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 10) {
                    Image(systemName: "square.3.layers.3d").font(.title).foregroundStyle(.indigo)
                    VStack(alignment: .leading) { Text("Aether").font(.title3.bold()); Text("以太").foregroundStyle(.secondary).font(.caption) }
                }.padding(.horizontal, 16).padding(.top, 24)
                List(SharedSupport.SettingsPage.allCases, selection: $navigation.page) { page in
                    Label(page.title, systemImage: page.symbol).tag(page).padding(.vertical, 5)
                }.listStyle(.sidebar)
            }.frame(width: 185)
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
                    case .permissions: SettingsContent("权限") { PermissionSettingsView() }
                    }
                }
            }
            .id(navigation.page)
            .accessibilityIdentifier("AetherSettingsPage." + navigation.page.rawValue)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }.tint(.indigo)
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
        Form {
            Section {
                Toggle("登录时启动 Aether", isOn: Binding(get: { login.enabled }, set: login.set))
                LabeledContent("系统登录项状态", value: login.status)
                if let error = login.error { Text(error).foregroundStyle(.red) }
            } header: { Text("启动") }

        }.formStyle(.grouped)
    }
}

private struct PermissionSettingsView: View {
    @State private var accessibility = AXIsProcessTrusted()
    @State private var monitoring = CGPreflightListenEventAccess()
    var body: some View {
        Form {
            Section("辅助功能") {
                LabeledContent("状态", value: accessibility ? "已授权" : "未授权")
                Text("用于自动粘贴、快捷键映射、应用操作及系统时钟镜像。未授权时仍可记录和复制剪贴板、使用本地计时。")
                Button("打开辅助功能设置") { open("Privacy_Accessibility") }
            }
            Section("输入监控") {
                LabeledContent("状态", value: monitoring ? "已授权" : "未授权")
                Text("用于识别左右修饰键和物理中英键、快捷键提示及 ABC 自动切换防护。")
                Button("打开输入监控设置") { open("Privacy_ListenEvent") }
            }
            Section {
                Text("若系统要求重新打开应用，请使用菜单栏右键的“重新启动”。")
                Text("系统时钟镜像受 macOS 版本及系统接口限制；本地倒计时不依赖镜像。")
            }
        }.formStyle(.grouped)
        .task {
            while !Task.isCancelled {
                accessibility = AXIsProcessTrusted()
                monitoring = CGPreflightListenEventAccess()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }
    private func open(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + anchor) { NSWorkspace.shared.open(url) }
    }
}
