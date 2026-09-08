import Foundation
import Testing
@testable import ShortcutCore

@Test("右 Option 实体按钮发送一次完整轻点")
func rightOptionButtonProducesCompleteTap() {
    #expect(ModifierTapSequence.tapDuration == 0.02)
    #expect(ModifierTapSequence.steps(for: .rightOption) == [
        ModifierTapStep(
            keyCode: 61,
            isKeyDown: true,
            modifiers: .option,
            physicalModifiers: .rightOption
        ),
        ModifierTapStep(keyCode: 61, isKeyDown: false, modifiers: [])
    ])
}

@Test("左右 Shift 实体按钮同时按下再完整松开")
func bothShiftButtonProducesCompleteTap() {
    #expect(ModifierTapSequence.steps(for: .bothShifts) == [
        ModifierTapStep(
            keyCode: 56,
            isKeyDown: true,
            modifiers: .shift,
            physicalModifiers: .leftShift
        ),
        ModifierTapStep(
            keyCode: 60,
            isKeyDown: true,
            modifiers: .shift,
            physicalModifiers: [.leftShift, .rightShift]
        ),
        ModifierTapStep(
            keyCode: 60,
            isKeyDown: false,
            modifiers: .shift,
            physicalModifiers: .leftShift
        ),
        ModifierTapStep(keyCode: 56, isKeyDown: false, modifiers: [])
    ])
}

@Test("应用设置可以保存和读取")
func appPreferencesRoundTrip() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = AppPreferencesStore(fileURL: directory.appendingPathComponent("preferences.json"))
    var configuration = AppPreferencesConfiguration()
    configuration.app.launchAtLogin = true
    configuration.app.blockAutomaticABC = true
    configuration.app.showModifierButtons = false

    try store.save(configuration)

    #expect(try store.load() == configuration)
}

@Test("应用名称按英文或拼音首字母注册")
func applicationInitialsSupportLatinAndChineseNames() {
    #expect(ApplicationInitialResolver.initial(for: "Google Chrome") == "G")
    #expect(ApplicationInitialResolver.initial(for: "抖音") == "D")
    #expect(ApplicationInitialResolver.initial(for: "高德地图") == "G")
    #expect(ApplicationInitialResolver.initial(for: "123") == nil)
}

@Test("应用首字母与 macOS 字母键码双向对应")
func applicationLetterKeyCodesRoundTrip() {
    for letter in "ABCDEFGHIJKLMNOPQRSTUVWXYZ".map(String.init) {
        let keyCode = ApplicationLetterKey.keyCode(for: letter)
        #expect(keyCode != nil)
        #expect(keyCode.flatMap(ApplicationLetterKey.letter(for:)) == letter)
    }
}

@Test("应用唤醒长按时间限制在可用范围")
func applicationShortcutHoldDurationIsClamped() {
    var preferences = ApplicationShortcutPreferences()
    preferences.holdDuration = 0.1
    #expect(preferences.normalizedHoldDuration() == 0.3)
    preferences.holdDuration = 2
    #expect(preferences.normalizedHoldDuration() == 1.5)
}

@Test("应用选择顺序保留用户设置并把新应用追加到末尾")
func applicationShortcutOrderKeepsPreferenceAndAppendsNewApplications() {
    let applications = [
        RegisteredApplication(bundleIdentifier: "c", displayName: "Code", applicationPath: "/C.app"),
        RegisteredApplication(bundleIdentifier: "a", displayName: "ChatGPT", applicationPath: "/A.app"),
        RegisteredApplication(bundleIdentifier: "b", displayName: "Chrome", applicationPath: "/B.app")
    ]

    let ordered = ApplicationOrderResolver.ordered(
        applications,
        preferredBundleIdentifiers: ["b", "missing", "a"]
    )

    #expect(ordered.map(\.bundleIdentifier) == ["b", "a", "c"])
}

@Test("拖动应用顺序时保留暂时未安装应用的位置")
func applicationShortcutReorderKeepsUnavailableApplications() {
    let applications = [
        RegisteredApplication(bundleIdentifier: "a", displayName: "ChatGPT", applicationPath: "/A.app"),
        RegisteredApplication(bundleIdentifier: "b", displayName: "Chrome", applicationPath: "/B.app"),
        RegisteredApplication(bundleIdentifier: "c", displayName: "Code", applicationPath: "/C.app")
    ]

    let updated = ApplicationOrderResolver.updatingPreference(
        ["a", "missing", "b"],
        availableApplications: applications,
        moving: IndexSet(integer: 1),
        toOffset: 0
    )

    #expect(updated == ["b", "missing", "a", "c"])
}

