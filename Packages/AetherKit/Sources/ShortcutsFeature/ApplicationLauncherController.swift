import SharedSupport
import AppKit
import ShortcutCore
import SwiftUI

final class ApplicationShortcutEventRouter {
    enum Phase { case pressed, released }

    var onEvent: (@MainActor (String, Phase) -> Void)?
    private let lock = NSLock()
    private var registeredKeyCodes = Set<UInt16>()
    private var activeKeyCodes = Set<UInt16>()

    func update(initials: Set<String>) {
        lock.withLock {
            registeredKeyCodes = Set(initials.compactMap(ApplicationLetterKey.keyCode(for:)))
        }
    }

    func handleKeyDown(
        keyCode: UInt16,
        modifiers: ShortcutModifiers,
        physicalModifiers: PhysicalModifierKeys,
        isRepeat: Bool
    ) -> Bool {
        guard modifiers == [.option], !physicalModifiers.contains(.capsLock),
              let initial = ApplicationLetterKey.letter(for: keyCode),
              lock.withLock({ registeredKeyCodes.contains(keyCode) })
        else { return false }
        if !isRepeat {
            lock.withLock { _ = activeKeyCodes.insert(keyCode) }
            Task { @MainActor [weak self] in self?.onEvent?(initial, .pressed) }
        }
        return true
    }

    func handleKeyUp(keyCode: UInt16) -> Bool {
        guard let initial = ApplicationLetterKey.letter(for: keyCode),
              lock.withLock({ activeKeyCodes.remove(keyCode) != nil })
        else { return false }
        Task { @MainActor [weak self] in self?.onEvent?(initial, .released) }
        return true
    }
}

final class ApplicationChooserNavigationRouter {
    enum Command { case previous, next, activate, dismiss }

    var onCommand: (@MainActor (Command) -> Void)?
    private let lock = NSLock()
    private var isVisible = false

    func setVisible(_ visible: Bool) { lock.withLock { isVisible = visible } }

    func handle(keyCode: UInt16, isRepeat: Bool) -> Bool {
        let command: Command
        switch keyCode {
        case 126: command = .previous
        case 125: command = .next
        case 36, 76: command = .activate
        case 53: command = .dismiss
        default: return false
        }
        guard lock.withLock({ isVisible }) else { return false }
        if !isRepeat {
            Task { @MainActor [weak self] in self?.onCommand?(command) }
        }
        return true
    }
}

@MainActor
final class ApplicationLauncherController {
    let eventRouter = ApplicationShortcutEventRouter()
    let navigationRouter = ApplicationChooserNavigationRouter()

    private let applicationsProvider: (String) -> [RegisteredApplication]
    private let defaultApplicationProvider: (String) -> RegisteredApplication?
    private let holdDurationProvider: () -> TimeInterval
    private let setDefaultHandler: (String?, String) -> Void
    private let moveApplicationsHandler: (String, IndexSet, Int) -> Void
    private let launchHandler: (RegisteredApplication) -> Void
    private var pendingInitial: String?
    private var holdTimer: Timer?
    private var displayedInitial: String?
    private var selectedIndex = 0
    private var panel: NSPanel?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?

    init(
        applicationsProvider: @escaping (String) -> [RegisteredApplication],
        defaultApplicationProvider: @escaping (String) -> RegisteredApplication?,
        holdDurationProvider: @escaping () -> TimeInterval,
        setDefaultHandler: @escaping (String?, String) -> Void,
        moveApplicationsHandler: @escaping (String, IndexSet, Int) -> Void,
        launchHandler: @escaping (RegisteredApplication) -> Void
    ) {
        self.applicationsProvider = applicationsProvider
        self.defaultApplicationProvider = defaultApplicationProvider
        self.holdDurationProvider = holdDurationProvider
        self.setDefaultHandler = setDefaultHandler
        self.moveApplicationsHandler = moveApplicationsHandler
        self.launchHandler = launchHandler
        eventRouter.onEvent = { [weak self] initial, phase in self?.handle(initial: initial, phase: phase) }
        navigationRouter.onCommand = { [weak self] command in self?.handle(command) }
    }

