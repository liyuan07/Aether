// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CAetherCore
@testable import ClipboardFeature

// Frozen pre-streaming native bridge, used only for independent compatibility and timing.
struct ReferenceClipboardArchiveWire {
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