@Test("旧版应用快捷键配置缺少顺序字段时仍可迁移")
func legacyApplicationShortcutPreferencesDecodeWithoutOrder() throws {
    let json = """
    {"schemaVersion":7,"applicationShortcuts":{"defaultBundleIdentifiers":{"C":"a"},"holdDuration":0.6}}
    """

    let configuration = try JSONDecoder().decode(AppPreferencesConfiguration.self, from: Data(json.utf8))

    #expect(configuration.applicationShortcuts.defaultBundleIdentifiers == ["C": "a"])
    #expect(configuration.applicationShortcuts.orderedBundleIdentifiers.isEmpty)
    #expect(configuration.applicationShortcuts.holdDuration == 0.6)
}
@Test("旧输入法配置只迁移仍保留的通用设置")
func legacyInputConfigurationKeepsOnlySupportedPreferences() throws {
    let json = """
    {
      "schemaVersion": 5,
      "app": {"launchAtLogin": true},
      "general": {"blockAutomaticABC": true, "globalActivationTarget": {"current": {}}},
      "applicationRules": [{"name": "Terminal"}],
      "domainRules": [{"pattern": "*.example.com"}]
    }
    """
    let configuration = try JSONDecoder().decode(AppPreferencesConfiguration.self, from: Data(json.utf8))

    #expect(configuration.schemaVersion == AppPreferencesConfiguration.currentSchemaVersion)
    #expect(configuration.app.launchAtLogin)
    #expect(configuration.app.showModifierButtons)
    #expect(configuration.app.blockAutomaticABC)
    let encoded = String(decoding: try JSONEncoder().encode(configuration), as: UTF8.self)
    #expect(!encoded.contains("general"))
    #expect(!encoded.contains("applicationRules"))
    #expect(!encoded.contains("domainRules"))
}

@Test("旧版登录启动字段会迁移到应用设置")
func legacyLaunchAtLoginMigratesToAppPreferences() throws {
    let json = """
    {"schemaVersion":4,"general":{"launchAtLogin":true,"blockAutomaticABC":true}}
    """
    let configuration = try JSONDecoder().decode(AppPreferencesConfiguration.self, from: Data(json.utf8))

    #expect(configuration.app.launchAtLogin)
    #expect(configuration.app.blockAutomaticABC)
}

@Test("ABC 屏蔽为物理中英键建立手动会话，离开 ABC 后才恢复自动规则")
func abcSwitchGuardKeepsManualSessionUntilLeavingABC() {
    var guardState = ABCSwitchGuardState()
    #expect(guardState.decision(
        blockAutomaticABC: true,
        switchedToABC: true,
        canObservePhysicalKey: true,
        uptime: 10
    ) == .restoreDoubao)
    guardState.physicalInputSwitchKeyWasPressed(at: 20)
    #expect(guardState.decision(
        blockAutomaticABC: true,
        switchedToABC: true,
        canObservePhysicalKey: true,
        uptime: 21
    ) == .allowManualSwitch)
    #expect(guardState.isManualABCSessionActive)
    #expect(guardState.decision(
        blockAutomaticABC: false,
        switchedToABC: false,
        canObservePhysicalKey: true,
        uptime: 201
    ) == .ignore)
    #expect(!guardState.isManualABCSessionActive)
}

@Test("过期的物理中英键授权不会放行后续自动 ABC 切换")
func abcSwitchGuardExpiresUnusedPhysicalAuthorization() {
    var guardState = ABCSwitchGuardState()
    guardState.physicalInputSwitchKeyWasPressed(at: 10)
    #expect(guardState.decision(
        blockAutomaticABC: true,
        switchedToABC: true,
        canObservePhysicalKey: true,
        uptime: 10 + ABCSwitchGuardState.manualAuthorizationDuration + 0.1
    ) == .restoreDoubao)
}

@Test("事件 tap 能识别中英键和其他系统输入源切换键")
func physicalInputSwitchKeyCodesAreRecognized() {
    #expect(PhysicalInputSwitchKey.matches(keyCode: 57))
    #expect(PhysicalInputSwitchKey.matches(keyCode: 63))
    #expect(PhysicalInputSwitchKey.matches(keyCode: 102))
    #expect(PhysicalInputSwitchKey.matches(keyCode: 104))
    #expect(!PhysicalInputSwitchKey.matches(keyCode: 56))
    #expect(!PhysicalInputSwitchKey.matches(keyCode: 58))
}

