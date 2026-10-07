// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CAetherCore

public struct ShortcutRuleEdit: Sendable {
    public let index: Int?
    public let selection: Int?
    public let requiresConflictScan: Bool
    fileprivate init(_ value: AetherRuleEdit) {
        index = value.index < 0 ? nil : value.index
        selection = value.selection < 0 ? nil : value.selection
        requiresConflictScan = value.rescan != 0
    }
}

/// Rust owns immutable metadata and the first position for each UUID. No native records are retained.
public final class ShortcutRuleIndex: @unchecked Sendable {
    private let handle: UnsafeMutableRawPointer
    public init(_ rules: [ShortcutRule]) {
        let rows = rules.map(\.editMetadata)
        let pointer = rows.withUnsafeBufferPointer { aether_rule_index_create($0.baseAddress, $0.count) }
        guard let pointer else { preconditionFailure("Invalid shortcut index input") }
        handle = pointer
    }
    deinit { aether_rule_index_destroy(handle) }
    public func position(of id: UUID) -> Int? {
        let position = aether_rule_index_find(handle, .init(bytes: id.uuid))
        return position < 0 ? nil : position
    }
    public func updating(_ rule: ShortcutRule) -> ShortcutRuleEdit {
        .init(aether_rule_index_edit(handle, rule.editMetadata, 0))
    }
    public func removing(_ id: UUID) -> ShortcutRuleEdit {
        .init(aether_rule_index_edit(handle, .init(id: .init(bytes: id.uuid), source: .init(), enabled: 0), 1))
    }
    public static func newRule(desktopPath: String) -> ShortcutRule {
        let template = aether_rule_new_template()
        precondition(template.kind == 1)
        return .init(name: "新快捷键", source: .init(keyCode: template.source.code,
            modifiers: .init(rawValue: template.source.modifiers), physicalModifiers: .init(rawValue: template.source.physical)),
            action: .finderFolder(path: desktopPath), isEnabled: template.enabled != 0)
    }
    public static func moving(_ rules: [ShortcutRule], offsets: IndexSet, destination: Int) -> [ShortcutRule]? {
        let offsets = offsets.map(Int64.init)
        var order = [Int](repeating: 0, count: rules.count)
        let valid = offsets.withUnsafeBufferPointer { offsets in
            order.withUnsafeMutableBufferPointer {
                aether_rule_move(rules.count, offsets.baseAddress, offsets.count, Int64(destination), $0.baseAddress, $0.count)
            }
        }
        guard valid != 0 else { return nil }
        return order.map { rules[$0] }
    }
}

private extension ShortcutRule {
    var editMetadata: AetherRuleMeta { .init(id: .init(bytes: id.uuid), source: source.rustKey, enabled: isEnabled ? 1 : 0) }
}
