import SharedSupport
import AppKit
import ShortcutCore
import SwiftUI

struct ShortcutGuideEntry: Identifiable {
    let rule: ShortcutRule
    let isExecutable: Bool

    var id: UUID { rule.id }
}

private enum ShortcutGuideExecution {
    case action(ShortcutAction)
    case shortcut(KeyCombination)
}

private struct ShortcutGuideItem: Identifiable {
    let id: String
    let name: String
    let detail: String
    let shortcut: KeyCombination
    let execution: ShortcutGuideExecution?
    let unavailableLabel: String?
    let originalOrder: Int
    var isFavorite: Bool
}

private struct ShortcutGuideLayer: Identifiable {
    let id: String
    var title: String
    var note: String
    var items: [ShortcutGuideItem]
    var emptyMessage: String
}

final class ShortcutGuideNavigationRouter {
    enum Command {
        case previous
        case next
        case dismiss
    }

    var onCommand: (@MainActor (Command) -> Void)?
    private let lock = NSLock()
    private var isVisible = false

    func setVisible(_ visible: Bool) {
        lock.withLock { isVisible = visible }
    }

    func handle(keyCode: UInt16, isRepeat: Bool) -> Bool {
        let command: Command
        switch keyCode {
        case 4, 123: command = .previous
        case 37, 124: command = .next
        case 53: command = .dismiss
        default: return false
        }
        guard lock.withLock({ isVisible }) else { return false }
        if !isRepeat {
            Task { @MainActor [weak self] in
                self?.onCommand?(command)
            }
        }
        return true
    }
}

@MainActor
final class ShortcutGuideController {
    let navigationRouter = ShortcutGuideNavigationRouter()
    var settingsHandler: (() -> Void)?

    private let entriesProvider: () -> [ShortcutGuideEntry]
    private let holdDurationProvider: () -> TimeInterval
    private let favoriteIDsProvider: () -> Set<String>
    private let favoriteToggleHandler: (String) -> Bool
    private let actionHandler: (ShortcutAction) -> Void
    private var triggerState = ShortcutGuideTriggerState(
        requiredModifiers: [.capsLock, .leftCommand]
    )
    private var layerSelection = ShortcutGuideLayerSelection()
    private var layers: [ShortcutGuideLayer] = []
    private var presentationID: UUID?
    private var holdTimer: Timer?
    private var panel: NSPanel?

    init(
        entriesProvider: @escaping () -> [ShortcutGuideEntry],
        holdDurationProvider: @escaping () -> TimeInterval,
        favoriteIDsProvider: @escaping () -> Set<String>,
        favoriteToggleHandler: @escaping (String) -> Bool,
        actionHandler: @escaping (ShortcutAction) -> Void
    ) {
        self.entriesProvider = entriesProvider
        self.holdDurationProvider = holdDurationProvider
        self.favoriteIDsProvider = favoriteIDsProvider
        self.favoriteToggleHandler = favoriteToggleHandler
        self.actionHandler = actionHandler
        navigationRouter.onCommand = { [weak self] command in
            self?.handle(command)
        }
    }

    func physicalModifiersDidChange(_ modifiers: PhysicalModifierKeys) {
        guard panel?.isVisible != true else { return }
        apply(triggerState.update(activeModifiers: modifiers))
    }

    func keyPressed() {
        guard panel?.isVisible != true else { return }
        apply(triggerState.keyPressed())
    }

    func stop() {
        dismissGuide()
        panel = nil
    }

