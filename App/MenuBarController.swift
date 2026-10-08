import AppKit
import SwiftUI
import SharedSupport
import ClipboardFeature
import ShortcutsFeature
import TimerFeature
import PromptFeature
import MemoFeature
import PortsFeature

typealias ControlCenterTab = ControlCenterDestination

@MainActor private final class ControlCenterNavigation: ObservableObject {
    @Published var tab: ControlCenterTab = .overview
    @Published var height: CGFloat = 580
    @Published var width: CGFloat = AetherLayout.panelWidth
    @Published var showing = false
    @Published var tabOrder: [ControlCenterTab]

    init(defaults: UserDefaults = AppEnvironment.controlCenterDefaults) {
        tabOrder = ControlCenterDestination.entryOrder(saved: defaults.stringArray(forKey: "controlCenterTabOrder") ?? [])
    }

    func move(_ tab: ControlCenterTab, before destination: ControlCenterTab) {
        tabOrder = ControlCenterDestination.moving(tab, before: destination, in: tabOrder)
        AppEnvironment.controlCenterDefaults.set(tabOrder.map(\.rawValue), forKey: "controlCenterTabOrder")
    }
}

@MainActor final class MenuBarController: NSObject, NSPopoverDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let startup: StartupController
    private let navigation = ControlCenterNavigation()
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
    func show(tab: ControlCenterTab? = nil) {
        guard let button = item.button else { return }
        // A popover otherwise inherits the status item's appearance rather than the app override.
        popover.appearance = NSApp.appearance
        navigation.tab = .opening(explicit: tab)
        if startup.ready { ClipboardModule.shared.captureTarget(); ShortcutsModule.shared.captureTarget() }
        let height = min(580, (button.window?.screen?.visibleFrame.height ?? 700) - 50)
        let width = min(AetherLayout.panelWidth, (button.window?.screen?.visibleFrame.width ?? 360) - 24)
        navigation.height = max(1, height)
        navigation.width = width
        if popover.contentViewController == nil {
            popover.contentViewController = NSHostingController(rootView: ControlCenterView(startup: startup, navigation: navigation))
        }
        popover.contentSize = NSSize(width: width, height: navigation.height)
        if popover.isShown { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        navigation.showing = true
        PortsModule.shared.setSummaryVisible(startup.ready && navigation.tab == .overview)
    }
    func hide() { popover.performClose(nil); navigation.showing = false; PortsModule.shared.setSummaryVisible(false) }
    func popoverDidClose(_ notification: Notification) {
        navigation.showing = false
        PortsModule.shared.setSummaryVisible(false)
    }
    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp { contextMenu() }
        else if popover.isShown { hide() } else { show() }
    }
    private func contextMenu() {
        hide()
        let menu = NSMenu()
        let groups: [[(String, Selector)]] = [
            [("打开首页", #selector(openCenter)), ("剪贴板", #selector(openClipboard)),
             ("快捷操作", #selector(openShortcuts)), ("备忘录", #selector(openMemo)), ("提示词优化", #selector(openPrompt))],
            [("设置…", #selector(openSettings))],
            [("重新启动", #selector(restart)), ("退出 Aether", #selector(quit))]
        ]
        for (index, group) in groups.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            for (title, action) in group {
                let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
                entry.target = self
                menu.addItem(entry)
            }
        }
        if let button = item.button { menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button) }
    }
    @objc private func openCenter() { show() }
    @objc private func openClipboard() { show(tab: .clipboard) }
    @objc private func openShortcuts() { show(tab: .shortcuts) }
    @objc private func openMemo() { show(tab: .memo) }
    @objc private func openPrompt() { AppRouter.shared.send(.prompt) }
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
    @ObservedObject var navigation: ControlCenterNavigation
    var body: some View {
        VStack(spacing: 0) {
            if startup.ready {
                switch navigation.tab {
                case .clipboard: ClipboardModule.shared.compactPanel()
                case .shortcuts: ShortcutsModule.shared.quickActions()
                case .memo: MemoModule.shared.compactPanel()
                case .prompt: PromptModule.shared.compactPanel()
                case .overview:
                    VStack(spacing: 0) {
                        PanelToolbar("Aether") {
                            Button { AppRouter.shared.send(.settings(.general)) } label: { Image(systemName: "gearshape") }
                                .help("设置").accessibilityLabel("设置")
                        }
                        Divider()
                        ScrollView {
                            VStack(spacing: 16) {
                                ControlCenterEntries(navigation: navigation)
                                TimerModule.shared.overview(isVisible: navigation.showing)
                                PortsModule.shared.summary()
                            }.padding(12)
                        }
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
        .environment(\.panelBackAction, { navigation.tab = .overview })
        .font(.system(size: 13))
        .controlSize(.small)
        .frame(width: navigation.width, height: navigation.height)
        .tint(.indigo)
        .background(.regularMaterial)
        .onExitCommand { AppRouter.shared.send(.dismissPanels) }
        .onChange(of: navigation.tab) { _, tab in
            PortsModule.shared.setSummaryVisible(startup.ready && navigation.showing && tab == .overview)
        }
        .onChange(of: startup.ready) { _, ready in
            PortsModule.shared.setSummaryVisible(ready && navigation.showing && navigation.tab == .overview)
        }
    }
}

private struct ControlCenterEntries: View {
    @ObservedObject var navigation: ControlCenterNavigation
    @State private var dragging: ControlCenterTab?

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            ForEach(navigation.tabOrder) { tab in
                Button { navigation.tab = tab } label: {
                    HStack(spacing: 8) {
                        Image(systemName: tab.symbol).foregroundStyle(.tint).frame(width: 20)
                        Text(tab.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 10).frame(minHeight: 40)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onDrag {
                    dragging = tab
                    return NSItemProvider(object: tab.rawValue as NSString)
                }
                .onDrop(of: [.text], delegate: TabDropDelegate(destination: tab, navigation: navigation, dragging: $dragging))
                .accessibilityHint("按住并拖动调整入口位置")
                .accessibilityIdentifier("control-center.tab.\(tab.rawValue)")
            }
        }
        .accessibilityLabel("功能入口，可拖动调整顺序")
    }
}

private struct TabDropDelegate: DropDelegate {
    let destination: ControlCenterTab
    let navigation: ControlCenterNavigation
    @Binding var dragging: ControlCenterTab?

    func dropEntered(info: DropInfo) {
        guard let dragging else { return }
        navigation.move(dragging, before: destination)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}
