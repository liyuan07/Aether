import CAetherCore
import RustCore
import Foundation
import SharedSupport

struct QuickClipboardEntry: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var key: String
    var value: String
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        key: String,
        value: String,
        createdAt: Date = Date(),
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.key = key
        self.value = value
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }
}

struct QuickClipboardCollection: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    let createdAt: Date
    var updatedAt: Date
    var entries: [QuickClipboardEntry]

    init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        entries: [QuickClipboardEntry] = []
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.entries = entries
    }
}

enum QuickClipboardStorageError: LocalizedError, Equatable {
    case unreadable
    case unsupportedVersion
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .unreadable:
            "无法读取常用剪贴板，原文件已保留。请检查文件后重新打开 Aether。"
        case .unsupportedVersion:
            "常用剪贴板来自较新版本，已停止写入以保留原数据。请更新 Aether。"
        case .writeFailed:
            "无法保存常用剪贴板，请检查本机存储空间和文件权限。"
        }
    }
}

final class QuickClipboardStorage {
    private let directory: URL
    private let lock = NSRecursiveLock()
    private let core: UnsafeMutableRawPointer?

    init(directory: URL = AppEnvironment.directory("Clipboard"), fileManager: FileManager = .default) {
        self.directory = directory
        core = directory.appendingPathComponent("quick-maps.json").withUnsafeFileSystemRepresentation {
            aether_quick_create($0)
        }
    }
    deinit { aether_quick_destroy(core) }
    var fileURL: URL { directory.appendingPathComponent("quick-maps.json") }

    func load() throws -> [QuickClipboardCollection] {
        lock.lock(); defer { lock.unlock() }
        let collections: [QuickClipboardCollection] = try decode(aether_quick_load(core))
        try installComparisons(collections)
        return collections
    }
    func save(_ collections: [QuickClipboardCollection]) throws {
        lock.lock(); defer { lock.unlock() }
        let data = try encode(collections)
        try check(data.withUnsafeBytes { aether_quick_save(core, span($0)) })
        try installComparisons(collections)
    }
    fileprivate func apply(_ command: QuickClipboardCommand) throws -> QuickClipboardReply {
        lock.lock(); defer { lock.unlock() }
        let data = try encode(command)
        return try data.withUnsafeBytes { try decode(aether_quick_apply(core, span($0))) }
    }
    private func installComparisons(_ collections: [QuickClipboardCollection]) throws {
        struct Comparisons: Encodable { let name: String; let keys: [String] }
        let data = try encode(collections.map {
            Comparisons(name: normalizedQuickClipboardName($0.name), keys: $0.entries.map { canonicalQuickClipboardKey($0.key) })
        })
        try check(data.withUnsafeBytes { aether_quick_comparisons(core, span($0)) })
    }
    private func span(_ bytes: UnsafeRawBufferPointer) -> AetherBytes {
        AetherBytes(data: bytes.bindMemory(to: UInt8.self).baseAddress, length: bytes.count)
    }
    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        do { return try encoder.encode(value) } catch { throw QuickClipboardStorageError.writeFailed }
    }
    private func decode<T: Decodable>(_ handle: UnsafeMutableRawPointer?) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        do { return try decoder.decode(T.self, from: RustBuffer.take(handle)) }
        catch let error as RustDiskError { try check(error.status); throw QuickClipboardStorageError.unreadable }
        catch { throw QuickClipboardStorageError.unreadable }
    }
    private func check(_ status: UInt32) throws {
        switch status {
        case 0: return
        case 2: throw QuickClipboardStorageError.unreadable
        case 4: throw QuickClipboardStorageError.unsupportedVersion
        default: throw QuickClipboardStorageError.writeFailed
        }
    }
}

private struct QuickClipboardCommand: Encodable {
    var action: UInt32
    var id: UUID? = nil
    var collectionID: UUID? = nil
    var entryID: UUID? = nil
    var name: String? = nil
    var key: String? = nil
    var value: String? = nil
    var comparison: String? = nil
    var nonempty: Bool? = nil
    var date: Double? = nil
    var index: Int? = nil
    var collection: QuickClipboardCollection? = nil
    var entry: QuickClipboardEntry? = nil
    var keys: [String]? = nil
}
private struct QuickClipboardReply: Decodable {
    let error: UInt32
    let existingID: UUID?
    let resultID: UUID?
    let selection: UUID?
    let patch: Patch?
    struct Patch: Decodable { let kind: UInt32; let index: Int; let collection: QuickClipboardCollection? }
    let deletedCollection: QuickClipboardCollection?
    let deletedEntry: QuickClipboardEntry?
    let index: Int
}
private func normalizedQuickClipboardName(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
        .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
        .precomposedStringWithCanonicalMapping
}
private func canonicalQuickClipboardKey(_ value: String) -> String { value.precomposedStringWithCanonicalMapping }

