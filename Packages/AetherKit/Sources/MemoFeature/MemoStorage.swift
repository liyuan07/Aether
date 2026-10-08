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
/// Swift copies borrowed records into platform UUID/Date DTOs for the native view adapter.
public final class MemoStorage {
    private let lock = NSRecursiveLock()
    private let core: UnsafeMutableRawPointer?

    public init(directory: URL) {
        core = directory.withUnsafeFileSystemRepresentation { aether_memo_create($0) }
    }
    deinit { aether_memo_destroy(core) }

    public func load() throws -> [MemoItem] {
        lock.lock(); defer { lock.unlock() }
        try check(aether_memo_load_records(core))
        return try records()
    }
    public func save(_ items: [MemoItem]) throws {
        lock.lock(); defer { lock.unlock() }
        let writer = aether_memo_writer_create()
        defer { aether_memo_writer_destroy(writer) }
        for item in items {
            try check(withRecord(item) { aether_memo_writer_append(writer, $0) })
        }
        try check(aether_memo_save_records(core, writer))
    }
    func add(_ item: MemoItem) throws {
        lock.lock(); defer { lock.unlock() }
        try check(withRecord(item) { aether_memo_add_record(core, $0) })
    }
    func complete(id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        try check(id.uuidString.withCString { aether_memo_complete(core, $0) })
    }
    func presentation(reloading: Bool = false) throws -> (items: [MemoItem], sorted: [MemoItem]) {
        lock.lock(); defer { lock.unlock() }
        if reloading { try check(aether_memo_load_records(core)) }
        let items = try records()
        var indices = Array(repeating: 0, count: items.count)
        let count = indices.withUnsafeMutableBufferPointer { aether_memo_order(core, $0.baseAddress, $0.count) }
        guard count == items.count else { throw MemoStorageError.unreadable }
        return (items, indices.map { items[$0] })
    }
    private func records() throws -> [MemoItem] {
        guard core != nil else { throw MemoStorageError.unreadable }
        var items: [MemoItem] = []
        items.reserveCapacity(aether_memo_count(core))
        for index in 0..<aether_memo_count(core) {
            var view = AetherMemoView()
            guard aether_memo_record(core, index, &view) != 0,
                  let id = UUID(uuidString: memoText(view.id)) else { throw MemoStorageError.unreadable }
            items.append(MemoItem(id: id, title: memoText(view.title),
                deadline: view.has_deadline == 0 ? nil : Date(timeIntervalSince1970: view.deadline / 1000),
                createdAt: Date(timeIntervalSince1970: view.created_at / 1000)))
        }
        return items
    }
    private func withRecord<T>(_ item: MemoItem, body: (AetherMemoView) -> T) -> T {
        withMemoUTF8(item.id.uuidString) { id in
            withMemoUTF8(item.title) { title in
                body(AetherMemoView(id: id, title: title,
                    created_at: item.createdAt.timeIntervalSince1970 * 1000,
                    deadline: (item.deadline?.timeIntervalSince1970 ?? 0) * 1000,
                    has_deadline: item.deadline == nil ? 0 : 1))
            }
        }
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

private func memoText(_ bytes: AetherBytes) -> String {
    guard bytes.length != 0, let data = bytes.data else { return "" }
    return String(decoding: UnsafeBufferPointer(start: data, count: bytes.length), as: UTF8.self)
}
private func withMemoUTF8<T>(_ text: String, _ body: (AetherBytes) -> T) -> T {
    if let result = text.utf8.withContiguousStorageIfAvailable({ body(AetherBytes(data: $0.baseAddress, length: $0.count)) }) { return result }
    return Array(text.utf8).withUnsafeBufferPointer { body(AetherBytes(data: $0.baseAddress, length: $0.count)) }
}