@Test("默认快捷键与产品基线一致")
func defaultRulesMatchProductBaseline() {
    let rules = DefaultShortcutRules.make(desktopPath: "/Users/test/Desktop")

    #expect(rules.count == 20)
    #expect(rules.map(\.source) == [
        KeyCombination(keyCode: 18, modifiers: [.option], physicalModifiers: [.capsLock]),
        KeyCombination(keyCode: 19, modifiers: [.option], physicalModifiers: [.capsLock]),
        KeyCombination(keyCode: 17, modifiers: [.option], physicalModifiers: [.capsLock]),
        KeyCombination(keyCode: 123, modifiers: [.option], physicalModifiers: [.capsLock]),
        KeyCombination(keyCode: 124, modifiers: [.option], physicalModifiers: [.capsLock]),
        KeyCombination(keyCode: 125, modifiers: [.option], physicalModifiers: [.capsLock]),
        KeyCombination(keyCode: 126, modifiers: [.option], physicalModifiers: [.capsLock]),
        KeyCombination(keyCode: 2, modifiers: [.command, .shift]),
        KeyCombination(keyCode: 4, modifiers: [.command], physicalModifiers: [.capsLock]),
        KeyCombination(keyCode: 38, modifiers: [.command], physicalModifiers: [.capsLock]),
        KeyCombination(keyCode: 40, modifiers: [.command], physicalModifiers: [.capsLock]),
        KeyCombination(keyCode: 37, modifiers: [.command], physicalModifiers: [.capsLock]),
        KeyCombination(keyCode: 16, modifiers: [.command], physicalModifiers: [.capsLock]),
        KeyCombination(keyCode: 32, modifiers: [.command], physicalModifiers: [.capsLock]),
        KeyCombination(keyCode: 34, modifiers: [.command], physicalModifiers: [.capsLock]),
        KeyCombination(keyCode: 31, modifiers: [.command], physicalModifiers: [.capsLock]),
        KeyCombination(keyCode: 45, modifiers: [.command], physicalModifiers: [.capsLock]),
        KeyCombination(keyCode: 46, modifiers: [.command], physicalModifiers: [.capsLock]),
        KeyCombination(keyCode: 43, modifiers: [.command], physicalModifiers: [.capsLock]),
        KeyCombination(keyCode: 47, modifiers: [.command], physicalModifiers: [.capsLock])
    ])
    #expect(rules.filter { !$0.isEnabled }.isEmpty)

    #expect(rules[0].action == .finderFolder(path: "/Users/test/Desktop"))
    #expect(rules[1].action == .finderFolder(path: "/Users/test/Desktop/code"))
    #expect(rules[2].action == .terminal(fallbackPath: "/Users/test/Desktop", useFrontmostFinder: true))
    #expect(rules[3].action == .windowLayout(.leftHalf))
    #expect(rules[4].action == .windowLayout(.rightHalf))
    #expect(rules[5].action == .windowLayout(.bottomHalf))
    #expect(rules[6].action == .windowLayout(.topHalf))
    #expect(rules[7].action == .showDesktop)
    #expect(rules[8].action == .remap(to: KeyCombination(keyCode: 123, modifiers: [])))
    #expect(rules[9].action == .remap(to: KeyCombination(keyCode: 125, modifiers: [])))
    #expect(rules[10].action == .remap(to: KeyCombination(keyCode: 126, modifiers: [])))
    #expect(rules[11].action == .remap(to: KeyCombination(keyCode: 124, modifiers: [])))
    #expect(rules[12].action == .remap(to: KeyCombination(keyCode: 123, modifiers: [.option])))
    #expect(rules[13].action == .remap(to: KeyCombination(keyCode: 124, modifiers: [.command])))
    #expect(rules[14].action == .remap(to: KeyCombination(keyCode: 123, modifiers: [.command])))
    #expect(rules[15].action == .remap(to: KeyCombination(keyCode: 124, modifiers: [.option])))
    #expect(rules[16].action == .remap(to: KeyCombination(keyCode: 126, modifiers: [.option])))
    #expect(rules[17].action == .remap(to: KeyCombination(keyCode: 125, modifiers: [.command])))
    #expect(rules[18].action == .remap(to: KeyCombination(keyCode: 126, modifiers: [.command])))
    #expect(rules[19].action == .remap(to: KeyCombination(keyCode: 125, modifiers: [.option])))
}

