import SharedSupport
import AppKit
import ApplicationServices
import ServiceManagement
import ShortcutCore

@MainActor
final class ShortcutsRuntime: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var shortcutEngine: GlobalShortcutEngine?
    private var actionExecutor: ActionExecutor?
    private var settingsController: SettingsWindowController?
    private var shortcutGuideController: ShortcutGuideController?
    private var applicationLauncherController: ApplicationLauncherController?
    private var installedApplicationCatalog: InstalledApplicationCatalog?
    private var automaticABCGuardController: AutomaticABCGuardController?
    private var modifierButtonsController: ModifierButtonsController?
    private var lastAppGeneralPreferences: AppGeneralPreferences?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let executor = ActionExecutor(preferences: { [weak model] in
            model?.appPreferences.applicationShortcuts ?? ApplicationShortcutPreferences()
        })
        executor.onUndoAvailabilityChanged = { [weak model] available in
            model?.canRestoreWindowLayout = available
        }
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
            launchHandler: { [weak executor] application, display in
                executor?.execute(.application(
                    target: ApplicationTarget(
                        displayName: application.displayName,
                        bundleIdentifier: application.bundleIdentifier,
                        applicationPath: application.applicationPath
                    ),
                    mode: .activateExisting
                ), targetDisplay: display)
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
            actionHandler: { [weak executor] action, display in
                executor?.execute(action, targetDisplay: display)
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
            openClipboard: { AppRouter.shared.send(.clipboard) }
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
            ShortcutsModule.shared.rulesChanged?()
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


        model.onAppPreferencesChanged = { [weak self, weak abcGuard] configuration in
            abcGuard?.update(isEnabled: configuration.app.blockAutomaticABC)
            self?.applyAppGeneralPreferences(configuration.app)
        }
        applicationCatalog.onApplicationsChanged = { [weak model, weak applicationLauncher] applications in
            model?.setRegisteredApplications(applications)
            applicationLauncher?.update(applications: applications)
        }

        refreshPermission(promptIfNeeded: false)
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
        actionExecutor?.cancel()
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

    func execute(_ action: ShortcutAction) {
        actionExecutor?.execute(action, targetDisplay: ShortcutDisplayContext.capture())
    }

    func restoreLastWindowLayout() {
        actionExecutor?.restoreLastWindowLayout()
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
               !AppEnvironment.shortcutsDefaults.bool(forKey: "didRequestInputMonitoringPermission") {
                AppEnvironment.shortcutsDefaults.set(true, forKey: "didRequestInputMonitoringPermission")
                PhysicalModifierMonitor.requestAuthorization()
            }
        }

        if wasInputMonitoringGranted != isInputMonitoringGranted {
            model.notifyEngine()
            model.notifyAppPreferences()
            model.rescanConflicts()
        }

        if isGranted {
                shortcutEngine?.start()
            if !wasGranted {
                model.notifyEngine()
                model.notifyAppPreferences()
                model.rescanConflicts()
            }
            return
        }

        shortcutEngine?.stop()
        if promptIfNeeded, !AppEnvironment.shortcutsDefaults.bool(forKey: "didRequestAccessibilityPermission") {
            AppEnvironment.shortcutsDefaults.set(true, forKey: "didRequestAccessibilityPermission")
            AccessibilityPermission.request()
        }

    }

    private func applyAppGeneralPreferences(_ preferences: AppGeneralPreferences) {
        NSApp.setActivationPolicy(.accessory)
        modifierButtonsController?.setVisible(preferences.showModifierButtons)

        lastAppGeneralPreferences = preferences
    }

    private func restoreConfigurationAccess() {
        settingsController?.show(ruleID: nil)
    }
}
