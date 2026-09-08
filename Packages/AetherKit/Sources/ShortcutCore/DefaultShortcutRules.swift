import Foundation

public enum DefaultShortcutRules {
    public static let currentMigrationVersion = 10

    public static func make(desktopPath: String? = nil) -> [ShortcutRule] {
        let desktop = desktopPath ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first?.path ?? "~/Desktop"

        return version10Rules(desktop: desktop) + version7Rules()
    }

    public static func mergingAdditions(
        into existingRules: [ShortcutRule],
        desktopPath: String? = nil
    ) -> [ShortcutRule] {
        let desktop = desktopPath ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first?.path ?? "~/Desktop"
        return appendingUnoccupied(
            version10Rules(desktop: desktop) + version7Rules(),
            to: existingRules
        )
    }

    public static func migrate(
        _ existingRules: [ShortcutRule],
        fromVersion: Int,
        desktopPath: String? = nil
    ) -> [ShortcutRule] {
        guard fromVersion < currentMigrationVersion else { return existingRules }

        let desktop = desktopPath ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first?.path ?? "~/Desktop"
        var migratedRules = existingRules

        if fromVersion < 1 {
            migratedRules = appendingUnoccupied(version1Rules(desktop: desktop), to: migratedRules)
        }
        if fromVersion < 3 {
            migratedRules = removingUnmodifiedDefaults(legacyVersion2Rules(), from: migratedRules)
            migratedRules = appendingUnoccupied(version3Rules(), to: migratedRules)
        }
        if fromVersion < 5 {
            migratedRules = removingUnmodifiedDefaults(legacyVersion4Rules(), from: migratedRules)
            migratedRules = appendingUnoccupied(version5Rules(), to: migratedRules)
        }
        if fromVersion < 6 {
            migratedRules = removingUnmodifiedDefaults(version5Rules(), from: migratedRules)
            migratedRules = appendingUnoccupied(version6Rules(), to: migratedRules)
        }
        if fromVersion < 7 {
            migratedRules = removingUnmodifiedDefaults(
                version3Rules() + version6Rules(),
                from: migratedRules
            )
            migratedRules = appendingUnoccupied(version7Rules(), to: migratedRules)
        }
        if fromVersion < 8 {
            migratedRules = removingUnmodifiedDefaults(
                originalRules(desktop: desktop) + version1Rules(desktop: desktop),
                from: migratedRules
            )
            migratedRules = appendingUnoccupied(version8Rules(desktop: desktop), to: migratedRules)
        }
        if fromVersion < 9 {
            migratedRules = removingUnmodifiedDefaults(
                [version8ShowDesktopRule()],
                from: migratedRules
            )
        }
        if fromVersion < 10 {
            migratedRules = appendingUnoccupied(
                [version10ShowDesktopRule()],
                to: migratedRules
            )
        }
        return migratedRules
    }

    private static func version10Rules(desktop: String) -> [ShortcutRule] {
        version9Rules(desktop: desktop) + [version10ShowDesktopRule()]
    }

    private static func version10ShowDesktopRule() -> ShortcutRule {
        ShortcutRule(
            name: "系统显示桌面",
            source: KeyCombination(keyCode: 2, modifiers: [.command, .shift]),
            action: .showDesktop
        )
    }

    private static func version9Rules(desktop: String) -> [ShortcutRule] {
        removingUnmodifiedDefaults(
            [version8ShowDesktopRule()],
            from: version8Rules(desktop: desktop)
        )
    }

    private static func version8Rules(desktop: String) -> [ShortcutRule] {
        let codeFolder = URL(fileURLWithPath: desktop, isDirectory: true)
            .appendingPathComponent("code", isDirectory: true)
            .path
        let systemModifiers = ShortcutModifiers.option
        let physicalModifiers = PhysicalModifierKeys.capsLock

        return [
            ShortcutRule(
                name: "打开 Finder 桌面",
                source: KeyCombination(keyCode: 18, modifiers: systemModifiers, physicalModifiers: physicalModifiers),
                action: .finderFolder(path: desktop)
            ),
            ShortcutRule(
                name: "打开桌面 code 文件夹",
                source: KeyCombination(keyCode: 19, modifiers: systemModifiers, physicalModifiers: physicalModifiers),
                action: .finderFolder(path: codeFolder)
            ),
            ShortcutRule(
                name: "在当前路径打开终端",
                source: KeyCombination(keyCode: 17, modifiers: systemModifiers, physicalModifiers: physicalModifiers),
                action: .terminal(fallbackPath: desktop, useFrontmostFinder: true)
            ),
            version8ShowDesktopRule(),
            ShortcutRule(
                name: "窗口左半屏",
                source: KeyCombination(keyCode: 123, modifiers: systemModifiers, physicalModifiers: physicalModifiers),
                action: .windowLayout(.leftHalf)
            ),
            ShortcutRule(
                name: "窗口右半屏",
                source: KeyCombination(keyCode: 124, modifiers: systemModifiers, physicalModifiers: physicalModifiers),
                action: .windowLayout(.rightHalf)
            ),
            ShortcutRule(
                name: "窗口下半屏",
                source: KeyCombination(keyCode: 125, modifiers: systemModifiers, physicalModifiers: physicalModifiers),
                action: .windowLayout(.bottomHalf)
            ),
            ShortcutRule(
                name: "窗口上半屏",
                source: KeyCombination(keyCode: 126, modifiers: systemModifiers, physicalModifiers: physicalModifiers),
                action: .windowLayout(.topHalf)
            )
        ]
    }