@Test("现有配置只追加未占用的新默认快捷键")
func defaultRuleMigrationPreservesExistingConfiguration() {
    let occupiedOptionC = ShortcutRule(
        name: "用户自定义 Option+C",
        source: KeyCombination(keyCode: 8, modifiers: [.option]),
        action: .finderFolder(path: "/tmp/custom")
    )
    let existingRules = [occupiedOptionC]

    let migrated = DefaultShortcutRules.migrate(
        existingRules,
        fromVersion: 0,
        desktopPath: "/Users/test/Desktop"
    )

    #expect(migrated.count == 21)
    #expect(migrated.first == occupiedOptionC)
    #expect(migrated.filter { $0.source == occupiedOptionC.source } == [occupiedOptionC])
    #expect(!migrated.contains { $0.source == KeyCombination(keyCode: 46, modifiers: [.option]) })
    #expect(!migrated.contains { $0.source == KeyCombination(keyCode: 13, modifiers: [.option]) })
    #expect(migrated.contains { $0.source == KeyCombination(keyCode: 19, modifiers: [.option], physicalModifiers: [.capsLock]) })
    #expect(!migrated.contains { $0.source == KeyCombination(keyCode: 2, modifiers: [.option], physicalModifiers: [.capsLock]) })
    #expect(migrated.contains {
        $0.source == KeyCombination(keyCode: 2, modifiers: [.command, .shift])
            && $0.action == .showDesktop
    })
    #expect(migrated.contains { $0.source == KeyCombination(keyCode: 4, modifiers: [.command], physicalModifiers: [.capsLock]) })
    #expect(migrated.contains { $0.source == KeyCombination(keyCode: 38, modifiers: [.command], physicalModifiers: [.capsLock]) })
    #expect(migrated.contains { $0.source == KeyCombination(keyCode: 40, modifiers: [.command], physicalModifiers: [.capsLock]) })
    #expect(migrated.contains { $0.source == KeyCombination(keyCode: 37, modifiers: [.command], physicalModifiers: [.capsLock]) })
    #expect(migrated.contains { $0.source == KeyCombination(keyCode: 16, modifiers: [.command], physicalModifiers: [.capsLock]) })
    #expect(migrated.contains { $0.source == KeyCombination(keyCode: 47, modifiers: [.command], physicalModifiers: [.capsLock]) })

    let migratedAgain = DefaultShortcutRules.migrate(
        migrated,
        fromVersion: DefaultShortcutRules.currentMigrationVersion,
        desktopPath: "/Users/test/Desktop"
    )
    #expect(migratedAgain == migrated)
}

@Test("版本 3 迁移替换旧默认项且不覆盖用户配置")
func version3MigrationReplacesOnlyUnmodifiedDefaults() {
    let legacyDefault = ShortcutRule(
        name: "Vim 向左",
        source: KeyCombination(keyCode: 4, modifiers: [.option, .command]),
        action: .remap(to: KeyCombination(keyCode: 123, modifiers: []))
    )
    let customizedLegacyRule = ShortcutRule(
        name: "用户保留的旧组合",
        source: KeyCombination(keyCode: 38, modifiers: [.option, .command]),
        action: .finderFolder(path: "/tmp/custom")
    )
    let occupiedPhysicalH = ShortcutRule(
        name: "用户自定义物理 H",
        source: KeyCombination(
            keyCode: 4,
            modifiers: [.command],
            physicalModifiers: [.capsLock, .leftCommand]
        ),
        action: .finderFolder(path: "/tmp/physical")
    )

    let migrated = DefaultShortcutRules.migrate(
        [legacyDefault, customizedLegacyRule, occupiedPhysicalH],
        fromVersion: 2,
        desktopPath: "/Users/test/Desktop"
    )

    #expect(migrated.count == 22)
    #expect(!migrated.contains { $0.id == legacyDefault.id })
    #expect(migrated.contains(customizedLegacyRule))
    #expect(migrated.contains(occupiedPhysicalH))
    #expect(!migrated.contains { $0.source == KeyCombination(keyCode: 46, modifiers: [.option]) })
    #expect(migrated.filter { $0.source == occupiedPhysicalH.source } == [occupiedPhysicalH])
    #expect(migrated.contains { $0.source == KeyCombination(keyCode: 38, modifiers: [.command], physicalModifiers: [.capsLock]) })
    #expect(migrated.contains { $0.source == KeyCombination(keyCode: 40, modifiers: [.command], physicalModifiers: [.capsLock]) })
    #expect(migrated.contains { $0.source == KeyCombination(keyCode: 37, modifiers: [.command], physicalModifiers: [.capsLock]) })
}