enum QuickClipboardValidationError: LocalizedError, Equatable {
    case emptyCollectionName
    case duplicateCollectionName(existingID: UUID)
    case missingCollection
    case emptyKey
    case emptyValue
    case duplicateKey(existingID: UUID)

    var errorDescription: String? {
        switch self {
        case .emptyCollectionName: "请输入名称。"
        case .duplicateCollectionName: "这个名称已被使用。"
        case .missingCollection: "没有找到此内容。"
        case .emptyKey: "请输入标题。"
        case .emptyValue: "请输入内容。"
        case .duplicateKey: "这个标题已存在。"
        }
    }
}

struct QuickClipboardDeletedEntry: Equatable {
    let collectionID: UUID
    let index: Int
    let entry: QuickClipboardEntry
}

struct QuickClipboardDeletedCollection: Equatable {
    let index: Int
    let collection: QuickClipboardCollection
}

@MainActor
final class QuickClipboardModel: ObservableObject {
    @Published private(set) var collections: [QuickClipboardCollection] = []
    @Published var selectedCollectionID: UUID?
    @Published private(set) var storageMessage: String?

    private let storage: QuickClipboardStorage
    private let now: () -> Date

    init(
        storage: QuickClipboardStorage? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.storage = storage ?? QuickClipboardStorage()
        self.now = now
        reload()
    }

    var selectedCollection: QuickClipboardCollection? {
        guard let selectedCollectionID else { return collections.first }
        return collections.first { $0.id == selectedCollectionID }
            ?? collections.first
    }

    func reload() {
        do {
            collections = try storage.load()
            if selectedCollectionID.flatMap({ id in
                collections.first { $0.id == id }
            }) == nil {
                selectedCollectionID = collections.first?.id
            }
            storageMessage = nil
        } catch {
            storageMessage = error.localizedDescription
        }
    }

    func existingCollectionID(named rawName: String) -> UUID? {
        try? storage.apply(.init(action: 0, comparison: normalizedQuickClipboardName(rawName))).resultID
    }

    @discardableResult
    func createDefaultCollection() -> Result<UUID, QuickClipboardValidationError> {
        createCollectionCommand(action: 2, name: nil)
    }