    private static func version8ShowDesktopRule() -> ShortcutRule {
        ShortcutRule(
            name: "显示桌面",
            source: KeyCombination(keyCode: 2, modifiers: [.option], physicalModifiers: [.capsLock]),
            action: .showDesktop
        )
    }

    private static func originalRules(desktop: String) -> [ShortcutRule] {
        [
            ShortcutRule(
                name: "打开 Chrome",
                source: KeyCombination(keyCode: 14, modifiers: [.option]),
                action: .application(
                    target: ApplicationTarget(
                        displayName: "Google Chrome",
                        bundleIdentifier: "com.google.Chrome",
                        applicationPath: "/Applications/Google Chrome.app"
                    ),
                    mode: .activateExisting
                )
            ),
            ShortcutRule(
                name: "打开 Finder 桌面",
                source: KeyCombination(keyCode: 18, modifiers: [.option]),
                action: .finderFolder(path: desktop)
            ),
            ShortcutRule(
                name: "在当前路径打开终端",
                source: KeyCombination(keyCode: 17, modifiers: [.option]),
                action: .terminal(fallbackPath: desktop, useFrontmostFinder: true)
            )
        ]
    }

    private static func version1Rules(desktop: String) -> [ShortcutRule] {
        let codeFolder = URL(fileURLWithPath: desktop, isDirectory: true)
            .appendingPathComponent("code", isDirectory: true)
            .path

        return [
            ShortcutRule(
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
            ),
            ShortcutRule(
                name: "打开 Mail",
                source: KeyCombination(keyCode: 46, modifiers: [.option]),
                action: .application(
                    target: ApplicationTarget(
                        displayName: "Mail",
                        bundleIdentifier: "com.apple.mail",
                        applicationPath: "/System/Applications/Mail.app"
                    ),
                    mode: .activateExisting
                )
            ),
            ShortcutRule(
                name: "打开微信",
                source: KeyCombination(keyCode: 13, modifiers: [.option]),
                action: .application(
                    target: ApplicationTarget(
                        displayName: "微信",
                        bundleIdentifier: "com.tencent.xinWeChat",
                        applicationPath: "/Applications/WeChat.app"
                    ),
                    mode: .activateExisting
                )
            ),
            ShortcutRule(
                name: "打开桌面 code 文件夹",
                source: KeyCombination(keyCode: 19, modifiers: [.option]),
                action: .finderFolder(path: codeFolder)
            ),
            ShortcutRule(
                name: "显示桌面",
                source: KeyCombination(keyCode: 2, modifiers: [.option]),
                action: .showDesktop
            )
        ]
    }

    private static func version3Rules() -> [ShortcutRule] {
        let physicalChord: PhysicalModifierKeys = [.capsLock, .leftCommand]

        return [
            ShortcutRule(
                name: "Vim 向左",
                source: KeyCombination(
                    keyCode: 4,
                    modifiers: [.command],
                    physicalModifiers: physicalChord
                ),
                action: .remap(to: KeyCombination(keyCode: 123, modifiers: []))
            ),
            ShortcutRule(
                name: "Vim 向下",
                source: KeyCombination(
                    keyCode: 38,
                    modifiers: [.command],
                    physicalModifiers: physicalChord
                ),
                action: .remap(to: KeyCombination(keyCode: 125, modifiers: []))
            ),
            ShortcutRule(
                name: "Vim 向上",
                source: KeyCombination(
                    keyCode: 40,
                    modifiers: [.command],
                    physicalModifiers: physicalChord
                ),
                action: .remap(to: KeyCombination(keyCode: 126, modifiers: []))
            ),
            ShortcutRule(
                name: "Vim 向右",
                source: KeyCombination(
                    keyCode: 37,
                    modifiers: [.command],
                    physicalModifiers: physicalChord
                ),
                action: .remap(to: KeyCombination(keyCode: 124, modifiers: []))
            )
        ]
    }

