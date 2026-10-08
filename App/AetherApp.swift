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
    private var resourceScene: String?
    private let startup = StartupController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = AppEnvironment.resourceProfile
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
        if !AppEnvironment.isResourceProfiling, DataMigration(destination: AppEnvironment.root).receipt()?.phase != "complete" {
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
        if let profile = AppEnvironment.resourceProfile {
            do { try profile.recordLaunch(processIdentifier: ProcessInfo.processInfo.processIdentifier) }
            catch { NSApp.terminate(nil); return }
            if let index = CommandLine.arguments.firstIndex(of: "--resource-scene") {
                guard index + 1 < CommandLine.arguments.count else { NSApp.terminate(nil); return }
                resourceScene = CommandLine.arguments[index + 1]
                presentResourceScene()
                return
            }
        }
        if CommandLine.arguments.contains("--show-settings") { settings?.show(.general) }
    }
    private func presentResourceScene() {
        switch resourceScene {
        case "settings-closed", nil: break
        case "general-visible": settings?.show(.general)
        case "ports-visible": settings?.show(.ports)
        case "clipboard-visible":
            status?.hide()
            ClipboardModule.shared.presentWindow()
        default: NSApp.terminate(nil)
        }
    }
    private func route(_ route: AppRoute) {
        let plan = AppRoutePolicy.plan(for: route, ready: started)
        if plan.capture_targets != 0 {
            ClipboardModule.shared.captureTarget(); ShortcutsModule.shared.captureTarget()
        }
        if plan.hide_menu != 0 { status?.hide() }
        if plan.hide_clipboard != 0 { ClipboardModule.shared.hideWindow() }
        switch plan.presentation {
        case 1: status?.show(tab: .overview)
        case 2: ClipboardModule.shared.showWindow()
        case 3: status?.show(tab: .prompt)
        case 4: if case let .settings(page) = route { settings?.show(page) }
        case 5: settings?.show(.general)
        default: break
        }
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        if started { ShortcutsModule.shared.refreshPermissions() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if AppEnvironment.isResourceProfiling {
            if started { presentResourceScene() }
            return true
        }
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