    @discardableResult
    func createCollection(name rawName: String) -> Result<UUID, QuickClipboardValidationError> {
        createCollectionCommand(action: 1, name: rawName.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func createCollectionCommand(action: UInt32, name: String?) -> Result<UUID, QuickClipboardValidationError> {
        let command = QuickClipboardCommand(action: action, id: UUID(), name: name,
            comparison: name.map(normalizedQuickClipboardName), date: now().timeIntervalSince1970 * 1000)
        return apply(command).flatMap { reply in
            guard let id = reply.resultID else { return .failure(.missingCollection) }
            selectedCollectionID = reply.selection
            return .success(id)
        }
    }

    func renameCollection(id: UUID, name rawName: String) -> Result<Void, QuickClipboardValidationError> {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        return apply(.init(action: 3, collectionID: id, name: name, comparison: normalizedQuickClipboardName(name),
            date: now().timeIntervalSince1970 * 1000)).map { _ in () }
    }

    @discardableResult
    func deleteCollection(id: UUID) -> QuickClipboardDeletedCollection? {
        guard case let .success(reply) = apply(.init(action: 4, collectionID: id)),
              let collection = reply.deletedCollection else { return nil }
        selectedCollectionID = reply.selection
        return .init(index: reply.index, collection: collection)
    }

    func restoreCollection(_ deleted: QuickClipboardDeletedCollection) -> Bool {
        let command = QuickClipboardCommand(action: 5, comparison: normalizedQuickClipboardName(deleted.collection.name),
            index: deleted.index, collection: deleted.collection, keys: deleted.collection.entries.map { canonicalQuickClipboardKey($0.key) })
        guard case let .success(reply) = apply(command) else { return false }
        selectedCollectionID = reply.selection
        return true
    }

    @discardableResult
    func addEntry(collectionID: UUID, key rawKey: String, value: String) -> Result<UUID, QuickClipboardValidationError> {
        let id = UUID()
        return apply(entryCommand(action: 6, collectionID: collectionID, entryID: nil, id: id, key: rawKey, value: value)).map { _ in id }
    }

    func updateEntry(collectionID: UUID, entryID: UUID, key rawKey: String, value: String) -> Result<Void, QuickClipboardValidationError> {
        apply(entryCommand(action: 7, collectionID: collectionID, entryID: entryID, id: nil, key: rawKey, value: value)).map { _ in () }
    }

    private func entryCommand(action: UInt32, collectionID: UUID, entryID: UUID?, id: UUID?, key rawKey: String, value: String) -> QuickClipboardCommand {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return .init(action: action, id: id, collectionID: collectionID, entryID: entryID, key: key, value: value,
            comparison: canonicalQuickClipboardKey(key), nonempty: !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            date: now().timeIntervalSince1970 * 1000)
    }

    @discardableResult
    func deleteEntry(collectionID: UUID, entryID: UUID) -> QuickClipboardDeletedEntry? {
        guard case let .success(reply) = apply(.init(action: 8, collectionID: collectionID, entryID: entryID,
            date: now().timeIntervalSince1970 * 1000)), let entry = reply.deletedEntry else { return nil }
        return .init(collectionID: collectionID, index: reply.index, entry: entry)
    }

    func restoreEntry(_ deleted: QuickClipboardDeletedEntry) -> Bool {
        let command = QuickClipboardCommand(action: 9, collectionID: deleted.collectionID, comparison: canonicalQuickClipboardKey(deleted.entry.key),
            date: now().timeIntervalSince1970 * 1000, index: deleted.index, entry: deleted.entry)
        if case .success = apply(command) { return true }
        return false
    }

    private func apply(_ command: QuickClipboardCommand) -> Result<QuickClipboardReply, QuickClipboardValidationError> {
        do {
            let reply = try storage.apply(command)
            switch reply.error {
            case 0:
                if let patch = reply.patch {
                    // Publish the core's committed projection; validation and transaction policy remain in Rust.
                    var next = collections
                    switch patch.kind {
                    case 1:
                        guard let collection = patch.collection, (0...next.count).contains(patch.index) else { throw QuickClipboardStorageError.unreadable }
                        next.insert(collection, at: patch.index)
                    case 2:
                        guard let collection = patch.collection, next.indices.contains(patch.index) else { throw QuickClipboardStorageError.unreadable }
                        next[patch.index] = collection
                    case 3:
                        guard next.indices.contains(patch.index) else { throw QuickClipboardStorageError.unreadable }
                        next.remove(at: patch.index)
                    default: throw QuickClipboardStorageError.unreadable
                    }
                    collections = next
                    storageMessage = nil
                }
                return .success(reply)
            case 200: return .failure(.emptyCollectionName)
            case 201:
                guard let id = reply.existingID else { return .failure(.missingCollection) }
                return .failure(.duplicateCollectionName(existingID: id))
            case 203: return .failure(.emptyKey)
            case 204: return .failure(.emptyValue)
            case 205:
                guard let id = reply.existingID else { return .failure(.missingCollection) }
                return .failure(.duplicateKey(existingID: id))
            default: return .failure(.missingCollection)
            }
        } catch {
            storageMessage = error.localizedDescription
            return .failure(.missingCollection)
        }
    }
}

struct QuickClipboardSearchSection: Equatable, Identifiable {
    let collectionID: UUID
    let collectionName: String
    let entries: [QuickClipboardEntry]
    let rank: Int
    let updatedAt: Date

    var id: UUID { collectionID }
}

func quickClipboardSearch(
    query rawQuery: String,
    collections: [QuickClipboardCollection]
) -> [QuickClipboardSearchSection] {
    let query = normalizedQuickClipboardSearchText(rawQuery)
    guard !query.isEmpty else { return [] }

    var groups: [AetherQuickSearchCollection] = []
    var rows: [AetherQuickSearchEntry] = []
    var entries: [QuickClipboardEntry] = []
    for collection in collections {
        let name = normalizedQuickClipboardSearchText(collection.name)
        let match = quickClipboardTextMatch(name, query: query)
        groups.append(.init(match_kind: match, timestamp: collection.updatedAt.timeIntervalSinceReferenceDate,
            start: rows.count, count: collection.entries.count))
        for entry in collection.entries {
            let key = match == 1 ? "" : normalizedQuickClipboardSearchText(entry.key)
            let value = match == 1 ? "" : normalizedQuickClipboardSearchText(entry.value)
            rows.append(.init(key_match: quickClipboardTextMatch(key, query: query), value_match: value.contains(query) ? 1 : 0,
                timestamp: entry.updatedAt.timeIntervalSinceReferenceDate))
            entries.append(entry)
        }
    }
    var sections = Array(repeating: AetherQuickSearchSection(), count: collections.count)
    var indices = Array(repeating: 0, count: entries.count)
    let count = groups.withUnsafeBufferPointer { groups in
        rows.withUnsafeBufferPointer { rows in
            sections.withUnsafeMutableBufferPointer { sections in
                indices.withUnsafeMutableBufferPointer { indices in
                    aether_quick_search(groups.baseAddress, groups.count, rows.baseAddress, rows.count,
                        sections.baseAddress, sections.count, indices.baseAddress, indices.count)
                }
            }
        }
    }
    return sections.prefix(count).map { section in
        let collection = collections[section.collection]
        return .init(collectionID: collection.id, collectionName: collection.name,
            entries: indices[section.start..<(section.start + section.count)].map { entries[$0] },
            rank: section.rank, updatedAt: collection.updatedAt)
    }
}

private func quickClipboardTextMatch(_ text: String, query: String) -> UInt8 {
    if text == query { return 1 }
    if text.hasPrefix(query) { return 2 }
    return text.contains(query) ? 3 : 0
}

private func normalizedQuickClipboardSearchText(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
        .folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        )
}
