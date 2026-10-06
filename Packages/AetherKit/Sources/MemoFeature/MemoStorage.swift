import RustCore
import CAetherCore
import Foundation

public enum MemoStorageError: LocalizedError {
    case unreadable, unsupportedVersion, writeFailed

    public var errorDescription: String? {
        switch self {
        case .unreadable: "无法读取备忘录，原文件已保留。请检查文件后重新打开 Aether。"
        case .unsupportedVersion: "备忘录来自较新版本，已停止写入以保留原数据。请更新 Aether。"
        case .writeFailed: "无法保存备忘录，请检查本机存储空间和文件权限。"
        }
    }
}

/// Rust owns data validation, mutation, atomic persistence and ordering.
/// Swift serializes platform UUID/Date DTOs for the native view adapter.
public final class MemoStorage {
    private let lock = NSRecursiveLock()
    private let core: UnsafeMutableRawPointer?

    public init(directory: URL) {
        core = directory.withUnsafeFileSystemRepresentation { aether_memo_create($0) }
    }
    deinit { aether_memo_destroy(core) }

    public func load() throws -> [MemoItem] {
        lock.lock(); defer { lock.unlock() }
        return try decode(aether_memo_load(core))
    }
    public func save(_ items: [MemoItem]) throws {
        lock.lock(); defer { lock.unlock() }
        let data = try encode(items)
        try check(data.withUnsafeBytes { aether_memo_save(core, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) })
    }
    func add(_ item: MemoItem) throws {
        lock.lock(); defer { lock.unlock() }
        let data = try encode(item)
        try check(data.withUnsafeBytes { aether_memo_add(core, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) })
    }
    func complete(id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        try check(id.uuidString.withCString { aether_memo_complete(core, $0) })
    }
    func presentation(reloading: Bool = false) throws -> (items: [MemoItem], sorted: [MemoItem]) {
        lock.lock(); defer { lock.unlock() }
        let items = try decode(reloading ? aether_memo_load(core) : aether_memo_snapshot(core, 0))
        var indices = Array(repeating: 0, count: items.count)
        let count = indices.withUnsafeMutableBufferPointer { aether_memo_order(core, $0.baseAddress, $0.count) }
        guard count == items.count else { throw MemoStorageError.unreadable }
        return (items, indices.map { items[$0] })
    }
    private func encode<T: Encodable>(_ value: T) throws -> Data {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            return try encoder.encode(value)
        } catch { throw MemoStorageError.writeFailed }
    }
    private func decode(_ buffer: UnsafeMutableRawPointer?) throws -> [MemoItem] {
        do {
            let data = try RustBuffer.take(buffer)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            return try decoder.decode([MemoItem].self, from: data)
        } catch let error as RustDiskError {
            throw error.status == 4 ? MemoStorageError.unsupportedVersion : MemoStorageError.unreadable
        } catch { throw MemoStorageError.unreadable }
    }
    private func check(_ status: UInt32) throws {
        switch status {
        case 0: return
        case 2: throw MemoStorageError.unreadable
        case 4: throw MemoStorageError.unsupportedVersion
        default: throw MemoStorageError.writeFailed
        }
    }
}
