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
        let status = wire.withViews { rows, urls, groups in
            aether_clipboard_archive_write_records(core, rows.baseAddress, rows.count,
                archive.history.count, archive.pinnedItems.count, urls.baseAddress, urls.count,
                groups.baseAddress, groups.count, archive.groups == nil ? 0 : 1)
        }
        if status != 0 { throw RustDiskError(status: status) }
    }
}

/// One UTF-8 arena borrows native values without an intermediate JSON document.
private struct ClipboardArchiveWire {
    struct Row {
        let fields: [Range<Int>?]
        let timestamp: Double
        let urlStart: Int, fileCount: Int
        let present: UInt16
        let kind: UInt8, pinned: UInt8
    }
    struct Group {
        let id: Range<Int>
        let timestamp: Double
        let start: Int, count: Int
    }
    var arena = Data()
    var rows: [Row] = []
    var urls: [Range<Int>] = []
    var groups: [Group] = []

    init(_ archive: ClipboardArchive) {
        rows.reserveCapacity(archive.history.count + archive.pinnedItems.count + (archive.groups ?? []).reduce(0) { $0 + $1.items.count })
        for item in archive.history { append(item) }
        for item in archive.pinnedItems { append(item) }
        for group in archive.groups ?? [] {
            let id = append(group.id.uuidString)!
            let start = rows.count
            for item in group.items { append(item) }
            groups.append(Group(id: id, timestamp: group.timestamp.timeIntervalSinceReferenceDate, start: start, count: group.items.count))
        }
    }
    mutating func append(_ text: String?) -> Range<Int>? {
        guard let text else { return nil }
        let start = arena.count
        arena.append(contentsOf: text.utf8)
        return start..<arena.count
    }
    mutating func append(_ item: ClipboardItem) {
        let fields = [append(item.id.uuidString), append(item.preview), append(item.stringData),
                      append(item.imageFileName), append(item.imageContentHash),
                      append(item.rtfData?.base64EncodedString()), append(item.rtfFileName)]
        let bits: [UInt16] = [1, 4, 8, 16, 32, 128, 256]
        var present: UInt16 = 2
        for (field, bit) in zip(fields, bits) where field != nil { present |= bit }
        let urlStart = urls.count
        if let files = item.fileURLs {
            present |= 64
            for file in files { urls.append(append(file)!) }
        }
        rows.append(Row(fields: fields, timestamp: item.timestamp.timeIntervalSinceReferenceDate,
            urlStart: urlStart, fileCount: urls.count - urlStart, present: present,
            kind: item.type.rustKind, pinned: item.isPinned ? 1 : 0))
    }
    func withViews<T>(_ body: (UnsafeBufferPointer<AetherClipboardArchiveWriteItem>, UnsafeBufferPointer<AetherBytes>, UnsafeBufferPointer<AetherClipboardArchiveWriteGroup>) -> T) -> T {
        arena.withUnsafeBytes { raw in
            let base = raw.bindMemory(to: UInt8.self).baseAddress
            func bytes(_ range: Range<Int>?) -> AetherBytes {
                guard let range else { return .init(data: nil, length: 0) }
                return .init(data: base?.advanced(by: range.lowerBound), length: range.count)
            }
            let records = rows.map { row in
                AetherClipboardArchiveWriteItem(item: .init(id: bytes(row.fields[0]), preview: bytes(row.fields[1]),
                    string_data: bytes(row.fields[2]), image_file_name: bytes(row.fields[3]), image_content_hash: bytes(row.fields[4]),
                    rtf_data: bytes(row.fields[5]), rtf_file_name: bytes(row.fields[6]), timestamp: row.timestamp,
                    file_count: row.fileCount, present: row.present, kind: row.kind, pinned: row.pinned), url_start: row.urlStart)
            }
            let fileViews = urls.map { bytes($0) }
            let groupViews = groups.map { AetherClipboardArchiveWriteGroup(id: bytes($0.id), timestamp: $0.timestamp, start: $0.start, count: $0.count) }
            return records.withUnsafeBufferPointer { records in
                fileViews.withUnsafeBufferPointer { urls in
                    groupViews.withUnsafeBufferPointer { groups in body(records, urls, groups) }
                }
            }
        }
    }
}