    func update(applications: [RegisteredApplication]) {
        eventRouter.update(initials: Set(applications.map(\.initial)))
        if let displayedInitial,
           !applications.contains(where: { $0.initial == displayedInitial }) {
            dismiss()
        } else if panel?.isVisible == true {
            refreshContent()
        }
    }

    func stop() {
        holdTimer?.invalidate()
        holdTimer = nil
        dismiss()
        panel = nil
    }

    private func handle(initial: String, phase: ApplicationShortcutEventRouter.Phase) {
        switch phase {
        case .pressed:
            guard panel?.isVisible != true else { return }
            holdTimer?.invalidate()
            pendingInitial = initial
            let timer = Timer(timeInterval: holdDurationProvider(), repeats: false) { [weak self] _ in
                Task { @MainActor in self?.showChooserIfNeeded(for: initial) }
            }
            timer.tolerance = 0.03
            RunLoop.main.add(timer, forMode: .common)
            holdTimer = timer
        case .released:
            guard pendingInitial == initial else { return }
            pendingInitial = nil
            holdTimer?.invalidate()
            holdTimer = nil
            guard panel?.isVisible != true else { return }
            if let application = defaultApplicationProvider(initial) {
                launchHandler(application)
            } else {
                showChooser(for: initial)
            }
        }
    }

    private func showChooserIfNeeded(for initial: String) {
        holdTimer = nil
        guard pendingInitial == initial, applicationsProvider(initial).count > 1 else { return }
        showChooser(for: initial)
    }

    private func showChooser(for initial: String) {
        let applications = applicationsProvider(initial)
        guard !applications.isEmpty else { return }
        displayedInitial = initial
        if let defaultApplication = defaultApplicationProvider(initial),
           let index = applications.firstIndex(of: defaultApplication) {
            selectedIndex = index
        } else {
            selectedIndex = 0
        }

        let screen = NSScreen.main ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let width: CGFloat = 430
        let height = min(CGFloat(520), CGFloat(112 + applications.count * 58))
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.setContentSize(NSSize(width: width, height: height))
        panel.setFrameOrigin(NSPoint(x: visibleFrame.midX - width / 2, y: visibleFrame.midY - height / 2))
        refreshContent()
        navigationRouter.setVisible(true)
        panel.orderFrontRegardless()
        startOutsideClickMonitoring()
    }

    private func handle(_ command: ApplicationChooserNavigationRouter.Command) {
        guard let initial = displayedInitial else { return }
        let applications = applicationsProvider(initial)
        guard !applications.isEmpty else { return }
        switch command {
        case .previous:
            selectedIndex = (selectedIndex - 1 + applications.count) % applications.count
            refreshContent()
        case .next:
            selectedIndex = (selectedIndex + 1) % applications.count
            refreshContent()
        case .activate:
            launch(applications[selectedIndex])
        case .dismiss:
            dismiss()
        }
    }

    private func launch(_ application: RegisteredApplication) {
        dismiss()
        launchHandler(application)
    }

    private func setDefault(_ application: RegisteredApplication) {
        guard let initial = displayedInitial else { return }
        setDefaultHandler(application.bundleIdentifier, initial)
        refreshContent()
    }

    private func moveApplications(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        guard let initial = displayedInitial else { return }
        let applications = applicationsProvider(initial)
        let selectedApplicationID = applications.indices.contains(selectedIndex)
            ? applications[selectedIndex].id
            : nil
        moveApplicationsHandler(initial, offsets, destination)
        if let selectedApplicationID,
           let updatedIndex = applicationsProvider(initial).firstIndex(where: { $0.id == selectedApplicationID }) {
            selectedIndex = updatedIndex
        }
        refreshContent()
    }