@Test("版本 5 迁移替换旧文本导航布局且保留用户修改")
func version5MigrationReplacesOnlyUnmodifiedTextNavigationRules() {
    let physicalChord: PhysicalModifierKeys = [.capsLock, .leftCommand]
    let legacyU = ShortcutRule(
        name: "到当前段落结尾",
        source: KeyCombination(keyCode: 32, modifiers: [.command], physicalModifiers: physicalChord),
        action: .remap(to: KeyCombination(keyCode: 125, modifiers: [.option]))
    )
    let customizedI = ShortcutRule(
        name: "用户自定义 I",
        source: KeyCombination(keyCode: 34, modifiers: [.command], physicalModifiers: physicalChord),
        action: .finderFolder(path: "/tmp/custom-i")
    )

    let migrated = DefaultShortcutRules.migrate(
        [legacyU, customizedI],
        fromVersion: 4,
        desktopPath: "/Users/test/Desktop"
    )

    #expect(migrated.count == 21)
    #expect(!migrated.contains { $0.id == legacyU.id })
    #expect(migrated.contains(customizedI))
    #expect(migrated.contains {
        $0.source == KeyCombination(keyCode: 32, modifiers: [.command], physicalModifiers: [.capsLock])
            && $0.action == .remap(to: KeyCombination(keyCode: 124, modifiers: [.command]))
    })
    #expect(migrated.filter { $0.source == customizedI.source } == [customizedI])
}

@Test("版本 6 迁移交换内侧文本导航键且保留用户修改")
func version6MigrationSwapsInnerNavigationKeysAndPreservesCustomization() {
    let physicalChord: PhysicalModifierKeys = [.capsLock, .leftCommand]
    let legacyU = ShortcutRule(
        name: "到当前行开头",
        source: KeyCombination(keyCode: 32, modifiers: [.command], physicalModifiers: physicalChord),
        action: .remap(to: KeyCombination(keyCode: 123, modifiers: [.command]))
    )
    let customizedM = ShortcutRule(
        name: "用户自定义 M",
        source: KeyCombination(keyCode: 46, modifiers: [.command], physicalModifiers: physicalChord),
        action: .finderFolder(path: "/tmp/custom-m")
    )

    let migrated = DefaultShortcutRules.migrate(
        [legacyU, customizedM],
        fromVersion: 5,
        desktopPath: "/Users/test/Desktop"
    )

    #expect(migrated.count == 21)
    #expect(!migrated.contains { $0.id == legacyU.id })
    #expect(migrated.contains(customizedM))
    #expect(migrated.contains {
        $0.source == KeyCombination(keyCode: 32, modifiers: [.command], physicalModifiers: [.capsLock])
            && $0.action == .remap(to: KeyCombination(keyCode: 124, modifiers: [.command]))
    })
    #expect(migrated.filter { $0.source == customizedM.source } == [customizedM])
}

@Test("版本 8 和 9 迁移移除旧应用及显示桌面默认项")
func version8And9MigrationRemoveApplicationsAndDesktopShortcut() {
    let legacyCodex = ShortcutRule(
        name: "打开 Codex",
        source: KeyCombination(keyCode: 8, modifiers: [.option]),
        action: .application(
            target: ApplicationTarget(
                displayName: "Codex",
                bundleIdentifier: "com.openai.codex",
                applicationPath: "/Applications/ChatGPT.app"
            ),
            mode: .activateExisting
        )
    )
    let legacyDesktop = ShortcutRule(
        name: "显示桌面",
        source: KeyCombination(keyCode: 2, modifiers: [.option]),
        action: .showDesktop
    )
    var customizedDesktop = legacyDesktop
    customizedDesktop.id = UUID()
    customizedDesktop.name = "我自己的显示桌面"

    let migrated = DefaultShortcutRules.migrate(
        [legacyCodex, legacyDesktop, customizedDesktop],
        fromVersion: 7,
        desktopPath: "/Users/test/Desktop"
    )

    #expect(!migrated.contains { $0.id == legacyCodex.id })
    #expect(!migrated.contains { $0.id == legacyDesktop.id })
    #expect(migrated.contains(customizedDesktop))
    #expect(!migrated.contains {
        $0.source == KeyCombination(keyCode: 2, modifiers: [.option], physicalModifiers: [.capsLock])
            && $0.action == .showDesktop
    })
    #expect(migrated.filter { if case .application = $0.action { true } else { false } }.isEmpty)
}

