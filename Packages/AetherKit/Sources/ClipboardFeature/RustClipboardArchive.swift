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
    func save(_ archive: ClipboardArchive, cleanup: ClipboardResourceFiles? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        var callbacks = cleanup?.callbacks ?? AetherClipboardResourceCleanup()
        var plan: UnsafeMutableRawPointer?
        defer { aether_clipboard_resource_cleanup_destroy(plan) }
        let status = withExtendedLifetime(cleanup) {
            withUnsafePointer(to: &callbacks) { callbacks in
                let status = encodeAndWrite(archive, callbacks: cleanup == nil ? nil : callbacks, plan: &plan)
                if status == 0, plan != nil { autoreleasepool { aether_clipboard_resource_cleanup_run(plan, callbacks) } }
                return status
            }
        }
        if status != 0 { throw RustDiskError(status: status) }
    }
    // This scope ends before enumeration/removal: the complete bridge arena cannot remain live then.
    @inline(never) private func encodeAndWrite(_ archive: ClipboardArchive, callbacks: UnsafePointer<AetherClipboardResourceCleanup>?, plan: inout UnsafeMutableRawPointer?) -> UInt32 {
        let wire = ClipboardArchiveWire(archive)
        return autoreleasepool {
            wire.withViews { rows, urls, groups, bytes in
                aether_clipboard_archive_write_spans_preparing_cleanup(core, rows.baseAddress, rows.count,
                    archive.history.count, archive.pinnedItems.count, urls.baseAddress, urls.count,
                    groups.baseAddress, groups.count, archive.groups == nil ? 0 : 1, bytes, callbacks, &plan)
            }
        }
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

/// Platform file/Unicode primitives; Rust owns reference selection, eligibility and removal planning.
final class ClipboardResourceFiles {
    private let directories: [URL]
    private let fileManager: FileManager
    private var files: [URL] = []
    private let nameBuffer = NSMutableData()
    init(images: URL, payloads: URL, fileManager: FileManager = .default) {
        directories = [images, payloads]; self.fileManager = fileManager
    }
    private func canonical(_ text: String) -> AetherBytes {
        var normalized = text.precomposedStringWithCanonicalMapping
        nameBuffer.length = 0
        normalized.withUTF8 { bytes in
            if let base = bytes.baseAddress { nameBuffer.append(base, length: bytes.count) }
        }
        return .init(data: nameBuffer.bytes.assumingMemoryBound(to: UInt8.self), length: nameBuffer.length)
    }
    var callbacks: AetherClipboardResourceCleanup {
        .init(context: Unmanaged.passUnretained(self).toOpaque(), canonical: { pointer, bytes in
            let owner = Unmanaged<ClipboardResourceFiles>.fromOpaque(pointer!).takeUnretainedValue()
            return owner.canonical(clipboardArchiveText(bytes))
        }, enumerate: { pointer, kind in
            let owner = Unmanaged<ClipboardResourceFiles>.fromOpaque(pointer!).takeUnretainedValue()
            guard Int(kind) < owner.directories.count else { return 0 }
            owner.files = (try? owner.fileManager.contentsOfDirectory(at: owner.directories[Int(kind)], includingPropertiesForKeys: nil)) ?? []
            return owner.files.count
        }, name: { pointer, index in
            let owner = Unmanaged<ClipboardResourceFiles>.fromOpaque(pointer!).takeUnretainedValue()
            return owner.canonical(owner.files[index].lastPathComponent)
        }, remove: { pointer, index in
            let owner = Unmanaged<ClipboardResourceFiles>.fromOpaque(pointer!).takeUnretainedValue()
            try? owner.fileManager.removeItem(at: owner.files[index])
        })
    }
}
