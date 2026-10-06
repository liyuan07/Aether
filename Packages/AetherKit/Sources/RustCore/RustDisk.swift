// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CAetherCore

public struct RustDiskError: Error {
    public let status: UInt32
    public init(status: UInt32) { self.status = status }
}

/// Owns the buffer returned by the core; Data receives that ownership without
/// copying the JSON bytes. The Rust handle is released by Data's deallocator.
public enum RustBuffer {
    public static func take(_ handle: UnsafeMutableRawPointer?) throws -> Data {
        let view = aether_buffer_view(handle)
        guard view.status == 0 else {
            aether_buffer_destroy(handle)
            throw RustDiskError(status: view.status)
        }
        guard view.length > 0, let bytes = view.bytes else {
            aether_buffer_destroy(handle)
            return Data()
        }
        return Data(bytesNoCopy: bytes, count: view.length, deallocator: .custom { _, _ in
            aether_buffer_destroy(handle)
        })
    }
}

public enum RustDisk {
    public static func read(_ file: URL, rejectSymbolicLinks: Bool = true) throws -> Data? {
        let handle = file.withUnsafeFileSystemRepresentation { aether_file_read($0, rejectSymbolicLinks ? 1 : 0) }
        let view = aether_buffer_view(handle)
        if view.status == 1 { aether_buffer_destroy(handle); return nil }
        return try RustBuffer.take(handle)
    }
    public static func write(_ data: Data, to file: URL, privateFile: Bool = true, synchronize: Bool = false) throws {
        let status = file.withUnsafeFileSystemRepresentation { path in
            data.withUnsafeBytes { bytes in
                aether_file_write(path, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, privateFile ? 1 : 0, synchronize ? 1 : 0)
            }
        }
        guard status == 0 else { throw RustDiskError(status: status) }
    }
}
