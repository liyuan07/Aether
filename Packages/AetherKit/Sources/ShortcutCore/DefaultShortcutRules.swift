// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CAetherCore

public enum DefaultShortcutRules {
    public static let currentMigrationVersion = Int(aether_shortcut_default_version())

    public static func make(desktopPath: String? = nil) -> [ShortcutRule] {
        plan([], mode: 0, version: 0, desktopPath: desktopPath)
    }

    public static func mergingAdditions(into existingRules: [ShortcutRule], desktopPath: String? = nil) -> [ShortcutRule] {
        plan(existingRules, mode: 1, version: 0, desktopPath: desktopPath)
    }

    public static func migrate(_ existingRules: [ShortcutRule], fromVersion: Int, desktopPath: String? = nil) -> [ShortcutRule] {
        guard fromVersion < currentMigrationVersion else { return existingRules }
        return plan(existingRules, mode: 2, version: fromVersion, desktopPath: desktopPath)
    }

    private static func plan(_ rules: [ShortcutRule], mode: UInt8, version: Int, desktopPath: String?) -> [ShortcutRule] {
        let desktop = desktopPath ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first?.path ?? "~/Desktop"
        let context = NativeDefaultRules(rules: rules, desktop: desktop)
        let matches: @convention(c) (UnsafeMutableRawPointer?, Int, UInt8, Int) -> UInt8 = { pointer, index, recipe, target in
            let context = Unmanaged<NativeDefaultRules>.fromOpaque(pointer!).takeUnretainedValue()
            let existing = recipe == 0 ? context.rules[index] : context.rule(index)
            let expected = context.rule(target)
            return existing.name == expected.name && existing.source == expected.source
                && existing.action == expected.action && existing.isEnabled == expected.isEnabled ? 1 : 0
        }
        let keys = rules.map { $0.source.rustKey }
        return withExtendedLifetime(context) {
            let handle = keys.withUnsafeBufferPointer {
                aether_shortcut_defaults_plan($0.baseAddress, $0.count, mode, Int64(version), matches,
                    Unmanaged.passUnretained(context).toOpaque())
            }
            guard let handle else { preconditionFailure("Invalid default shortcut migration plan") }
            defer { aether_shortcut_defaults_destroy(handle) }
            if aether_shortcut_defaults_identity(handle) != 0 { return rules }
            return (0..<aether_shortcut_defaults_count(handle)).map {
                let reference = aether_shortcut_defaults_ref(handle, $0)
                return reference.recipe == 0 ? rules[reference.index] : context.rule(reference.index)
            }
        }
    }
}

/// Native adaptation only: Foundation paths, UUID creation and native field equality.
/// Recipes are materialized lazily for this one call; no UUIDs or user rules are globally cached.
private final class NativeDefaultRules {
    let rules: [ShortcutRule]
    let desktop: String
    private var cache: [Int: ShortcutRule] = [:]
    private lazy var codeFolder = URL(fileURLWithPath: desktop, isDirectory: true)
        .appendingPathComponent("code", isDirectory: true).path

    init(rules: [ShortcutRule], desktop: String) { self.rules = rules; self.desktop = desktop }

    func rule(_ index: Int) -> ShortcutRule {
        if let cached = cache[index] { return cached }
        let view = aether_shortcut_default_recipe(index)
        precondition(view.valid != 0)
        let action: ShortcutAction
        switch view.kind {
        case 0:
            action = .application(target: .init(displayName: text(view.display), bundleIdentifier: text(view.bundle),
                applicationPath: text(view.path)), mode: .activateExisting)
        case 1: action = .finderFolder(path: view.argument == 0 ? desktop : codeFolder)
        case 2: action = .terminal(fallbackPath: desktop, useFrontmostFinder: true)
        case 3: action = .showDesktop
        case 4:
            let layouts: [WindowLayout] = [.leftHalf, .rightHalf, .bottomHalf, .topHalf]
            action = .windowLayout(layouts[Int(view.argument)])
        case 5: action = .remap(to: key(view.target))
        default: preconditionFailure("Invalid default shortcut action")
        }
        let result = ShortcutRule(name: text(view.name), source: key(view.source), action: action)
        cache[index] = result
        return result
    }

    private func text(_ bytes: AetherBytes) -> String {
        String(decoding: UnsafeBufferPointer(start: bytes.data, count: bytes.length), as: UTF8.self)
    }
    private func key(_ key: AetherKey) -> KeyCombination {
        .init(keyCode: key.code, modifiers: .init(rawValue: key.modifiers), physicalModifiers: .init(rawValue: key.physical))
    }
}