@Test("版本 9 只删除未修改的中英显示桌面默认项")
func version9MigrationRemovesOnlyUnmodifiedDesktopShortcut() {
    let defaultDesktop = ShortcutRule(
        name: "显示桌面",
        source: KeyCombination(keyCode: 2, modifiers: [.option], physicalModifiers: [.capsLock]),
        action: .showDesktop
    )
    var customizedDesktop = defaultDesktop
    customizedDesktop.id = UUID()
    customizedDesktop.name = "我自己的显示桌面"

    let migrated = DefaultShortcutRules.migrate(
        [defaultDesktop, customizedDesktop],
        fromVersion: 8,
        desktopPath: "/Users/test/Desktop"
    )

    #expect(!migrated.contains { $0.id == defaultDesktop.id })
    #expect(migrated.contains(customizedDesktop))
}

@Test("版本 10 追加系统显示桌面且不覆盖已占用组合")
func version10MigrationAddsSystemShowDesktopWithoutOverwriting() {
    let source = KeyCombination(keyCode: 2, modifiers: [.command, .shift])
    let migrated = DefaultShortcutRules.migrate([], fromVersion: 9)

    #expect(migrated.count == 1)
    #expect(migrated[0].name == "系统显示桌面")
    #expect(migrated[0].source == source)
    #expect(migrated[0].action == .showDesktop)

    let occupied = ShortcutRule(
        name: "用户自定义 Command+Shift+D",
        source: source,
        action: .finderFolder(path: "/tmp/custom")
    )
    let occupiedMigration = DefaultShortcutRules.migrate([occupied], fromVersion: 9)

    #expect(occupiedMigration == [occupied])
}

@Test("旧版快捷键 JSON 缺少物理修饰键时仍可读取")
func legacyKeyCombinationDecodingDefaultsToNoPhysicalModifiers() throws {
    let data = Data(#"{"keyCode":4,"modifiers":8}"#.utf8)
    let shortcut = try JSONDecoder().decode(KeyCombination.self, from: data)

    #expect(shortcut == KeyCombination(keyCode: 4, modifiers: [.command]))
    #expect(shortcut.physicalModifiers.isEmpty)
}

@Test("物理修饰键组合显示来源与左右位置")
func physicalModifierShortcutDisplay() {
    let shortcut = KeyCombination(
        keyCode: 4,
        modifiers: [.command],
        physicalModifiers: [.capsLock, .leftCommand]
    )

    #expect(shortcut.displayString == "中英+左⌘+H")

    let capsLockOnlyShortcut = KeyCombination(
        keyCode: 4,
        modifiers: [.command],
        physicalModifiers: [.capsLock]
    )
    #expect(capsLockOnlyShortcut.displayString == "中英+H")

    let systemShortcut = KeyCombination(
        keyCode: 2,
        modifiers: [.option],
        physicalModifiers: [.capsLock]
    )
    #expect(systemShortcut.displayString == "中英+⌥+D")
}

@Test("中英组合不依赖它是否被映射成 Command")
func physicalInputSwitchShortcutIgnoresItsLogicalCommand() {
    let rule = ShortcutRule(
        name: "显示桌面",
        source: KeyCombination(keyCode: 2, modifiers: [.option], physicalModifiers: [.capsLock]),
        action: .showDesktop
    )

    #expect(ShortcutTriggerResolver.resolve(
        rule: rule,
        eventModifiers: [.option],
        activePhysicalModifiers: [.capsLock]
    ) != nil)
    #expect(ShortcutTriggerResolver.resolve(
        rule: rule,
        eventModifiers: [.option, .command],
        activePhysicalModifiers: [.capsLock]
    ) != nil)
    #expect(ShortcutTriggerResolver.resolve(
        rule: rule,
        eventModifiers: [.option, .command],
        activePhysicalModifiers: []
    ) == nil)
}

@Test("方向半屏组合为四分之一屏")
func windowLayoutCombinesDirectionsAndCalculatesFrames() {
    #expect(WindowLayout.combining([.leftHalf, .topHalf]) == .topLeft)
    #expect(WindowLayout.combining([.rightHalf, .bottomHalf]) == .bottomRight)
    #expect(WindowLayout.combining([.leftHalf]) == .leftHalf)
    #expect(WindowLayout.combining([.leftHalf, .rightHalf]) == nil)

    let visibleFrame = CGRect(x: 10, y: 20, width: 1001, height: 801)
    #expect(WindowLayout.leftHalf.frame(in: visibleFrame) == CGRect(x: 10, y: 20, width: 500, height: 801))
    #expect(WindowLayout.topRight.frame(in: visibleFrame) == CGRect(x: 510, y: 420, width: 501, height: 401))
    #expect(WindowLayout.bottomLeft.frame(in: visibleFrame) == CGRect(x: 10, y: 20, width: 500, height: 400))
}

