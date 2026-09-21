import AppKit
import SwiftUI
import SharedSupport
import ClipboardFeature
import ShortcutsFeature
import TimerFeature
import PromptFeature
import MemoFeature

enum ControlCenterTab: String, CaseIterable, Identifiable {
    case overview, clipboard, shortcuts, memo, prompt

    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: "概览"
        case .clipboard: "剪贴板"
        case .shortcuts: "快捷操作"
        case .memo: "备忘录"
        case .prompt: "Prompt"
        }
    }
}

@MainActor private final class ControlCenterNavigation: ObservableObject {
    @Published var tab: ControlCenterTab = .overview
    @Published var height: CGFloat = 600
    @Published var tabOrder: [ControlCenterTab]

    init(defaults: UserDefaults = AppEnvironment.controlCenterDefaults) {
        let saved = defaults.stringArray(forKey: "controlCenterTabOrder")?.compactMap(ControlCenterTab.init(rawValue:)) ?? []
        let known = saved.reduce(into: [ControlCenterTab]()) { result, tab in
            if !result.contains(tab) { result.append(tab) }
        }
        let missing = ControlCenterTab.allCases.filter { !known.contains($0) }
        tabOrder = known + missing
    }

    func move(_ tab: ControlCenterTab, before destination: ControlCenterTab) {
        guard tab != destination,
              let sourceIndex = tabOrder.firstIndex(of: tab),
              let destinationIndex = tabOrder.firstIndex(of: destination) else { return }
        tabOrder.move(fromOffsets: IndexSet(integer: sourceIndex), toOffset: destinationIndex)
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
        if let tab { navigation.tab = tab }
        if startup.ready { ClipboardModule.shared.captureTarget(); ShortcutsModule.shared.captureTarget() }
        let height = min(600, (button.window?.screen?.visibleFrame.height ?? 700) - 50)
        let width: CGFloat = 300
        navigation.height = max(350, height)
        if popover.contentViewController == nil {
            popover.contentViewController = NSHostingController(rootView: ControlCenterView(startup: startup, navigation: navigation).frame(width: width))
        }
        popover.contentSize = NSSize(width: width, height: navigation.height)
        if popover.isShown { return }
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
        for (title, action) in [("打开控制中心", #selector(openCenter)), ("Prompt 优化…", #selector(openPrompt)), ("设置…", #selector(openSettings)), ("重新启动", #selector(restart)), ("退出 Aether", #selector(quit))] {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self; menu.addItem(entry)
        }
        if let button = item.button { menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button) }
    }
    @objc private func openCenter() { show() }
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
            ControlCenterTabs(navigation: navigation)
                .padding(.horizontal, 8).padding(.bottom, 12)
            Divider()
            if startup.ready {
                switch navigation.tab {
                case .clipboard: ClipboardModule.shared.compactPanel()
                case .shortcuts: ShortcutsModule.shared.quickActions()
                case .memo: MemoModule.shared.compactPanel()
                case .prompt: PromptModule.shared.compactPanel()
                case .overview:
                    ScrollView {
                        TimerModule.shared.overview()
                            .background(.background, in: RoundedRectangle(cornerRadius: 12))
                            .padding(12)
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
        .frame(height: navigation.height)
        .tint(.indigo)
        .background(.regularMaterial)
        .onExitCommand { AppRouter.shared.send(.dismissPanels) }
    }
}

private struct ControlCenterTabs: View {
    @ObservedObject var navigation: ControlCenterNavigation
    @State private var dragging: ControlCenterTab?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(navigation.tabOrder) { tab in
                Button { navigation.tab = tab } label: {
                    Text(tab.title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(navigation.tab == tab ? .white : .primary)
                .background(navigation.tab == tab ? Color.indigo : .clear, in: RoundedRectangle(cornerRadius: 8))
                .onDrag {
                    dragging = tab
                    return NSItemProvider(object: tab.rawValue as NSString)
                }
                .onDrop(of: [.text], delegate: TabDropDelegate(destination: tab, navigation: navigation, dragging: $dragging))
                .accessibilityLabel(tab == .prompt ? "Prompt 优化" : tab.title)
                .accessibilityHint("按住并拖动调整页面位置")
                .accessibilityIdentifier("control-center.tab.\(tab.rawValue)")
            }
        }
        .padding(2)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityLabel("控制中心页面，可拖动调整顺序")
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
