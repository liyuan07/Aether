import AppKit
import SwiftUI
import SharedSupport
import ClipboardFeature
import ShortcutsFeature
import TimerFeature
import PromptFeature
import PortsFeature

@main struct AetherApp: App {
    @NSApplicationDelegateAdaptor(AetherDelegate.self) private var delegate
    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("设置…") { AppRouter.shared.send(.settings(.general)) }
                        .keyboardShortcut(",", modifiers: .command)
                }
            }
    }
}

@MainActor final class AetherDelegate: NSObject, NSApplicationDelegate {
    private var status: MenuBarController?
    private var settings: AetherSettingsController?
    private var started = false
    private let startup = StartupController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let peers = NSRunningApplication.runningApplications(withBundleIdentifier: "com.liyuan.aether")
        if peers.contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            peers.first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier })?.activate()
            NSApp.terminate(nil); return
        }
        AppRouter.shared.handler = { [weak self] route in self?.route(route) }
        settings = AetherSettingsController(startup: startup)
        status = MenuBarController(startup: startup)
        startup.onReady = { [weak self] in self?.startFeatures() }
        startup.prepare()
        if DataMigration(destination: AppEnvironment.root).receipt()?.phase != "complete" {
            settings?.show(.general)
        }
    }
    private func startFeatures() {
        guard !started else { return }
        started = true
        ShortcutsModule.shared.rulesChanged = {
            ClipboardModule.shared.builtInHotKeyAllowed = !ShortcutsModule.shared.claimsClipboardHotKey
            ClipboardModule.shared.refreshHotKey()
        }
        ShortcutsModule.shared.start()
        ClipboardModule.shared.builtInHotKeyAllowed = !ShortcutsModule.shared.claimsClipboardHotKey
        ClipboardModule.shared.start()
        TimerModule.shared.start()
        LoginService.shared.synchronize()
        if CommandLine.arguments.contains("--show-settings") { settings?.show(.general) }
    }
    private func route(_ route: AppRoute) {
        switch route {
        case .overview: status?.show(tab: .overview)
        case .clipboard:
            guard started else { settings?.show(.general); return }
            ClipboardModule.shared.captureTarget(); ShortcutsModule.shared.captureTarget()
            status?.hide()
            ClipboardModule.shared.showWindow()
        case .prompt:
            guard started else { settings?.show(.general); return }
            ClipboardModule.shared.hideWindow()
            status?.show(tab: .prompt)
        case let .settings(page):
            if started { ClipboardModule.shared.captureTarget(); ShortcutsModule.shared.captureTarget() }
            status?.hide()
            settings?.show(page)
        case .dismissPanels:
            status?.hide()
            if started { ClipboardModule.shared.hideWindow() }
        }
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        if started { ShortcutsModule.shared.refreshPermissions() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if settings?.isVisible != true { route(.overview) }
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        if started {
            ClipboardModule.shared.stop()
            ShortcutsModule.shared.stop()
            TimerModule.shared.stop()
            PromptModule.shared.stop()
            PortsModule.shared.stop()
        }
    }
}
