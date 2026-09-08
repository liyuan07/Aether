/*
 * package counter
 * Derived from Atoll (DynamicIsland) and boring.notch
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import AppKit
import Combine
import Defaults
import SwiftUI

@main
struct PackageCounterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("设置…") {
                    SettingsWindowController.shared.showWindow()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

extension AppDelegate {
    static var shared: AppDelegate? {
        NSApplication.shared.delegate as? AppDelegate
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var windows: [NSScreen: NSWindow] = [:]
    var viewModels: [NSScreen: DynamicIslandViewModel] = [:]
    var window: NSWindow?

    let vm = DynamicIslandViewModel()
    private let coordinator = DynamicIslandViewCoordinator.shared
    private var previousScreens: [NSScreen] = []
    private var cancellables = Set<AnyCancellable>()
    private var windowsHiddenForLock = false
    private var statusItem: NSStatusItem?

    private lazy var statusMenu: NSMenu = {
        let menu = NSMenu()

        let settingsItem = NSMenuItem(
            title: "设置…",
            action: #selector(openSettings),
            keyEquivalent: ""
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        let restartItem = NSMenuItem(
            title: "重新启动 package counter",
            action: #selector(restartApplication),
            keyEquivalent: ""
        )
        restartItem.target = self
        menu.addItem(restartItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "退出 package counter",
            action: #selector(quitApplication),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }()

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Defaults[.enableTimerFeature] = true
        Defaults[.timerDisplayMode] = .tab
        Defaults[.timerControlWindowEnabled] = false
        coordinator.currentView = .timer

        LaunchAtLoginManager.shared.synchronizeWithSavedPreference()

        TimerControlWindowManager.shared.hide(animated: false)
        _ = EyeCareManager.shared
        _ = SystemTimerBridge.shared
        LockScreenManager.shared.configure(viewModel: vm)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenConfigurationDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            forName: .selectedScreenChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.adjustWindowPosition(changeAlpha: true)
            }
        }

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(onScreenLocked),
            name: NSNotification.Name(rawValue: "com.apple.screenIsLocked"),
            object: nil
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(onSystemWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(onSystemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(onScreenUnlocked),
            name: NSNotification.Name(rawValue: "com.apple.screenIsUnlocked"),
            object: nil
        )

        Defaults.publisher(.showOnAllDisplays, options: [])
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.rebuildWindows()
            }
            .store(in: &cancellables)

        Defaults.publisher(.openNotchWidth, options: [])
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.ensureWindowSize(self.requiredWindowSize(), animated: false, force: true)
            }
            .store(in: &cancellables)

        previousScreens = NSScreen.screens
        adjustWindowPosition(changeAlpha: true)
        configureStatusItem()
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        EyeCareManager.shared.stop()
        TimerControlWindowManager.shared.hide(animated: false)
        TimerInteractionPanelManager.shared.hide(animated: false)
        EyeCareBreakWindowManager.shared.hide()
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = item.button else { return }

        let image = NSImage(systemSymbolName: "timer", accessibilityDescription: "package counter")
        image?.isTemplate = true
        button.image = image
        button.toolTip = "package counter"
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            TimerInteractionPanelManager.shared.hide()
            showStatusMenu(from: sender)
            return
        }

        if EyeCareBreakWindowManager.shared.isVisible {
            EyeCareBreakWindowManager.shared.bringForward()
            return
        }

        TimerInteractionPanelManager.shared.present(
            using: viewModelForStatusItem(),
            triggerRect: statusItemScreenRect(for: sender)
        )
    }

    private func showStatusMenu(from button: NSStatusBarButton) {
        guard let statusItem else { return }
        statusItem.menu = statusMenu
        button.performClick(nil)
        statusItem.menu = nil
    }

    private func viewModelForStatusItem() -> DynamicIslandViewModel {
        guard let screen = statusItem?.button?.window?.screen else { return vm }
        return viewModels[screen] ?? vm
    }

    private func statusItemScreenRect(for button: NSStatusBarButton) -> CGRect? {
        guard let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    @objc private func openSettings() {
        TimerInteractionPanelManager.shared.hide()
        SettingsWindowController.shared.showWindow()
    }

    @objc private func restartApplication() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier,
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        NSApplication.shared.terminate(nil)
    }

    @objc private func quitApplication() {
        NSApplication.shared.terminate(nil)
    }

    private func createDynamicIslandWindow(
        for screen: NSScreen,
        with viewModel: DynamicIslandViewModel
    ) -> NSWindow {
        let size = adjustedSizeForScreen(requiredWindowSize(), screen: screen)
        let panel = DynamicIslandWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow],
            backing: .buffered,
            defer: false
        )
        panel.animationBehavior = .none
        panel.contentView = FirstMouseHostingView(
            rootView: ContentView().environmentObject(viewModel)
        )
        panel.orderFrontRegardless()
        return panel
    }

    private func requiredWindowSize() -> CGSize {
        var size = Defaults[.enableMinimalisticUI] ? minimalisticOpenNotchSize : openNotchSize
        size.height = 250
        return addShadowPadding(to: size, isMinimalistic: Defaults[.enableMinimalisticUI])
    }

    private func adjustedSizeForScreen(_ size: CGSize, screen: NSScreen) -> CGSize {
        guard shouldUseDynamicIslandMode(for: screen.localizedName) else { return size }
        return CGSize(
            width: size.width + dynamicIslandShadowInset * 2,
            height: size.height + dynamicIslandTopOffset
        )
    }

    func ensureWindowSize(_ size: CGSize, animated: Bool, force: Bool = false) {
        guard size.width > 0, size.height > 0 else { return }

        if Defaults[.showOnAllDisplays] {
            for (screen, panel) in windows {
                resize(panel, on: screen, to: adjustedSizeForScreen(size, screen: screen), force: force)
            }
        } else if let window {
            let screen = window.screen
                ?? NSScreen.screens.first(where: { $0.frame.intersects(window.frame) })
                ?? NSScreen.main
            if let screen {
                resize(window, on: screen, to: adjustedSizeForScreen(size, screen: screen), force: force)
            }
        }
    }

    private func resize(_ panel: NSWindow, on screen: NSScreen, to size: CGSize, force: Bool) {
        guard force || panel.frame.size != size else { return }
        let width = min(size.width, screen.frame.width)
        let height = min(size.height, screen.frame.height)
        panel.setFrame(
            NSRect(
                x: screen.frame.midX - width / 2,
                y: screen.frame.maxY - height,
                width: width,
                height: height
            ),
            display: true
        )
    }

    private func position(_ panel: NSWindow, on screen: NSScreen, changeAlpha: Bool) {
        if changeAlpha { panel.alphaValue = 0 }
        panel.setFrameOrigin(
            NSPoint(
                x: screen.frame.midX - panel.frame.width / 2,
                y: screen.frame.maxY - panel.frame.height
            )
        )
        if changeAlpha { panel.alphaValue = 1 }
    }

    @objc private func screenConfigurationDidChange() {
        TimerInteractionPanelManager.shared.hide(animated: false)
        let screens = NSScreen.screens
        let changed = screens.count != previousScreens.count
            || Set(screens.map(\.localizedName)) != Set(previousScreens.map(\.localizedName))
            || Set(screens.map(\.frame)) != Set(previousScreens.map(\.frame))
        previousScreens = screens
        if changed {
            rebuildWindows()
            EyeCareBreakWindowManager.shared.reposition(preferredScreenName: vm.screen)
        }
    }

    @objc func adjustWindowPosition(changeAlpha: Bool = false) {
        let builtInScreens = NSScreen.screens.filter(isBuiltInDisplay)

        if Defaults[.showOnAllDisplays] {
            let screens = Set(builtInScreens)

            for screen in windows.keys where !screens.contains(screen) {
                windows.removeValue(forKey: screen)?.close()
                viewModels.removeValue(forKey: screen)
            }

            for screen in screens {
                if windows[screen] == nil {
                    let viewModel = DynamicIslandViewModel(screen: screen.localizedName)
                    viewModels[screen] = viewModel
                    windows[screen] = createDynamicIslandWindow(for: screen, with: viewModel)
                }
                if let panel = windows[screen] {
                    position(panel, on: screen, changeAlpha: changeAlpha)
                }
            }
            return
        }

        let selectedScreen = builtInScreens.first {
            $0.localizedName == coordinator.preferredScreen
        } ?? NSScreen.main.flatMap { mainScreen in
            isBuiltInDisplay(mainScreen) ? mainScreen : nil
        } ?? builtInScreens.first

        guard let selectedScreen else {
            window?.close()
            window = nil
            return
        }

        coordinator.selectedScreen = selectedScreen.localizedName
        vm.screen = selectedScreen.localizedName
        vm.closedNotchSize = getClosedNotchSize(screen: selectedScreen.localizedName)
        vm.notchSize = vm.closedNotchSize

        if window == nil {
            window = createDynamicIslandWindow(for: selectedScreen, with: vm)
        }
        if let window {
            position(window, on: selectedScreen, changeAlpha: changeAlpha)
        }
    }

    private func rebuildWindows() {
        window?.close()
        window = nil
        windows.values.forEach { $0.close() }
        windows.removeAll()
        viewModels.removeAll()
        adjustWindowPosition(changeAlpha: true)
    }

    @objc private func onScreenLocked() {
        guard !windowsHiddenForLock else { return }
        windowsHiddenForLock = true
        EyeCareManager.shared.handleAway()
        vm.closeForLockScreen()
        TimerInteractionPanelManager.shared.hide(animated: false)
        windows.values.forEach { $0.orderOut(nil) }
        window?.orderOut(nil)
        LockScreenManager.shared.handleScreenLocked()
    }

    @objc private func onScreenUnlocked() {
        guard windowsHiddenForLock else { return }
        windowsHiddenForLock = false
        LockScreenManager.shared.handleScreenUnlocked()
        EyeCareManager.shared.handleReturn()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.windows.values.forEach { $0.orderFrontRegardless() }
            self.window?.orderFrontRegardless()
            self.adjustWindowPosition(changeAlpha: true)
        }
    }

    @objc private func onSystemWillSleep() {
        EyeCareManager.shared.handleAway()
    }

    @objc private func onSystemDidWake() {
        guard !LockScreenManager.shared.currentLockStatus else { return }
        EyeCareManager.shared.handleReturn()
    }
}

extension Notification.Name {
    static let selectedScreenChanged = Notification.Name("SelectedScreenChanged")
}

extension CGRect: @retroactive Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(origin.x)
        hasher.combine(origin.y)
        hasher.combine(size.width)
        hasher.combine(size.height)
    }
}