    private func apply(_ transition: ShortcutGuideTriggerState.Transition) {
        switch transition {
        case .none:
            break
        case .schedule:
            holdTimer?.invalidate()
            let duration = ShortcutGuideConfiguration.normalizedHoldDuration(holdDurationProvider())
            let timer = Timer(timeInterval: duration, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.holdTimer = nil
                    self.apply(self.triggerState.holdThresholdReached())
                }
            }
            timer.tolerance = 0.05
            RunLoop.main.add(timer, forMode: .common)
            holdTimer = timer
        case .show:
            showGuide()
        case .cancel:
            holdTimer?.invalidate()
            holdTimer = nil
        case .release:
            break
        }
    }

    private func showGuide() {
        let presentationID = UUID()
        self.presentationID = presentationID
        let favoriteIDs = favoriteIDsProvider()

        let customItems = entriesProvider().enumerated().map { index, entry in
            let itemID = "custom|\(entry.id.uuidString)"
            return ShortcutGuideItem(
                id: itemID,
                name: entry.rule.name,
                detail: entry.rule.action.summary,
                shortcut: entry.rule.source,
                execution: entry.isExecutable ? .action(entry.rule.action) : nil,
                unavailableLabel: entry.isExecutable
                    ? nil
                    : (entry.rule.isEnabled ? "不可执行" : "已停用"),
                originalOrder: index,
                isFavorite: favoriteIDs.contains(itemID)
            )
        }
        layers = [
            ShortcutGuideLayer(
                id: "custom",
                title: "自定义",
                note: "KeyPilot 快捷键，按设置中的拖拽顺序显示",
                items: sortedByFavorite(customItems),
                emptyMessage: "还没有自定义快捷键"
            )
        ]

        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        if let application = frontmostApplication,
           application.bundleIdentifier != Bundle.main.bundleIdentifier {
            let applicationID = "application|\(application.processIdentifier)"
            let applicationName = application.localizedName
                ?? application.bundleIdentifier
                ?? "当前软件"
            let applicationFavoritePrefix = "application|\(application.bundleIdentifier ?? applicationName)"
            layers.append(
                ShortcutGuideLayer(
                    id: applicationID,
                    title: applicationName,
                    note: "正在读取该软件菜单公开的快捷键…",
                    items: [],
                    emptyMessage: "正在读取…"
                )
            )
            ApplicationShortcutCatalogProvider.shared.load(for: application) { [weak self] catalog in
                guard let self,
                      self.presentationID == presentationID,
                      let index = self.layers.firstIndex(where: { $0.id == applicationID })
                else { return }
                self.layers[index].title = catalog.applicationName
                self.layers[index].note = "仅包含该软件菜单公开的快捷键"
                self.layers[index].emptyMessage = "该软件没有公开可读取的菜单快捷键"
                let currentFavoriteIDs = self.favoriteIDsProvider()
                let items = catalog.shortcuts.enumerated().map { itemIndex, shortcut in
                    let itemID = "\(applicationFavoritePrefix)|\(shortcut.id)"
                    return ShortcutGuideItem(
                        id: itemID,
                        name: shortcut.name,
                        detail: shortcut.detail,
                        shortcut: shortcut.shortcut,
                        execution: .shortcut(shortcut.shortcut),
                        unavailableLabel: nil,
                        originalOrder: itemIndex,
                        isFavorite: currentFavoriteIDs.contains(itemID)
                    )
                }
                self.layers[index].items = self.sortedByFavorite(items)
                self.refreshContent()
            }
        }

        let systemItems = SystemShortcutCatalog.shortcuts.enumerated().map { index, shortcut in
            let itemID = "favorite|\(shortcut.id)"
            return ShortcutGuideItem(
                id: itemID,
                name: shortcut.name,
                detail: shortcut.detail,
                shortcut: shortcut.shortcut,
                execution: .shortcut(shortcut.shortcut),
                unavailableLabel: nil,
                originalOrder: index,
                isFavorite: favoriteIDs.contains(itemID)
            )
        }
        layers.append(
            ShortcutGuideLayer(
                id: "system",
                title: "系统",
                note: "常用 macOS 快捷键；实际启用状态和改键以系统设置为准",
                items: sortedByFavorite(systemItems),
                emptyMessage: "没有可显示的系统快捷键"
            )
        )
        layerSelection.reset(count: layers.count)
        presentPanel()
    }

    private func handle(_ command: ShortcutGuideNavigationRouter.Command) {
        switch command {
        case .previous:
            navigate(by: -1)
        case .next:
            navigate(by: 1)
        case .dismiss:
            dismissGuide()
        }
    }

    private func navigate(by offset: Int) {
        guard panel?.isVisible == true else { return }
        layerSelection.move(by: offset)
        refreshContent()
    }

    private func selectLayer(_ index: Int) {
        layerSelection.select(index)
        refreshContent()
    }

    private func activate(_ item: ShortcutGuideItem) {
        guard let execution = item.execution else { return }
        dismissGuide()
        switch execution {
        case let .action(action):
            actionHandler(action)
        case let .shortcut(shortcut):
            SyntheticKeySender.send(shortcut)
        }
    }

    private func toggleFavorite(_ item: ShortcutGuideItem) {
        let isFavorite = favoriteToggleHandler(item.id)
        for layerIndex in layers.indices {
            guard let itemIndex = layers[layerIndex].items.firstIndex(where: { $0.id == item.id }) else {
                continue
            }
            layers[layerIndex].items[itemIndex].isFavorite = isFavorite
            layers[layerIndex].items = sortedByFavorite(layers[layerIndex].items)
            break
        }
        refreshContent()
    }

    private func sortedByFavorite(_ items: [ShortcutGuideItem]) -> [ShortcutGuideItem] {
        items.sorted { lhs, rhs in
            if lhs.isFavorite != rhs.isFavorite { return lhs.isFavorite }
            return lhs.originalOrder < rhs.originalOrder
        }
    }

    private func presentPanel() {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let width = min(visibleFrame.width, max(CGFloat(760), visibleFrame.width * 0.86))
        let height = min(visibleFrame.height, max(CGFloat(600), visibleFrame.height * 0.86))
        let panel = panel ?? makePanel()
        panel.setContentSize(NSSize(width: width, height: height))
        self.panel = panel
        refreshContent()

        panel.setFrameOrigin(
            NSPoint(
                x: visibleFrame.midX - width / 2,
                y: visibleFrame.midY - height / 2
            )
        )
        panel.alphaValue = 0
        navigationRouter.setVisible(true)
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    private func refreshContent() {
        guard let panel, !layers.isEmpty else { return }
        let selectedIndex = min(layerSelection.index, layers.count - 1)
        let content = ShortcutGuideView(
            layers: layers,
            selectedIndex: selectedIndex,
            selectLayer: { [weak self] index in self?.selectLayer(index) },
            navigate: { [weak self] offset in self?.navigate(by: offset) },
            activate: { [weak self] item in self?.activate(item) },
            toggleFavorite: { [weak self] item in self?.toggleFavorite(item) },
            openSettings: { [weak self] in self?.openSettings() }
        )
        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = panel.contentView?.bounds
            ?? NSRect(origin: .zero, size: panel.contentRect(forFrameRect: panel.frame).size)
        panel.contentView = hostingView
    }

    private func dismissGuide() {
        holdTimer?.invalidate()
        holdTimer = nil
        presentationID = nil
        triggerState = ShortcutGuideTriggerState(
            requiredModifiers: [.capsLock, .leftCommand]
        )
        navigationRouter.setVisible(false)
        panel?.orderOut(nil)
    }

    private func openSettings() {
        dismissGuide()
        settingsHandler?()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.becomesKeyOnlyIfNeeded = true
        return panel
    }
}

