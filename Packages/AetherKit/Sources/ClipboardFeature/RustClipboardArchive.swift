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
        let wire = ClipboardArchiveWire(archive)
        let status = wire.withViews { rows, urls, groups, bytes in
            aether_clipboard_archive_write_spans(core, rows.baseAddress, rows.count,
                archive.history.count, archive.pinnedItems.count, urls.baseAddress, urls.count,
                groups.baseAddress, groups.count, archive.groups == nil ? 0 : 1, bytes)
        }
        if status != 0 { throw RustDiskError(status: status) }
    }
}

/// Direct compact records and one UTF-8 arena; no per-item field arrays or second record array.
struct ClipboardArchiveWire {
    var arena: [UInt8] = []
    var rows: [AetherClipboardArchiveSpanItem] = []
    var urls: [AetherRuleText] = []
    var groups: [AetherClipboardArchiveSpanGroup] = []

    init(_ archive: ClipboardArchive) {
        rows.reserveCapacity(archive.history.count + archive.pinnedItems.count + (archive.groups ?? []).reduce(0) { $0 + $1.items.count })
        groups.reserveCapacity(archive.groups?.count ?? 0)
        for item in archive.history { append(item) }
        for item in archive.pinnedItems { append(item) }
        for group in archive.groups ?? [] {
            let id = append(group.id.uuidString)
            let start = rows.count
            for item in group.items { append(item) }
            groups.append(.init(id: id, timestamp: group.timestamp.timeIntervalSinceReferenceDate, start: start, count: rows.count - start))
        }
    }
    private mutating func append(_ text: String) -> AetherRuleText {
        let start = arena.count
        arena.append(contentsOf: text.utf8)
        return .init(start: start, length: arena.count - start)
    }
    private mutating func append(_ text: String?, bit: UInt16, present: inout UInt16) -> AetherRuleText {
        guard let text else { return .init() }
        present |= bit
        return append(text)
    }
    private mutating func append(_ item: ClipboardItem) {
        var row = AetherClipboardArchiveSpanItem()
        row.present = 7
        row.id = append(item.id.uuidString)
        row.preview = append(item.preview)
        row.string_data = append(item.stringData, bit: 8, present: &row.present)
        row.image_file_name = append(item.imageFileName, bit: 16, present: &row.present)
        row.image_content_hash = append(item.imageContentHash, bit: 32, present: &row.present)
        row.rtf_data = append(item.rtfData?.base64EncodedString(), bit: 128, present: &row.present)
        row.rtf_file_name = append(item.rtfFileName, bit: 256, present: &row.present)
        row.timestamp = item.timestamp.timeIntervalSinceReferenceDate
        row.url_start = urls.count
        if let files = item.fileURLs {
            row.present |= 64
            for file in files { urls.append(append(file)) }
        }
        row.file_count = urls.count - row.url_start
        row.kind = item.type.rustKind
        row.pinned = item.isPinned ? 1 : 0
        rows.append(row)
    }
    func withViews<T>(_ body: (UnsafeBufferPointer<AetherClipboardArchiveSpanItem>, UnsafeBufferPointer<AetherRuleText>, UnsafeBufferPointer<AetherClipboardArchiveSpanGroup>, AetherBytes) -> T) -> T {
        arena.withUnsafeBufferPointer { bytes in
            rows.withUnsafeBufferPointer { rows in
                urls.withUnsafeBufferPointer { urls in
                    groups.withUnsafeBufferPointer { groups in
                        body(rows, urls, groups, .init(data: bytes.baseAddress, length: bytes.count))
                    }
                }
            }
        }
    }
}
