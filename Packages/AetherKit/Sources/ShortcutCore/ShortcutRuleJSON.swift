// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CAetherCore
import RustCore

/// Native DTO adaptation only. Rust defines the persisted action and rule representation.
enum ShortcutRuleJSON {
    static func decode(_ data: Data) throws -> [ShortcutRule] {
        if let rules = decodeCore(data) { return rules }
        // Preserve Foundation's legacy encodings and exact DecodingError categories on exceptional inputs.
        return try JSONDecoder().decode([ShortcutRule].self, from: data)
    }

    static func decodeCore(_ data: Data) -> [ShortcutRule]? {
        let handle = data.withUnsafeBytes {
            aether_rule_decode(.init(data: $0.bindMemory(to: UInt8.self).baseAddress, length: $0.count))
        }
        defer { aether_rule_decoded_destroy(handle) }
        let view = aether_rule_decoded_view(handle)
        guard view.status == 0 else { return nil }
        return assemble(view)
    }

    static func assemble(_ view: AetherDecodedRules) -> [ShortcutRule] {
        let arena = UnsafeBufferPointer(start: view.bytes.data, count: view.bytes.length)
        func text(_ span: AetherRuleText) -> String {
            String(decoding: arena[span.start..<(span.start + span.length)], as: UTF8.self)
        }
        func key(_ value: AetherKey) -> KeyCombination {
            .init(keyCode: value.code, modifiers: .init(rawValue: value.modifiers),
                physicalModifiers: .init(rawValue: value.physical))
        }
        return UnsafeBufferPointer(start: view.rows, count: view.count).map { row in
            let action: ShortcutAction
            switch row.kind {
            case 0:
                action = .application(target: .init(displayName: text(row.display_name),
                    bundleIdentifier: row.bundle_present == 0 ? nil : text(row.bundle), applicationPath: text(row.path)),
                    mode: row.mode == 0 ? .activateExisting : .newWindow)
            case 1: action = .finderFolder(path: text(row.path))
            case 2: action = .terminal(fallbackPath: text(row.path), useFrontmostFinder: row.use_finder != 0)
            case 3: action = .showDesktop
            case 4: action = .windowLayout(WindowLayout.allCases[Int(row.layout)])
            case 5: action = .remap(to: key(row.target))
            default: preconditionFailure("Invalid decoded shortcut action")
            }
            return .init(id: UUID(uuid: row.id.bytes), name: text(row.name), source: key(row.source),
                action: action, isEnabled: row.enabled != 0)
        }
    }

    static func encode(_ rules: [ShortcutRule]) throws -> Data {
        try withRecords(rules) { rows, bytes in
            try RustBuffer.take(aether_rule_encode(rows.baseAddress, rows.count,
                .init(data: bytes.baseAddress, length: bytes.count)))
        }
    }

    static func withRecords<T>(_ rules: [ShortcutRule], body: (UnsafeBufferPointer<AetherRuleRecord>, UnsafeBufferPointer<UInt8>) throws -> T) rethrows -> T {
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
                switch mode {
                case .activateExisting: row.mode = 0
                case .newWindow: row.mode = 1
                }
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
                try body(rows, bytes)
            }
        }
    }
}
