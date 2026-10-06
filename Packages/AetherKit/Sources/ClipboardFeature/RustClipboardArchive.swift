// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CAetherCore
import RustCore

/// Owns archive validation/write protection; native Codable remains the presentation DTO bridge.
final class RustClipboardArchive: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private let core: UnsafeMutableRawPointer?
    init(fileURL: URL) { core = fileURL.withUnsafeFileSystemRepresentation { aether_clipboard_archive_create($0) } }
    deinit { aether_clipboard_archive_destroy(core) }

    func load() throws -> ClipboardArchive? {
        lock.lock(); defer { lock.unlock() }
        do {
            let data = try RustBuffer.take(aether_clipboard_archive_read(core))
            do { return try JSONDecoder().decode(ClipboardArchive.self, from: data) }
            catch { aether_clipboard_archive_block(core); throw error }
        } catch let error as RustDiskError where error.status == 1 { return nil }
    }
    func save(_ archive: ClipboardArchive) throws {
        lock.lock(); defer { lock.unlock() }
        let data = try JSONEncoder().encode(archive)
        let status = data.withUnsafeBytes { aether_clipboard_archive_write(core,
            .init(data: $0.bindMemory(to: UInt8.self).baseAddress, length: $0.count)) }
        if status != 0 { throw RustDiskError(status: status) }
    }
}