    private static func version5Rules() -> [ShortcutRule] {
        let physicalChord: PhysicalModifierKeys = [.capsLock, .leftCommand]

        return [
            ShortcutRule(
                name: "向左跳一个单词",
                source: KeyCombination(keyCode: 16, modifiers: [.command], physicalModifiers: physicalChord),
                action: .remap(to: KeyCombination(keyCode: 123, modifiers: [.option]))
            ),
            ShortcutRule(
                name: "到当前行开头",
                source: KeyCombination(keyCode: 32, modifiers: [.command], physicalModifiers: physicalChord),
                action: .remap(to: KeyCombination(keyCode: 123, modifiers: [.command]))
            ),
            ShortcutRule(
                name: "到当前行结尾",
                source: KeyCombination(keyCode: 34, modifiers: [.command], physicalModifiers: physicalChord),
                action: .remap(to: KeyCombination(keyCode: 124, modifiers: [.command]))
            ),
            ShortcutRule(
                name: "向右跳一个单词",
                source: KeyCombination(keyCode: 31, modifiers: [.command], physicalModifiers: physicalChord),
                action: .remap(to: KeyCombination(keyCode: 124, modifiers: [.option]))
            ),
            ShortcutRule(
                name: "到当前段落开头",
                source: KeyCombination(keyCode: 45, modifiers: [.command], physicalModifiers: physicalChord),
                action: .remap(to: KeyCombination(keyCode: 126, modifiers: [.option]))
            ),
            ShortcutRule(
                name: "到文档最前面",
                source: KeyCombination(keyCode: 46, modifiers: [.command], physicalModifiers: physicalChord),
                action: .remap(to: KeyCombination(keyCode: 126, modifiers: [.command]))
            ),
            ShortcutRule(
                name: "到文档最后面",
                source: KeyCombination(keyCode: 43, modifiers: [.command], physicalModifiers: physicalChord),
                action: .remap(to: KeyCombination(keyCode: 125, modifiers: [.command]))
            ),
            ShortcutRule(
                name: "到当前段落结尾",
                source: KeyCombination(keyCode: 47, modifiers: [.command], physicalModifiers: physicalChord),
                action: .remap(to: KeyCombination(keyCode: 125, modifiers: [.option]))
            )
        ]
    }

    private static func version6Rules() -> [ShortcutRule] {
        let physicalChord: PhysicalModifierKeys = [.capsLock, .leftCommand]

        return [
            ShortcutRule(
                name: "向左跳一个单词",
                source: KeyCombination(keyCode: 16, modifiers: [.command], physicalModifiers: physicalChord),
                action: .remap(to: KeyCombination(keyCode: 123, modifiers: [.option]))
            ),
            ShortcutRule(
                name: "到当前行结尾",
                source: KeyCombination(keyCode: 32, modifiers: [.command], physicalModifiers: physicalChord),
                action: .remap(to: KeyCombination(keyCode: 124, modifiers: [.command]))
            ),
            ShortcutRule(
                name: "到当前行开头",
                source: KeyCombination(keyCode: 34, modifiers: [.command], physicalModifiers: physicalChord),
                action: .remap(to: KeyCombination(keyCode: 123, modifiers: [.command]))
            ),
            ShortcutRule(
                name: "向右跳一个单词",
                source: KeyCombination(keyCode: 31, modifiers: [.command], physicalModifiers: physicalChord),
                action: .remap(to: KeyCombination(keyCode: 124, modifiers: [.option]))
            ),
            ShortcutRule(
                name: "到当前段落开头",
                source: KeyCombination(keyCode: 45, modifiers: [.command], physicalModifiers: physicalChord),
                action: .remap(to: KeyCombination(keyCode: 126, modifiers: [.option]))
            ),
            ShortcutRule(
                name: "到文档最后面",
                source: KeyCombination(keyCode: 46, modifiers: [.command], physicalModifiers: physicalChord),
                action: .remap(to: KeyCombination(keyCode: 125, modifiers: [.command]))
            ),
            ShortcutRule(
                name: "到文档最前面",
                source: KeyCombination(keyCode: 43, modifiers: [.command], physicalModifiers: physicalChord),
                action: .remap(to: KeyCombination(keyCode: 126, modifiers: [.command]))
            ),
            ShortcutRule(
                name: "到当前段落结尾",
                source: KeyCombination(keyCode: 47, modifiers: [.command], physicalModifiers: physicalChord),
                action: .remap(to: KeyCombination(keyCode: 125, modifiers: [.option]))
            )
        ]
    }

