import Darwin
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
    private struct Envelope: Codable {
        var schemaVersion: Int
        var collections: [QuickClipboardCollection]
    }

    private struct Version: Decodable {
        var schemaVersion: Int
    }

    private static let schemaVersion = 1
    private let directory: URL
    private let fileManager: FileManager
    private let lock = NSRecursiveLock()
    private var blocked = false

    init(
        directory: URL = AppEnvironment.directory("Clipboard"),
        fileManager: FileManager = .default
    ) {
        self.directory = directory
        self.fileManager = fileManager
    }

    var fileURL: URL {
        directory.appendingPathComponent("quick-maps.json")
    }

    func load() throws -> [QuickClipboardCollection] {
        lock.lock()
        defer { lock.unlock() }

        do {
            if let type = try? fileManager.attributesOfItem(atPath: fileURL.path)[.type],
               type as? FileAttributeType == .typeSymbolicLink {
                throw QuickClipboardStorageError.unreadable
            }
            guard fileManager.fileExists(atPath: fileURL.path) else {
                blocked = false
                return []
            }
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            guard try decoder.decode(Version.self, from: data).schemaVersion == Self.schemaVersion else {
                throw QuickClipboardStorageError.unsupportedVersion
            }
            let collections = try decoder.decode(Envelope.self, from: data).collections
            blocked = false
            return collections
        } catch {
            blocked = true
            throw (error as? QuickClipboardStorageError) ?? .unreadable
        }
    }

    func save(_ collections: [QuickClipboardCollection]) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !blocked else { throw QuickClipboardStorageError.unreadable }

        do {
            _ = try load()
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            guard try fileManager.attributesOfItem(atPath: directory.path)[.type]
                    as? FileAttributeType == .typeDirectory else {
                throw QuickClipboardStorageError.writeFailed
            }
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .millisecondsSince1970
            let data = try encoder.encode(
                Envelope(
                    schemaVersion: Self.schemaVersion,
                    collections: collections
                )
            )
            let temporary = directory.appendingPathComponent(
                ".quick-maps.\(UUID().uuidString).tmp"
            )
            defer { try? fileManager.removeItem(at: temporary) }
            guard fileManager.createFile(
                atPath: temporary.path,
                contents: data,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw QuickClipboardStorageError.writeFailed
            }
            guard rename(temporary.path, fileURL.path) == 0 else {
                throw QuickClipboardStorageError.writeFailed
            }
        } catch {
            throw (error as? QuickClipboardStorageError) ?? .writeFailed
        }
    }
}

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
        let normalized = Self.normalizedCollectionName(rawName)
        return collections.first {
            Self.normalizedCollectionName($0.name) == normalized
        }?.id
    }

    @discardableResult
    func createDefaultCollection() -> Result<UUID, QuickClipboardValidationError> {
        var index = 1
        while existingCollectionID(named: "常用 \(index)") != nil {
            index += 1
        }
        return createCollection(name: "常用 \(index)")
    }

    @discardableResult
    func createCollection(name rawName: String) -> Result<UUID, QuickClipboardValidationError> {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .failure(.emptyCollectionName) }
        if let existingID = existingCollectionID(named: name) {
            return .failure(.duplicateCollectionName(existingID: existingID))
        }
        let collection = QuickClipboardCollection(name: name, createdAt: now())
        guard persist(collections + [collection]) else {
            return .failure(.missingCollection)
        }
        selectedCollectionID = collection.id
        return .success(collection.id)
    }

    func renameCollection(
        id: UUID,
        name rawName: String
    ) -> Result<Void, QuickClipboardValidationError> {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .failure(.emptyCollectionName) }
        if let existingID = existingCollectionID(named: name), existingID != id {
            return .failure(.duplicateCollectionName(existingID: existingID))
        }
        guard let index = collections.firstIndex(where: { $0.id == id }) else {
            return .failure(.missingCollection)
        }
        var next = collections
        next[index].name = name
        next[index].updatedAt = now()
        guard persist(next) else { return .failure(.missingCollection) }
        return .success(())
    }

    @discardableResult
    func deleteCollection(id: UUID) -> QuickClipboardDeletedCollection? {
        guard let index = collections.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        let deleted = QuickClipboardDeletedCollection(
            index: index,
            collection: collections[index]
        )
        var next = collections
        next.remove(at: index)
        guard persist(next) else { return nil }
        selectedCollectionID = next.indices.contains(index)
            ? next[index].id
            : next.last?.id
        return deleted
    }

    func restoreCollection(_ deleted: QuickClipboardDeletedCollection) -> Bool {
        guard existingCollectionID(named: deleted.collection.name) == nil else {
            return false
        }
        var next = collections
        next.insert(deleted.collection, at: min(deleted.index, next.count))
        guard persist(next) else { return false }
        selectedCollectionID = deleted.collection.id
        return true
    }

    @discardableResult
    func addEntry(
        collectionID: UUID,
        key rawKey: String,
        value: String
    ) -> Result<UUID, QuickClipboardValidationError> {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return .failure(.emptyKey) }
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.emptyValue)
        }
        guard let collectionIndex = collections.firstIndex(where: { $0.id == collectionID }) else {
            return .failure(.missingCollection)
        }
        if let existing = collections[collectionIndex].entries.first(where: { $0.key == key }) {
            return .failure(.duplicateKey(existingID: existing.id))
        }
        let date = now()
        let entry = QuickClipboardEntry(
            key: key,
            value: value,
            createdAt: date
        )
        var next = collections
        next[collectionIndex].entries.append(entry)
        next[collectionIndex].updatedAt = date
        guard persist(next) else { return .failure(.missingCollection) }
        return .success(entry.id)
    }

    func updateEntry(
        collectionID: UUID,
        entryID: UUID,
        key rawKey: String,
        value: String
    ) -> Result<Void, QuickClipboardValidationError> {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return .failure(.emptyKey) }
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.emptyValue)
        }
        guard let collectionIndex = collections.firstIndex(where: { $0.id == collectionID }) else {
            return .failure(.missingCollection)
        }
        guard let entryIndex = collections[collectionIndex].entries.firstIndex(where: { $0.id == entryID }) else {
            return .failure(.missingCollection)
        }
        if let existing = collections[collectionIndex].entries.first(where: {
            $0.key == key && $0.id != entryID
        }) {
            return .failure(.duplicateKey(existingID: existing.id))
        }
        let date = now()
        var next = collections
        next[collectionIndex].entries[entryIndex].key = key
        next[collectionIndex].entries[entryIndex].value = value
        next[collectionIndex].entries[entryIndex].updatedAt = date
        next[collectionIndex].updatedAt = date
        guard persist(next) else { return .failure(.missingCollection) }
        return .success(())
    }

    @discardableResult
    func deleteEntry(
        collectionID: UUID,
        entryID: UUID
    ) -> QuickClipboardDeletedEntry? {
        guard let collectionIndex = collections.firstIndex(where: { $0.id == collectionID }),
              let entryIndex = collections[collectionIndex].entries.firstIndex(where: { $0.id == entryID }) else {
            return nil
        }
        let deleted = QuickClipboardDeletedEntry(
            collectionID: collectionID,
            index: entryIndex,
            entry: collections[collectionIndex].entries[entryIndex]
        )
        var next = collections
        next[collectionIndex].entries.remove(at: entryIndex)
        next[collectionIndex].updatedAt = now()
        guard persist(next) else { return nil }
        return deleted
    }

    func restoreEntry(_ deleted: QuickClipboardDeletedEntry) -> Bool {
        guard let collectionIndex = collections.firstIndex(where: {
            $0.id == deleted.collectionID
        }), !collections[collectionIndex].entries.contains(where: {
            $0.key == deleted.entry.key
        }) else {
            return false
        }
        var next = collections
        next[collectionIndex].entries.insert(
            deleted.entry,
            at: min(deleted.index, next[collectionIndex].entries.count)
        )
        next[collectionIndex].updatedAt = now()
        return persist(next)
    }

    private func persist(_ next: [QuickClipboardCollection]) -> Bool {
        do {
            try storage.save(next)
            collections = next
            storageMessage = nil
            return true
        } catch {
            storageMessage = error.localizedDescription
            return false
        }
    }

    private static func normalizedCollectionName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: .current
            )
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

    return collections.compactMap { collection in
        let name = normalizedQuickClipboardSearchText(collection.name)
        if name == query {
            return QuickClipboardSearchSection(
                collectionID: collection.id,
                collectionName: collection.name,
                entries: collection.entries,
                rank: 0,
                updatedAt: collection.updatedAt
            )
        }

        let collectionRank: Int? = name.hasPrefix(query)
            ? 2
            : (name.contains(query) ? 3 : nil)
        let rankedEntries: [(entry: QuickClipboardEntry, rank: Int, index: Int)] =
            collection.entries.enumerated().compactMap { index, entry in
                let key = normalizedQuickClipboardSearchText(entry.key)
                let value = normalizedQuickClipboardSearchText(entry.value)
                let rank: Int?
                if key == query {
                    rank = 1
                } else if key.hasPrefix(query) || collectionRank == 2 {
                    rank = 2
                } else if key.contains(query) || value.contains(query) || collectionRank == 3 {
                    rank = 3
                } else {
                    rank = nil
                }
                return rank.map { (entry, $0, index) }
            }
            .sorted {
                if $0.rank != $1.rank { return $0.rank < $1.rank }
                if $0.entry.updatedAt != $1.entry.updatedAt {
                    return $0.entry.updatedAt > $1.entry.updatedAt
                }
                return $0.index < $1.index
            }

        guard collectionRank != nil || !rankedEntries.isEmpty else { return nil }
        return QuickClipboardSearchSection(
            collectionID: collection.id,
            collectionName: collection.name,
            entries: rankedEntries.map(\.entry),
            rank: min(collectionRank ?? Int.max, rankedEntries.first?.rank ?? Int.max),
            updatedAt: collection.updatedAt
        )
    }
    .sorted {
        if $0.rank != $1.rank { return $0.rank < $1.rank }
        return $0.updatedAt > $1.updatedAt
    }
}

private func normalizedQuickClipboardSearchText(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
        .folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        )
}