private struct ShortcutGuideView: View {
    let layers: [ShortcutGuideLayer]
    let selectedIndex: Int
    let selectLayer: (Int) -> Void
    let navigate: (Int) -> Void
    let activate: (ShortcutGuideItem) -> Void
    let toggleFavorite: (ShortcutGuideItem) -> Void
    let openSettings: () -> Void

    private var selectedLayer: ShortcutGuideLayer {
        layers[selectedIndex]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("KeyPilot 快捷键")
                        .font(.title2.bold())
                    Text("松开按键后继续显示 · Esc 关闭 · H/L 或 ←/→ 切换层")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: openSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: 30, height: 30)
                        .background(Color.primary.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
                .help("打开 KeyPilot 设置")
            }

            HStack(spacing: 8) {
                Button { navigate(-1) } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)

                ForEach(Array(layers.enumerated()), id: \.element.id) { index, layer in
                    Button {
                        selectLayer(index)
                    } label: {
                        Text(layer.title)
                            .lineLimit(1)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity)
                            .background(
                                index == selectedIndex
                                    ? Color.accentColor.opacity(0.18)
                                    : Color.primary.opacity(0.05),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                }

                Button { navigate(1) } label: {
                    Image(systemName: "chevron.right")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
            }

            Text(selectedLayer.note)
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            if selectedLayer.items.isEmpty {
                ContentUnavailableView(
                    selectedLayer.emptyMessage,
                    systemImage: "keyboard"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geometry in
                    let columnCount = ShortcutGuideLayout.columnCount(
                        itemCount: selectedLayer.items.count,
                        availableWidth: geometry.size.width
                    )
                    let columns = Array(
                        repeating: GridItem(.flexible(), spacing: 8),
                        count: columnCount
                    )

                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(selectedLayer.items) { item in
                                ZStack(alignment: .topTrailing) {
                            Button {
                                activate(item)
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack(spacing: 8) {
                                        Text(item.shortcut.displayString)
                                            .font(.system(.callout, design: .monospaced, weight: .bold))
                                            .lineLimit(1)
                                        Spacer()
                                        if let unavailableLabel = item.unavailableLabel {
                                            Text(unavailableLabel)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Text(item.name)
                                        .font(.callout.weight(.semibold))
                                        .lineLimit(1)
                                    Text(item.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(
                                    Color.primary.opacity(item.execution == nil ? 0.035 : 0.07),
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                )
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(item.execution == nil)
                            .opacity(item.execution == nil ? 0.45 : 1)

                                    Button {
                                        toggleFavorite(item)
                                    } label: {
                                        Image(systemName: item.isFavorite ? "star.fill" : "star")
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(item.isFavorite ? Color.yellow : Color.secondary)
                                            .frame(width: 26, height: 26)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .padding(5)
                                    .help(item.isFavorite ? "取消收藏" : "收藏并置顶")
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.14), lineWidth: 1)
        }
    }
}