    private static func version7Rules() -> [ShortcutRule] {
        (version3Rules() + version6Rules()).map { legacyRule in
            var rule = legacyRule
            rule.source = KeyCombination(
                keyCode: legacyRule.source.keyCode,
                modifiers: legacyRule.source.modifiers,
                physicalModifiers: [.capsLock]
            )
            return rule
        }
    }

    private static func legacyVersion4Rules() -> [ShortcutRule] {
        let physicalChord: PhysicalModifierKeys = [.capsLock, .leftCommand]

        return [
            ShortcutRule(
                name: "向左跳一个单词",
                source: KeyCombination(keyCode: 16, modifiers: [.command], physicalModifiers: physicalChord),
                action: .remap(to: KeyCombination(keyCode: 123, modifiers: [.option]))
            ),
            ShortcutRule(
                name: "到当前段落结尾",
                source: KeyCombination(keyCode: 32, modifiers: [.command], physicalModifiers: physicalChord),
                action: .remap(to: KeyCombination(keyCode: 125, modifiers: [.option]))
            ),
            ShortcutRule(
                name: "到当前段落开头",
                source: KeyCombination(keyCode: 34, modifiers: [.command], physicalModifiers: physicalChord),
                action: .remap(to: KeyCombination(keyCode: 126, modifiers: [.option]))
            ),
            ShortcutRule(
                name: "向右跳一个单词",
                source: KeyCombination(keyCode: 31, modifiers: [.command], physicalModifiers: physicalChord),
                action: .remap(to: KeyCombination(keyCode: 124, modifiers: [.option]))
            ),
            ShortcutRule(
                name: "到当前行开头",
                source: KeyCombination(keyCode: 45, modifiers: [.command], physicalModifiers: physicalChord),
                action: .remap(to: KeyCombination(keyCode: 123, modifiers: [.command]))
            ),
            ShortcutRule(
                name: "到文档最后面",
                source: KeyCombination(keyCode: 46, modifiers: [.command], physicalModifiers: physicalChord),
                action: .remap(to: KeyCombination(keyCode: 125, modifiers: [.command]))
            ),
            ShortcutRule(
                name: "到文档最前面",
                source: KeyCombination(keyCode: 43, modifiers: [.command], physicalModifiers: physicalChord),
                action: .remap(to: KeyCombination(keyCode: 126, modifiers: [.command]))
            ),
            ShortcutRule(
                name: "到当前行结尾",
                source: KeyCombination(keyCode: 47, modifiers: [.command], physicalModifiers: physicalChord),
                action: .remap(to: KeyCombination(keyCode: 124, modifiers: [.command]))
            )
        ]
    }

    private static func legacyVersion2Rules() -> [ShortcutRule] {
        [
            ShortcutRule(
                name: "Vim 向左",
                source: KeyCombination(keyCode: 4, modifiers: [.option, .command]),
                action: .remap(to: KeyCombination(keyCode: 123, modifiers: []))
            ),
            ShortcutRule(
                name: "Vim 向下",
                source: KeyCombination(keyCode: 38, modifiers: [.option, .command]),
                action: .remap(to: KeyCombination(keyCode: 125, modifiers: []))
            ),
            ShortcutRule(
                name: "Vim 向上",
                source: KeyCombination(keyCode: 40, modifiers: [.option, .command]),
                action: .remap(to: KeyCombination(keyCode: 126, modifiers: []))
            ),
            ShortcutRule(
                name: "Vim 向右",
                source: KeyCombination(keyCode: 37, modifiers: [.option, .command]),
                action: .remap(to: KeyCombination(keyCode: 124, modifiers: []))
            )
        ]
    }

    private static func removingUnmodifiedDefaults(
        _ defaults: [ShortcutRule],
        from existingRules: [ShortcutRule]
    ) -> [ShortcutRule] {
        existingRules.filter { existing in
            !defaults.contains { defaultRule in
                existing.name == defaultRule.name
                    && existing.source == defaultRule.source
                    && existing.action == defaultRule.action
                    && existing.isEnabled == defaultRule.isEnabled
            }
        }
    }

    private static func appendingUnoccupied(
        _ additions: [ShortcutRule],
        to existingRules: [ShortcutRule]
    ) -> [ShortcutRule] {
        var occupiedShortcuts = Set(existingRules.map(\.source))
        var mergedRules = existingRules

        for rule in additions where !occupiedShortcuts.contains(rule.source) {
            mergedRules.append(rule)
            occupiedShortcuts.insert(rule.source)
        }
        return mergedRules
    }
}
