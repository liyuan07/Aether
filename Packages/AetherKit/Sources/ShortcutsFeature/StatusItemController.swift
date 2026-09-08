import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private struct SettingsRequest {
        let section: SettingsSection
        let ruleID: UUID?
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let model: AppModel
    private let openSettings: (SettingsSection, UUID?) -> Void
    private var cancellables = Set<AnyCancellable>()
    private var pendingSettingsRequest: SettingsRequest?

    init(model: AppModel, openSettings: @escaping (SettingsSection, UUID?) -> Void) {
        self.model = model
        self.openSettings = openSettings
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "KeyPilot")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "KeyPilot"
        }

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentSize = NSSize(width: 390, height: 430)
        popover.contentViewController = NSHostingController(
            rootView: QuickConfigView(
                model: model,
                openSettings: { [weak self] section in
                    self?.requestSettings(section: section)
                }
            )
        )

        model.$permissionGranted
            .sink { [weak self] isGranted in
                self?.statusItem.button?.contentTintColor = isGranted ? nil : .systemOrange
                self?.statusItem.button?.toolTip = isGranted ? "KeyPilot" : "KeyPilot：需要辅助功能权限"
            }
            .store(in: &cancellables)
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu(from: sender)
        } else {
            togglePopover(from: sender)
        }
    }

    func setVisible(_ visible: Bool) {
        statusItem.isVisible = visible
        if !visible { popover.performClose(nil) }
    }

    private func togglePopover(from button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func showContextMenu(from button: NSStatusBarButton) {
        popover.performClose(nil)
        let menu = NSMenu()
        menu.addItem(menuItem(title: "日常控制面板", action: #selector(openQuickConfig)))
        menu.addItem(menuItem(title: "完整设置…", action: #selector(openFullSettings)))
        menu.addItem(.separator())

        let permissionItem = menuItem(
            title: model.permissionGranted ? "辅助功能权限：已开启" : "辅助功能权限：需要开启…",
            action: #selector(openPermissionSettings)
        )
        if model.permissionGranted { permissionItem.isEnabled = false }
        menu.addItem(permissionItem)

        let inputMonitoringItem = menuItem(
            title: model.inputMonitoringGranted ? "输入监控权限：已开启" : "输入监控权限：需要开启…",
            action: #selector(openInputMonitoringSettings)
        )
        if model.inputMonitoringGranted { inputMonitoringItem.isEnabled = false }
        menu.addItem(inputMonitoringItem)
        menu.addItem(menuItem(title: "重新扫描冲突", action: #selector(rescanConflicts)))
        menu.addItem(.separator())
        menu.addItem(menuItem(title: "退出 KeyPilot", action: #selector(quitApplication)))
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    private func menuItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func openQuickConfig() {
        guard let button = statusItem.button else { return }
        togglePopover(from: button)
    }

    @objc private func openFullSettings() {
        requestSettings(section: .general)
    }

    @objc private func openPermissionSettings() {
        AccessibilityPermission.openSettings()
    }

    @objc private func openInputMonitoringSettings() {
        PhysicalModifierMonitor.openPrivacySettings()
    }

    @objc private func rescanConflicts() {
        model.rescanConflicts()
    }

    @objc private func quitApplication() {
        NSApp.terminate(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        deliverPendingSettingsRequest()
    }

    private func requestSettings(section: SettingsSection, ruleID: UUID? = nil) {
        pendingSettingsRequest = SettingsRequest(section: section, ruleID: ruleID)
        if popover.isShown {
            popover.performClose(nil)
        } else {
            deliverPendingSettingsRequest()
        }
    }

    private func deliverPendingSettingsRequest() {
        guard let request = pendingSettingsRequest else { return }
        pendingSettingsRequest = nil
        DispatchQueue.main.async { [weak self] in
            self?.openSettings(request.section, request.ruleID)
        }
    }
}
