// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import ShortcutCore

private let signatureID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
private func signatures(_ rules: [ShortcutRule]) -> [ShortcutRule] {
    rules.map { var rule = $0; rule.id = signatureID; return rule }
}

private func legacyCatalog(_ desktop: String) -> [[ShortcutRule]] {
    [ReferenceDefaultShortcutRules.originalRules(desktop: desktop),
     ReferenceDefaultShortcutRules.version1Rules(desktop: desktop),
     ReferenceDefaultShortcutRules.legacyVersion2Rules(), ReferenceDefaultShortcutRules.version3Rules(),
     ReferenceDefaultShortcutRules.legacyVersion4Rules(), ReferenceDefaultShortcutRules.version5Rules(),
     ReferenceDefaultShortcutRules.version6Rules(), ReferenceDefaultShortcutRules.version7Rules(),
     ReferenceDefaultShortcutRules.version8Rules(desktop: desktop),
     ReferenceDefaultShortcutRules.version9Rules(desktop: desktop),
     ReferenceDefaultShortcutRules.version10Rules(desktop: desktop)]
}

@Test("Rust 默认规则完整内容、顺序、路径与独立 Swift 参照一致")
func rustDefaultsCatalogParity() {
    #expect(DefaultShortcutRules.currentMigrationVersion == ReferenceDefaultShortcutRules.currentMigrationVersion)
    for desktop in ["/synthetic/Desktop", "/合成/桌 面", "/cafe\u{301}/Desktop", "", "relative/Desktop", "/test/../Desktop/", "~/Desktop"] {
        let actual = DefaultShortcutRules.make(desktopPath: desktop)
        #expect(signatures(actual) == signatures(ReferenceDefaultShortcutRules.make(desktopPath: desktop)))
        #expect(actual.count == 20)
        #expect(Set(actual.map(\.id)).count == actual.count)
        #expect(Set(actual.map(\.id)).isDisjoint(with: DefaultShortcutRules.make(desktopPath: desktop).map(\.id)))
    }
}

@Test("Rust 所有版本升级与合并保留自定义内容、禁用占位、原始 ID 和顺序")
func rustDefaultsMigrationParity() {
    let versions = [Int.min, -1] + Array(0...11) + [Int.max]
    for desktop in ["/synthetic/Desktop", "/合成/e\u{301}/桌 面", "relative/../Desktop", ""] {
        let catalog = legacyCatalog(desktop)
        let all = catalog.flatMap { $0 }
        var custom = all
        for index in custom.indices {
            switch index % 5 {
            case 0: custom[index].name += " 自定义"
            case 1: custom[index].isEnabled = false
            case 2: custom[index].action = .finderFolder(path: "/synthetic/自定义")
            case 3: custom[index].source.modifiers = .init(rawValue: 255)
            default: custom[index].source.physicalModifiers = .init(rawValue: 65535)
            }
        }
        let scenarios = [[], all, Array(all.reversed()), custom, Array(custom.prefix(7)) + Array(all.suffix(7))] + catalog
        for existing in scenarios {
            let merged = DefaultShortcutRules.mergingAdditions(into: existing, desktopPath: desktop)
            #expect(signatures(merged) == signatures(ReferenceDefaultShortcutRules.mergingAdditions(into: existing, desktopPath: desktop)))
            #expect(Array(merged.prefix(existing.count)) == existing)
            for version in versions {
                let actual = DefaultShortcutRules.migrate(existing, fromVersion: version, desktopPath: desktop)
                let expected = ReferenceDefaultShortcutRules.migrate(existing, fromVersion: version, desktopPath: desktop)
                #expect(signatures(actual) == signatures(expected))
                let oldIDs = Set(existing.map(\.id))
                #expect(actual.filter { oldIDs.contains($0.id) } == expected.filter { oldIDs.contains($0.id) })
            }
        }
    }
}

@Test("Rust 默认升级逐字段识别修改，原生规范等价字符串保持旧语义")
func rustDefaultsEachFieldParity() {
    let desktop = "/synthetic/café/Desktop"
    let oldRules = legacyCatalog(desktop).flatMap { $0 }
    for original in oldRules {
        var variants = [original]
        var name = original; name.name += " 编辑"; variants.append(name)
        var disabled = original; disabled.isEnabled = false; variants.append(disabled)
        var action = original; action.action = .finderFolder(path: "/synthetic/custom"); variants.append(action)
        var key = original; key.source.keyCode = 65535; variants.append(key)
        for candidate in variants {
            for version in 0...9 {
                let actual = DefaultShortcutRules.migrate([candidate, candidate], fromVersion: version,
                    desktopPath: desktop.decomposedStringWithCanonicalMapping)
                let expected = ReferenceDefaultShortcutRules.migrate([candidate, candidate], fromVersion: version,
                    desktopPath: desktop.decomposedStringWithCanonicalMapping)
                #expect(signatures(actual) == signatures(expected))
                #expect(actual.filter { $0.id == candidate.id } == expected.filter { $0.id == candidate.id })
            }
        }
    }
}

@Test("无需升级与已占满来源时复用原生数组存储")
func rustDefaultsIdentityStorage() {
    let rules = DefaultShortcutRules.make(desktopPath: "/synthetic/Desktop")
    let merged = DefaultShortcutRules.mergingAdditions(into: rules, desktopPath: "/synthetic/Desktop")
    let future = DefaultShortcutRules.migrate(rules, fromVersion: Int.max, desktopPath: "/synthetic/Desktop")
    rules.withUnsafeBufferPointer { source in
        merged.withUnsafeBufferPointer { #expect($0.baseAddress == source.baseAddress) }
        future.withUnsafeBufferPointer { #expect($0.baseAddress == source.baseAddress) }
    }
}