@Test("窗口布局动作可以无损序列化")
func windowLayoutActionRoundTrip() throws {
    let action = ShortcutAction.windowLayout(.topRight)
    let data = try JSONEncoder().encode(action)
    #expect(try JSONDecoder().decode(ShortcutAction.self, from: data) == action)
}

@Test("映射规则支持 Shift 透传以扩展文本选择")
func remapRulePassesShiftThroughToTarget() {
    let rule = ShortcutRule(
        name: "向左跳一个单词",
        source: KeyCombination(
            keyCode: 16,
            modifiers: [.command],
            physicalModifiers: [.capsLock]
        ),
        action: .remap(to: KeyCombination(keyCode: 123, modifiers: [.option]))
    )

    let normal = ShortcutTriggerResolver.resolve(
        rule: rule,
        eventModifiers: [.command],
        activePhysicalModifiers: [.capsLock]
    )
    let selecting = ShortcutTriggerResolver.resolve(
        rule: rule,
        eventModifiers: [.command, .shift],
        activePhysicalModifiers: [.capsLock]
    )
    let unrelatedModifiers = ShortcutTriggerResolver.resolve(
        rule: rule,
        eventModifiers: [.command, .option],
        activePhysicalModifiers: [.capsLock]
    )

    #expect(normal?.action == .remap(to: KeyCombination(keyCode: 123, modifiers: [.option])))
    #expect(normal?.isExactModifierMatch == true)
    #expect(selecting?.action == .remap(to: KeyCombination(keyCode: 123, modifiers: [.option, .shift])))
    #expect(selecting?.isExactModifierMatch == false)
    #expect(unrelatedModifiers == nil)
}

@Test("双 Command 持续三秒后显示且松开时保持浮层")
func shortcutGuideHoldGesture() {
    var state = ShortcutGuideTriggerState(requiredModifiers: [.capsLock, .leftCommand])

    #expect(state.update(activeModifiers: [.capsLock]) == .none)
    #expect(state.update(activeModifiers: [.capsLock, .leftCommand]) == .schedule)
    #expect(state.holdThresholdReached() == .show)
    #expect(state.update(activeModifiers: [.capsLock]) == .release)
}

@Test("双 Command 期间按其他键会取消快捷键表")
func shortcutGuideDoesNotConflictWithShortcutChord() {
    var state = ShortcutGuideTriggerState(requiredModifiers: [.capsLock, .leftCommand])

    #expect(state.update(activeModifiers: [.capsLock, .leftCommand]) == .schedule)
    #expect(state.keyPressed() == .cancel)
    #expect(state.holdThresholdReached() == .none)
    #expect(state.update(activeModifiers: []) == .cancel)
}

@Test("快捷键表长按时间会限制范围并对齐半秒步进")
func shortcutGuideHoldDurationNormalization() {
    #expect(ShortcutGuideConfiguration.normalizedHoldDuration(-1) == 0.5)
    #expect(ShortcutGuideConfiguration.normalizedHoldDuration(2.74) == 2.5)
    #expect(ShortcutGuideConfiguration.normalizedHoldDuration(2.76) == 3)
    #expect(ShortcutGuideConfiguration.normalizedHoldDuration(20) == 10)
    #expect(ShortcutGuideConfiguration.normalizedHoldDuration(.infinity) == 3)
}

@Test("快捷键表分层导航支持左右循环")
func shortcutGuideLayerSelectionWraps() {
    var selection = ShortcutGuideLayerSelection()

    #expect(selection.reset(count: 3) == 0)
    #expect(selection.move(by: 1) == 1)
    #expect(selection.move(by: 1) == 2)
    #expect(selection.move(by: 1) == 0)
    #expect(selection.move(by: -1) == 2)
    #expect(selection.select(99) == 2)
}

@Test("快捷键表根据数量和宽度自适应栏数")
func shortcutGuideAdaptiveColumnCount() {
    #expect(ShortcutGuideLayout.columnCount(itemCount: 12, availableWidth: 1_200) == 2)
    #expect(ShortcutGuideLayout.columnCount(itemCount: 24, availableWidth: 1_200) == 3)
    #expect(ShortcutGuideLayout.columnCount(itemCount: 48, availableWidth: 1_200) == 4)
    #expect(ShortcutGuideLayout.columnCount(itemCount: 48, availableWidth: 800) == 3)
}

