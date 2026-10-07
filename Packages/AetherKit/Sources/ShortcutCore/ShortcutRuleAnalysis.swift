// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CAetherCore

/// Immutable rule snapshot. Rust computes validation and both execution states once;
/// native adaptation retains UUID semantics and shares the original Array storage.
public final class ShortcutRuleAnalysis: Sendable {
    public let issues: [ShortcutRuleIssue]
    private let rules: [ShortcutRule]
    private let flags: [UInt8]

    public init(rules: [ShortcutRule]) {
        self.rules = rules
        let core = rules.map(\.rustRule)
        let ids = rules.map { AetherUUID(bytes: $0.id.uuid) }
        var flags = [UInt8](repeating: 0, count: rules.count)
        let result = core.withUnsafeBufferPointer { aether_shortcut_validate($0.baseAddress, $0.count) }
        defer { aether_validation_destroy(result) }
        issues = ShortcutRuleValidator.decode(result, rules: rules)
        let accepted = core.withUnsafeBufferPointer { core in
            ids.withUnsafeBufferPointer { ids in
                flags.withUnsafeMutableBufferPointer {
                    aether_shortcut_execution_flags(result, core.baseAddress, ids.baseAddress, rules.count, $0.baseAddress, $0.count)
                }
            }
        }
        precondition(accepted != 0, "Invalid shortcut rule analysis")
        self.flags = flags
    }

    public func executableRuleIDs(inputMonitoringGranted: Bool) -> Set<UUID> {
        let mask = executionMask(inputMonitoringGranted, permission: true, recording: false)
        return Set(rules.indices.lazy.filter { self.flags[$0] & mask != 0 }.map { self.rules[$0].id })
    }

    public func executableRules(permissionGranted: Bool, inputMonitoringGranted: Bool, isRecording: Bool) -> [ShortcutRule] {
        let mask = executionMask(inputMonitoringGranted, permission: permissionGranted, recording: isRecording)
        guard mask != 0 else { return [] }
        if flags.allSatisfy({ $0 & mask != 0 }) { return rules }
        return rules.indices.compactMap { flags[$0] & mask != 0 ? rules[$0] : nil }
    }

    private func executionMask(_ monitoring: Bool, permission: Bool, recording: Bool) -> UInt8 {
        aether_shortcut_execution_mask(monitoring ? 1 : 0, permission ? 1 : 0, recording ? 1 : 0)
    }
}
