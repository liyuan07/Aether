import AppKit
import SwiftUI
import SharedSupport
import ClipboardFeature
import ShortcutsFeature
import TimerFeature

@MainActor final class MenuBarController: NSObject, NSPopoverDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let startup: StartupController
    init(startup: StartupController) {
        self.startup = startup
        super.init()
        let button = item.button!
        button.image = NSImage(systemSymbolName: "square.3.layers.3d", accessibilityDescription: "Aether · 以太")
        button.image?.isTemplate = true
        button.toolTip = "Aether · 以太"
        button.setAccessibilityIdentifier("AetherStatusItem")
        button.target = self
        button.action = #selector(clicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        popover.behavior = .transient
        popover.delegate = self
        popover.animates = true
    }
    func show() {
        guard let button = item.button else { return }
        if startup.ready { ClipboardModule.shared.captureTarget(); ShortcutsModule.shared.captureTarget() }
        let height = min(600, (button.window?.screen?.visibleFrame.height ?? 700) - 50)
        popover.contentViewController = NSHostingController(rootView: ControlCenterView(startup: startup).frame(width: 420, height: max(350, height)))
        popover.contentSize = NSSize(width: 420, height: max(350, height))
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
    func hide() { popover.performClose(nil) }
    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp { contextMenu() }
        else if popover.isShown { hide() } else { show() }
    }
    private func contextMenu() {
        hide()
        let menu = NSMenu()
        for (title, action) in [("打开控制中心", #selector(openCenter)), ("设置…", #selector(openSettings)), ("重新启动", #selector(restart)), ("退出 Aether", #selector(quit))] {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self; menu.addItem(entry)
        }
        if let button = item.button { menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button) }
    }
    @objc private func openCenter() { show() }
    @objc private func openSettings() { AppRouter.shared.send(.settings(.general)) }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func restart() {
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.1; done; exec /usr/bin/open \"$2\"", "aether-restart", String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundlePath]
        do { try helper.run(); NSApp.terminate(nil) }
        catch { let alert = NSAlert(error: error); alert.runModal() }
    }
}

private struct ControlCenterView: View {
    @ObservedObject var startup: StartupController
    @State private var tab = 0
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "square.3.layers.3d").font(.title2).foregroundStyle(.indigo)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Aether").font(.headline)
                    Text("以太 · 让常用操作触手可及").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button { AppRouter.shared.send(.settings(.general)) } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless).help("设置")
            }.padding(16)
            Picker("页面", selection: $tab) {
                Text("概览").tag(0)
                Text("剪贴板").tag(1)
                Text("快捷操作").tag(2)
            }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 14).padding(.bottom, 12)
            Divider()
            if startup.ready {
                switch tab {
                case 1: ClipboardModule.shared.compactPanel()
                case 2: ShortcutsModule.shared.quickActions()
                default:
                    ScrollView {
                        VStack(spacing: 12) {
                            TimerModule.shared.overview().background(.background, in: RoundedRectangle(cornerRadius: 12))
                            VStack(alignment: .leading, spacing: 12) {
                                Label("常用开关", systemImage: "switch.2").font(.headline)
                                ClipboardModule.shared.monitoringControl()
                                ShortcutsModule.shared.controls()
                            }.padding(14).background(.background, in: RoundedRectangle(cornerRadius: 12))
                        }.padding(12)
                    }
                }
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "tray.and.arrow.down").font(.largeTitle).foregroundStyle(.indigo)
                    Text("欢迎使用 Aether").font(.title3.bold())
                    Text(startup.message).foregroundStyle(.secondary)
                    Button("继续迁移") { startup.prepare() }.disabled(startup.importing)
                    if startup.importing { ProgressView() }
                }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .tint(.indigo)
        .background(.regularMaterial)
        .onExitCommand { AppRouter.shared.send(.dismissPanels) }
    }
}
