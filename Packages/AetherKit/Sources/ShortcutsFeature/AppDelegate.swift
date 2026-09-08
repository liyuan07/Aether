import AppKit
import ApplicationServices
import ServiceManagement
import ShortcutCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var shortcutEngine: GlobalShortcutEngine?
    private var actionExecutor: ActionExecutor?
    private var settingsController: SettingsWindowController?
    private var statusItemController: StatusItemController?
    private var shortcutGuideController: ShortcutGuideController?
    private var applicationLauncherController: ApplicationLauncherController?
    private var installedApplicationCatalog: InstalledApplicationCatalog?
    private var automaticABCGuardController: AutomaticABCGuardController?
    private var modifierButtonsController: ModifierButtonsController?
    private var permissionTimer: Timer?
    private var lastAppGeneralPreferences: AppGeneralPreferences?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let executor = ActionExecutor()
        let abcGuard = AutomaticABCGuardController(isEnabled: model.appPreferences.app.blockAutomaticABC)
        let applicationLauncher = ApplicationLauncherController(
            applicationsProvider: { [weak model] initial in model?.applications(for: initial) ?? [] },
            defaultApplicationProvider: { [weak model] initial in model?.defaultApplication(for: initial) },
            holdDurationProvider: { [weak model] in
                model?.appPreferences.applicationShortcuts.normalizedHoldDuration() ?? 0.5
            },
            setDefaultHandler: { [weak model] bundleIdentifier, initial in
                model?.setDefaultApplication(bundleIdentifier: bundleIdentifier, for: initial)
            },
            moveApplicationsHandler: { [weak model] initial, offsets, destination in
                model?.moveApplications(for: initial, fromOffsets: offsets, toOffset: destination)
            },
            launchHandler: { [weak executor] application in
                executor?.execute(.application(
                    target: ApplicationTarget(
                        displayName: application.displayName,
                        bundleIdentifier: application.bundleIdentifier,
                        applicationPath: application.applicationPath
                    ),
                    mode: .activateExisting
                ))
            }
        )
        let applicationCatalog = InstalledApplicationCatalog()
        let guide = ShortcutGuideController(
            entriesProvider: { [weak model] in
                guard let model else { return [] }
                let executableIDs = model.executableRuleIDs
                return model.rules.map {
                    ShortcutGuideEntry(rule: $0, isExecutable: executableIDs.contains($0.id))
                }
            },
            holdDurationProvider: { [weak model] in
                model?.shortcutGuideHoldDuration ?? ShortcutGuideConfiguration.defaultHoldDuration
            },
            favoriteIDsProvider: { [weak model] in
                model?.shortcutGuideFavoriteIDs ?? []
            },
            favoriteToggleHandler: { [weak model] id in
                model?.toggleShortcutGuideFavorite(id) ?? false
            },
            actionHandler: { [weak executor] action in
                executor?.execute(action)
            }
        )
        let engine = GlobalShortcutEngine(
            actionHandler: { [weak executor] action in
                executor?.execute(action)
            },
            keyDownObserver: { [weak guide] in
                guide?.keyPressed()
            },
            keyDownObservationChord: [.capsLock, .leftCommand],
            inputSwitchKeyObserver: { [weak abcGuard] in
                abcGuard?.physicalInputSwitchKeyWasPressed()
            },
            guideNavigationHandler: { [weak guide, weak applicationLauncher] keyCode, isRepeat in
                if applicationLauncher?.navigationRouter.handle(keyCode: keyCode, isRepeat: isRepeat) == true {
                    return true
                }
                return guide?.navigationRouter.handle(keyCode: keyCode, isRepeat: isRepeat) ?? false
            },
            applicationKeyDownHandler: { [weak applicationLauncher] keyCode, modifiers, physicalModifiers, isRepeat in
                applicationLauncher?.eventRouter.handleKeyDown(
                    keyCode: keyCode,
                    modifiers: modifiers,
                    physicalModifiers: physicalModifiers,
                    isRepeat: isRepeat
                ) ?? false
            },
            applicationKeyUpHandler: { [weak applicationLauncher] keyCode in
                applicationLauncher?.eventRouter.handleKeyUp(keyCode: keyCode) ?? false
            },
            recoveryHandler: { [weak self] in
                self?.restoreConfigurationAccess()
            }
        )
        actionExecutor = executor
        automaticABCGuardController = abcGuard
        let modifierButtons = ModifierButtonsController(
            openBilldDesk: { [weak executor] in
                executor?.execute(.application(
                    target: ApplicationTarget(
                        displayName: "BilldDesk",
                        bundleIdentifier: "com.hsslive.billdDeskFlutterPro",
                        applicationPath: "/Applications/BilldDesk.app"
                    ),
                    mode: .activateExisting
                ))
            },
            openClipboard: { [weak executor] in
                executor?.execute(.application(
                    target: ApplicationTarget(
                        displayName: "Clipboard",
                        bundleIdentifier: "com.liyuan07.clipboard",
                        applicationPath: "/Applications/Clipboard.app"
                    ),
                    mode: .activateExisting
                ))
            }
        )
        modifierButtonsController = modifierButtons
        applicationLauncherController = applicationLauncher
        installedApplicationCatalog = applicationCatalog
        shortcutEngine = engine
        shortcutGuideController = guide
        PhysicalModifierMonitor.shared.onModifiersChanged = { [weak guide] modifiers in
            guide?.physicalModifiersDidChange(modifiers)
        }
        PhysicalModifierMonitor.shared.onInputSwitchKey = { [weak abcGuard] in
            abcGuard?.physicalInputSwitchKeyWasPressed()
        }
        model.onExecutableRulesChanged = { [weak engine] rules in
            engine?.updateRules(rules)
        }
        model.onConflictScanRequested = { [weak model] rules in
            ConflictScanner.shared.scan(rules: rules) { findings in
                model?.finishConflictScan(findings)
            }
        }
        let settings = SettingsWindowController(
            model: model,
            presentationChanged: { [weak modifierButtons] isPresented in
                modifierButtons?.setSettingsPresented(isPresented)
            }
        )
        settingsController = settings
        guide.settingsHandler = { [weak settings] in settings?.show(section: .shortcuts) }
        statusItemController = StatusItemController(
            model: model,
            openSettings: { [weak settings] section, ruleID in
                settings?.show(section: section, ruleID: ruleID)
            }
        )

        model.onAppPreferencesChanged = { [weak self, weak abcGuard] configuration in
            abcGuard?.update(isEnabled: configuration.app.blockAutomaticABC)
            self?.applyAppGeneralPreferences(configuration.app)
        }
        applicationCatalog.onApplicationsChanged = { [weak model, weak applicationLauncher] applications in
            model?.setRegisteredApplications(applications)
            applicationLauncher?.update(applications: applications)
        }

        refreshPermission(promptIfNeeded: true)
        model.notifyEngine()
        modifierButtons.start(isVisible: model.appPreferences.app.showModifierButtons)
        abcGuard.start()
        applicationCatalog.start()
        model.notifyAppPreferences()
        model.rescanConflicts()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        refreshPermission(promptIfNeeded: false)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settingsController?.show()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        permissionTimer?.invalidate()
        shortcutEngine?.stop()
        shortcutGuideController?.stop()
        applicationLauncherController?.stop()
        installedApplicationCatalog?.stop()
        automaticABCGuardController?.stop()
        modifierButtonsController?.stop()
        PhysicalModifierMonitor.shared.onModifiersChanged = nil
        PhysicalModifierMonitor.shared.onInputSwitchKey = nil
        PhysicalModifierMonitor.shared.stop()
        model.flushSave()
    }

    private func refreshPermission(promptIfNeeded: Bool) {
        let wasGranted = model.permissionGranted
        let isGranted = AccessibilityPermission.isGranted
        let wasInputMonitoringGranted = model.inputMonitoringGranted
        let isInputMonitoringGranted = PhysicalModifierMonitor.isAuthorized
        model.permissionGranted = isGranted
        model.inputMonitoringGranted = isInputMonitoringGranted
        modifierButtonsController?.updateAccessibilityPermission(isGranted: isGranted)

        if isInputMonitoringGranted {
            PhysicalModifierMonitor.shared.start()
        } else {
            PhysicalModifierMonitor.shared.stop()
            if promptIfNeeded,
               !UserDefaults.standard.bool(forKey: "didRequestInputMonitoringPermission") {
                UserDefaults.standard.set(true, forKey: "didRequestInputMonitoringPermission")
                PhysicalModifierMonitor.requestAuthorization()
            }
        }

        if wasInputMonitoringGranted != isInputMonitoringGranted {
            model.notifyEngine()
            model.notifyAppPreferences()
            model.rescanConflicts()
        }

        if isGranted {
            permissionTimer?.invalidate()
            permissionTimer = nil
            shortcutEngine?.start()
            if !wasGranted {
                model.notifyEngine()
                model.notifyAppPreferences()
                model.rescanConflicts()
            }
            return
        }

        shortcutEngine?.stop()
        if promptIfNeeded, !UserDefaults.standard.bool(forKey: "didRequestAccessibilityPermission") {
            UserDefaults.standard.set(true, forKey: "didRequestAccessibilityPermission")
            AccessibilityPermission.request()
        }

        if permissionTimer == nil {
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.refreshPermission(promptIfNeeded: false)
                }
            }
        }
    }

    private func applyAppGeneralPreferences(_ preferences: AppGeneralPreferences) {
        statusItemController?.setVisible(true)
        NSApp.setActivationPolicy(.accessory)
        modifierButtonsController?.setVisible(preferences.showModifierButtons)

        guard lastAppGeneralPreferences?.launchAtLogin != preferences.launchAtLogin else {
            lastAppGeneralPreferences = preferences
            return
        }
        do {
            if preferences.launchAtLogin {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else if SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            model.reportError("更新登录启动失败：\(error.localizedDescription)")
        }
        lastAppGeneralPreferences = preferences
    }

    private func restoreConfigurationAccess() {
        statusItemController?.setVisible(true)
        settingsController?.show(ruleID: nil)
    }
}
