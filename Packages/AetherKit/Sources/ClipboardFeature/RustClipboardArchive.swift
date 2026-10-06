// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CAetherCore
import RustCore

func clipboardArchiveText(_ bytes: AetherBytes) -> String {
    guard bytes.length != 0, let data = bytes.data else { return "" }
    return String(decoding: UnsafeBufferPointer(start: data, count: bytes.length), as: UTF8.self)
}

/// Rust owns archive parsing/records/write protection; native values are copied before views expire.
final class RustClipboardArchive: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private let core: UnsafeMutableRawPointer?
    init(fileURL: URL) { core = fileURL.withUnsafeFileSystemRepresentation { aether_clipboard_archive_create($0) } }
    deinit { aether_clipboard_archive_destroy(core) }

    func load() throws -> ClipboardArchive? {
        lock.lock(); defer { lock.unlock() }
        let decoded = aether_clipboard_archive_load_decoded(core)
        defer { aether_clipboard_archive_decoded_destroy(decoded) }
        let status = aether_clipboard_archive_decoded_status(decoded)
        if status == 1 { return nil }
        guard status == 0 else { throw RustDiskError(status: status) }
        func items(section: UInt8, group: Int = 0) throws -> [ClipboardItem] {
            try (0..<aether_clipboard_archive_decoded_count(decoded, section, group)).map { index in
                let record = aether_clipboard_archive_decoded_item(decoded, section, group, index)
                let urls = record.present & 64 != 0 ? (0..<record.file_count).map {
                    clipboardArchiveText(aether_clipboard_archive_decoded_url(decoded, section, group, index, $0))
                } : nil
                return try ClipboardItem(archiveRecord: record, fileURLs: urls)
            }
        }
        do {
            let history = try items(section: 0), pinned = try items(section: 1)
            let groups: [ClipboardGroup]? = aether_clipboard_archive_decoded_has_groups(decoded) != 0
                ? try (0..<aether_clipboard_archive_decoded_count(decoded, 3, 0)).map { index in
                    let record = aether_clipboard_archive_decoded_group(decoded, index)
                    guard let id = UUID(uuidString: clipboardArchiveText(record.id)) else { throw CocoaError(.fileReadCorruptFile) }
                    return ClipboardGroup(id: id, timestamp: Date(timeIntervalSinceReferenceDate: record.timestamp),
                                          items: try items(section: 2, group: index))
                } : nil
            return ClipboardArchive(history: history, pinnedItems: pinned, groups: groups)
        } catch { aether_clipboard_archive_block(core); throw error }
    }
    func save(_ archive: ClipboardArchive) throws {
        lock.lock(); defer { lock.unlock() }
        let data = try JSONEncoder().encode(archive)
        let status = data.withUnsafeBytes { aether_clipboard_archive_write(core,
            .init(data: $0.bindMemory(to: UInt8.self).baseAddress, length: $0.count)) }
        if status != 0 { throw RustDiskError(status: status) }
    }
}