@Test("应用快捷键过滤器排除通用菜单且保留应用专属命令")
func applicationMenuShortcutFilterSeparatesStandardCommands() {
    let command: (UInt16, ShortcutModifiers) -> KeyCombination = {
        KeyCombination(keyCode: $0, modifiers: $1)
    }
    let editBranch = [
        command(6, [.command]),
        command(7, [.command]),
        command(8, [.command]),
        command(9, [.command]),
        command(0, [.command]),
        command(35, [.command, .shift])
    ]
    let windowBranch = [
        command(46, [.command]),
        command(13, [.command]),
        command(3, [.command, .control]),
        command(123, [.control]),
        command(18, [.command])
    ]

    #expect(!ApplicationMenuShortcutFilter.shouldInclude(
        command(12, [.command]),
        topLevelIndex: 1,
        branchShortcuts: []
    ))
    #expect(!ApplicationMenuShortcutFilter.shouldInclude(
        command(8, [.command]),
        topLevelIndex: 3,
        branchShortcuts: editBranch
    ))
    #expect(ApplicationMenuShortcutFilter.shouldInclude(
        command(35, [.command, .shift]),
        topLevelIndex: 3,
        branchShortcuts: editBranch
    ))
    #expect(!ApplicationMenuShortcutFilter.shouldInclude(
        command(123, [.control]),
        topLevelIndex: 7,
        branchShortcuts: windowBranch
    ))
    #expect(ApplicationMenuShortcutFilter.shouldInclude(
        command(18, [.command]),
        topLevelIndex: 7,
        branchShortcuts: windowBranch
    ))
    #expect(ApplicationMenuShortcutFilter.shouldInclude(
        command(123, [.control]),
        topLevelIndex: 4,
        branchShortcuts: [command(123, [.control])]
    ))
}

@Test("显示桌面动作可以无损序列化")
func showDesktopActionRoundTrip() throws {
    let action = ShortcutAction.showDesktop
    let encoded = try JSONEncoder().encode(action)
    let decoded = try JSONDecoder().decode(ShortcutAction.self, from: encoded)

    #expect(decoded == action)
}

@Test("配置可以无损保存和读取")
func storeRoundTrip() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ShortcutCoreTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = ShortcutRuleStore(fileURL: directory.appendingPathComponent("shortcuts.json"))
    let expected = DefaultShortcutRules.make(desktopPath: "/Users/test/Desktop")
    try store.save(expected)

    #expect(try store.load() == expected)
}

@Test("启用的重复快捷键会被识别")
func duplicateShortcutValidation() {
    let source = KeyCombination(keyCode: 14, modifiers: [.option])
    let first = ShortcutRule(name: "A", source: source, action: .finderFolder(path: "/tmp"))
    let second = ShortcutRule(name: "B", source: source, action: .finderFolder(path: "/tmp"))

    let issues = ShortcutRuleValidator.issues(in: [first, second])

    #expect(issues.contains(.duplicateShortcut(ruleIDs: [first.id, second.id], shortcut: source)))
}

@Test("普通 Option 与 Option+中英不视为重复快捷键")
func physicalInputSwitchNamespaceDoesNotConflictWithPlainOption() {
    let plain = ShortcutRule(
        name: "普通 Option+D",
        source: KeyCombination(keyCode: 2, modifiers: [.option]),
        action: .showDesktop
    )
    let physical = ShortcutRule(
        name: "Option+中英+D",
        source: KeyCombination(keyCode: 2, modifiers: [.option], physicalModifiers: [.capsLock]),
        action: .showDesktop
    )

    #expect(ShortcutRuleValidator.issues(in: [plain, physical]).isEmpty)
}

@Test("快捷键映射环路会被识别")
func remapCycleValidation() {
    let firstKey = KeyCombination(keyCode: 0, modifiers: [.option])
    let secondKey = KeyCombination(keyCode: 1, modifiers: [.option])
    let first = ShortcutRule(name: "A 到 B", source: firstKey, action: .remap(to: secondKey))
    let second = ShortcutRule(name: "B 到 A", source: secondKey, action: .remap(to: firstKey))

    let issues = ShortcutRuleValidator.issues(in: [first, second])

    #expect(issues.contains(.remapCycle(ruleIDs: [first.id, second.id])))
}

private func assertApplicationRule(
    _ rule: ShortcutRule,
    displayName: String,
    bundleIdentifier: String,
    path: String
) {
    guard case let .application(target, mode) = rule.action else {
        Issue.record("期望为应用动作：\(rule.name)")
        return
    }
    #expect(mode == .activateExisting)
    #expect(target.displayName == displayName)
    #expect(target.bundleIdentifier == bundleIdentifier)
    #expect(target.applicationPath == path)
}