    private func refreshContent() {
        guard let panel, let initial = displayedInitial else { return }
        let applications = applicationsProvider(initial)
        guard !applications.isEmpty else { dismiss(); return }
        selectedIndex = min(selectedIndex, applications.count - 1)
        let defaultBundleIdentifier = defaultApplicationProvider(initial)?.bundleIdentifier
        panel.contentView = NSHostingView(rootView: ApplicationChooserView(
            initial: initial,
            applications: applications,
            selectedIndex: selectedIndex,
            defaultBundleIdentifier: defaultBundleIdentifier,
            select: { [weak self] index in self?.selectedIndex = index; self?.refreshContent() },
            launch: { [weak self] application in self?.launch(application) },
            setDefault: { [weak self] application in self?.setDefault(application) },
            move: { [weak self] offsets, destination in
                self?.moveApplications(fromOffsets: offsets, toOffset: destination)
            },
            dismiss: { [weak self] in self?.dismiss() }
        ))
    }

    private func dismiss() {
        holdTimer?.invalidate()
        holdTimer = nil
        pendingInitial = nil
        displayedInitial = nil
        navigationRouter.setVisible(false)
        stopOutsideClickMonitoring()
        panel?.orderOut(nil)
    }

    private func startOutsideClickMonitoring() {
        stopOutsideClickMonitoring()
        let mouseEvents: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseEvents) { [weak self] event in
            guard let self, self.panel?.isVisible == true, event.window !== self.panel else { return event }
            self.dismiss()
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseEvents) { [weak self] _ in
            Task { @MainActor in self?.dismiss() }
        }
    }

    private func stopOutsideClickMonitoring() {
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        localMouseMonitor = nil
        globalMouseMonitor = nil
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

private struct ApplicationChooserView: View {
    let initial: String
    let applications: [RegisteredApplication]
    let selectedIndex: Int
    let defaultBundleIdentifier: String?
    let select: (Int) -> Void
    let launch: (RegisteredApplication) -> Void
    let setDefault: (RegisteredApplication) -> Void
    let move: (IndexSet, Int) -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Option+\(initial) 应用选择").font(.title3.bold())
                    Text("拖动排序 · ↑/↓ 选择 · Enter 打开 · Esc 关闭").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: dismiss) { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain)
            }
            if defaultBundleIdentifier == nil, applications.count > 1 {
                Label("尚未设置默认应用，请点击星标设置", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(applications.enumerated()), id: \.element.id) { index, application in
                        HStack(spacing: 10) {
                            Button {
                                select(index)
                                launch(application)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: application.applicationPath))
                                        .resizable().frame(width: 32, height: 32)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(application.displayName).font(.callout.weight(.semibold))
                                        Text(application.applicationPath).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            Button { setDefault(application) } label: {
                                Image(systemName: defaultBundleIdentifier == application.bundleIdentifier ? "star.fill" : "star")
                                    .foregroundStyle(defaultBundleIdentifier == application.bundleIdentifier ? .yellow : .secondary)
                            }.buttonStyle(.plain).help("设为 Option+\(initial) 默认应用")
                            Image(systemName: "line.3.horizontal")
                                .font(.caption).foregroundStyle(.tertiary)
                                .help("拖动调整相对顺序")
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(
                            index == selectedIndex
                                ? Color.accentColor.opacity(0.18)
                                : Color.primary.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                        .id(application.id)
                        .listRowInsets(EdgeInsets(top: 3, leading: 0, bottom: 3, trailing: 0))
                        .listRowSeparator(.hidden)
                    }
                    .onMove(perform: move)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .onChange(of: selectedIndex) { _, _ in
                    if let selectedApplicationID { proxy.scrollTo(selectedApplicationID, anchor: .center) }
                }
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var selectedApplicationID: String? {
        applications.indices.contains(selectedIndex) ? applications[selectedIndex].id : nil
    }
}
