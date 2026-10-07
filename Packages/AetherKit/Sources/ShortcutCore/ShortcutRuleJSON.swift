// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CAetherCore
import RustCore

/// Native DTO adaptation only. Rust defines the persisted action and rule representation.
enum ShortcutRuleJSON {
    static func encode(_ rules: [ShortcutRule]) throws -> Data {
        var bytes = [UInt8]()
        func text(_ value: String) -> AetherRuleText {
            let start = bytes.count
            bytes.append(contentsOf: value.utf8)
            return .init(start: start, length: bytes.count - start)
        }
        let rows: [AetherRuleRecord] = rules.map { rule in
            var row = AetherRuleRecord()
            row.id = .init(bytes: rule.id.uuid)
            row.source = rule.source.rustKey
            row.name = text(rule.name)
            row.enabled = rule.isEnabled ? 1 : 0
            switch rule.action {
            case let .application(target, mode):
                row.kind = 0
                row.display_name = text(target.displayName)
                row.path = text(target.applicationPath)
                if let bundle = target.bundleIdentifier {
                    row.bundle_present = 1
                    row.bundle = text(bundle)
                }
                row.mode = mode == .activateExisting ? 0 : 1
            case let .finderFolder(path):
                row.kind = 1
                row.path = text(path)
            case let .terminal(path, useFinder):
                row.kind = 2
                row.path = text(path)
                row.use_finder = useFinder ? 1 : 0
            case .showDesktop:
                row.kind = 3
            case let .windowLayout(layout):
                row.kind = 4
                switch layout {
                case .leftHalf: row.layout = 0
                case .rightHalf: row.layout = 1
                case .topHalf: row.layout = 2
                case .bottomHalf: row.layout = 3
                case .topLeft: row.layout = 4
                case .topRight: row.layout = 5
                case .bottomLeft: row.layout = 6
                case .bottomRight: row.layout = 7
                }
            case let .remap(target):
                row.kind = 5
                row.target = target.rustKey
            }
            return row
        }
        return try rows.withUnsafeBufferPointer { rows in
            try bytes.withUnsafeBufferPointer { bytes in
                try RustBuffer.take(aether_rule_encode(rows.baseAddress, rows.count,
                    .init(data: bytes.baseAddress, length: bytes.count)))
            }
        }
    }
}
