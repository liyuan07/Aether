// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CAetherCore
import RustCore

/// Rust owns archive framing and rule format. Foundation retains preference dictionary semantics.
public enum ShortcutConfigurationJSON {
    public static func encode(_ archive: KeyPilotConfigurationArchive) throws -> Data {
        let preferences: Data
        do { preferences = try PreferenceJSON.encode(archive.preferences) }
        catch {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            return try encoder.encode(archive) // Preserve complete EncodingError coding paths.
        }

        return try ShortcutRuleJSON.withRecords(archive.shortcuts) { rows, bytes in
            try preferences.withUnsafeBytes { preferences in
                try RustBuffer.take(aether_shortcut_archive_encode(rows.baseAddress, rows.count,
                    .init(data: bytes.baseAddress, length: bytes.count),
                    .init(data: preferences.bindMemory(to: UInt8.self).baseAddress, length: preferences.count)))
            }
        }
    }

    public static func decode(_ data: Data) throws -> KeyPilotConfigurationArchive {
        if let archive = decodeCore(data) { return archive }
        // Preserve old text encodings and the complete archive's error path and wording.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(KeyPilotConfigurationArchive.self, from: data)
    }

    static func decodeCore(_ data: Data) -> KeyPilotConfigurationArchive? {
        let handle = data.withUnsafeBytes {
            aether_shortcut_archive_decode(.init(data: $0.bindMemory(to: UInt8.self).baseAddress, length: $0.count))
        }
        defer { aether_shortcut_archive_destroy(handle) }
        let view = aether_shortcut_archive_view(handle)
        guard view.status == 0, view.rules.status == 0, let bytes = view.preferences.data else { return nil }
        // Foundation may retain input storage in decoded values; give it an independently owned buffer.
        let preferencesData = Data(bytes: bytes, count: view.preferences.length)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let preferences = try? decoder.decode(AppPreferencesConfiguration.self, from: preferencesData) else { return nil }
        var archive = KeyPilotConfigurationArchive(shortcuts: ShortcutRuleJSON.assemble(view.rules), preferences: preferences)
        archive.schemaVersion = Int(view.version)
        return archive
    }

    public static func isSupported(_ archive: KeyPilotConfigurationArchive) -> Bool {
        aether_shortcut_archive_supported(Int64(archive.schemaVersion), Int64(archive.preferences.schemaVersion)) != 0
    }
}
