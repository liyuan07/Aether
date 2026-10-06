// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Combine
import RustCore
import SharedSupport
import XCTest
@testable import ClipboardFeature

final class RustQuickClipboardParityTests: XCTestCase {
    func testSearchMatchesIndependentPreviousSwiftRanking() {
        let texts = ["中文", "API", "ＡＰＩ", "á", "a\u{301}", "A", "👨‍👩‍👧‍👦", "👨", "\r\n", " ", "test", "前缀test后缀", "\u{0000}"]
        for seed in 0..<100 {
            let collections = (0..<12).map { c in
                QuickClipboardCollection(name: texts[(c * 7 + seed) % texts.count],
                    createdAt: Date(timeIntervalSince1970: Double((c + seed) % 5)),
                    entries: (0..<(c % 5)).map { e in
                        QuickClipboardEntry(key: texts[(e * 3 + c + seed) % texts.count],
                            value: texts[(e * 7 + seed) % texts.count],
                            createdAt: Date(timeIntervalSince1970: Double((e + c) % 3)))
                    })
            }
            for query in texts + ["不存在", "api", " a "] {
                XCTAssertEqual(quickClipboardSearch(query: query, collections: collections),
                    previousQuickClipboardSearch(query: query, collections: collections))
            }
        }
    }

    @MainActor
    func testMutationSequenceMatchesIndependentPreviousSwiftModel() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AetherQuickParity-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let storage = QuickClipboardStorage(directory: root.appendingPathComponent("rust"))
        let referenceStorage = PreviousQuickClipboardStorage(directory: root.appendingPathComponent("swift"))
        let model = QuickClipboardModel(storage: storage, now: { date })
        let reference = PreviousQuickClipboardModel(storage: referenceStorage, now: { date })
        let id = UUID()
        let collection = QuickClipboardCollection(id: id, name: "开始", createdAt: date)
        try storage.save([collection]); try referenceStorage.save([collection])
        model.reload(); reference.reload()
        for index in 0..<100 {
            let names = [" 名称 ", "ＡＰＩ", "api", "á", "a\u{301}", "", "环境\(index)"]
            let name = names[index % names.count]
            assertVoid(model.renameCollection(id: id, name: name), reference.renameCollection(id: id, name: name))
            let key = ["API", "api", " á ", "a\u{301}", "", "键\(index)"][index % 6]
            let value = index % 7 == 0 ? " \n" : "合成内容\u{0000}\(index)"
            let left = model.addEntry(collectionID: id, key: key, value: value)
            let right = reference.addEntry(collectionID: id, key: key, value: value)
            switch (left,right) {
            case (.success, .success): break
            case let (.failure(a),.failure(b)): XCTAssertEqual(errorKind(a), errorKind(b))
            default: XCTFail("Mismatched add result")
            }
            assertEquivalent(model.collections, reference.collections)
            if index % 3 == 0, let l = model.collections.first?.entries.last, let r = reference.collections.first?.entries.last {
                assertVoid(model.updateEntry(collectionID: id, entryID: l.id, key: "更新", value: "更新内容"),
                    reference.updateEntry(collectionID: id, entryID: r.id, key: "更新", value: "更新内容"))
                let ld = model.deleteEntry(collectionID: id, entryID: l.id)
                let rd = reference.deleteEntry(collectionID: id, entryID: r.id)
                XCTAssertEqual(ld == nil, rd == nil)
                if let ld, let rd { XCTAssertEqual(model.restoreEntry(ld), reference.restoreEntry(rd)) }
            }
            assertEquivalent(model.collections, reference.collections)
        }
        let removed = try XCTUnwrap(model.deleteCollection(id: id))
        let previousRemoved = try XCTUnwrap(reference.deleteCollection(id: id))
        XCTAssertEqual(model.restoreCollection(removed), reference.restoreCollection(previousRemoved))
        assertEquivalent(model.collections, reference.collections)
    }
    @MainActor
    func testMutationBenchmark() throws {
        guard ProcessInfo.processInfo.environment["AETHER_RUN_CORE_BENCHMARKS"] == "1" else { throw XCTSkip("Opt-in synthetic benchmark") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AetherQuickBenchmark-\(UUID())")
        defer { try? FileManager.default.removeItem(at:root) }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let collections = (0..<50).map { c in
            QuickClipboardCollection(name: "合成分组\(c)", createdAt: date, entries: (0..<20).map { e in
                QuickClipboardEntry(key:"合成标题\(e)",value:String(repeating:"合成正文",count:128),createdAt:date)
            })
        }
        let rustStorage = QuickClipboardStorage(directory:root.appendingPathComponent("rust"))
        let swiftStorage = PreviousQuickClipboardStorage(directory:root.appendingPathComponent("swift"))
        try rustStorage.save(collections); try swiftStorage.save(collections)
        let rust = QuickClipboardModel(storage:rustStorage,now:{date})
        let swift = PreviousQuickClipboardModel(storage:swiftStorage,now:{date})
        var rustTimes:[Double]=[], swiftTimes:[Double]=[]
        for iteration in 0..<9 {
            let clock=ContinuousClock()
            let start=clock.now
            try rust.renameCollection(id:collections[0].id,name:"更新\(iteration)").get()
            let middle=clock.now
            try swift.renameCollection(id:collections[0].id,name:"更新\(iteration)").get()
            let end=clock.now
            rustTimes.append(milliseconds(start.duration(to:middle)))
            swiftTimes.append(milliseconds(middle.duration(to:end)))
            XCTAssertEqual(rust.collections,swift.collections)
        }
        print("QUICK_MUTATION_SYNTHETIC 50 groups / 1000 entries median Rust=\(rustTimes.sorted()[4])ms Swift=\(swiftTimes.sorted()[4])ms")
    }
    private func milliseconds(_ duration:Duration)->Double {
        let parts=duration.components
        return Double(parts.seconds)*1000+Double(parts.attoseconds)/1e15
    }

    private func assertEquivalent(_ a: [QuickClipboardCollection], _ b: [QuickClipboardCollection]) {
        // Generated identities differ; compare all user data, dates, ordering and record counts.
        XCTAssertEqual(a.count,b.count)
        for (a,b) in zip(a,b) {
            XCTAssertEqual(a.name,b.name); XCTAssertEqual(a.createdAt,b.createdAt); XCTAssertEqual(a.updatedAt,b.updatedAt)
            XCTAssertEqual(a.entries.map(\.key),b.entries.map(\.key)); XCTAssertEqual(a.entries.map(\.value),b.entries.map(\.value))
            XCTAssertEqual(a.entries.map(\.createdAt),b.entries.map(\.createdAt)); XCTAssertEqual(a.entries.map(\.updatedAt),b.entries.map(\.updatedAt))
        }
    }
    private func assertVoid(_ a: Result<Void,QuickClipboardValidationError>, _ b: Result<Void,QuickClipboardValidationError>) {
        switch (a,b) {
        case (.success,.success): break
        case let (.failure(a),.failure(b)): XCTAssertEqual(errorKind(a),errorKind(b))
        default: XCTFail("Mismatched update result")
        }
    }
    private func errorKind(_ error: QuickClipboardValidationError) -> String {
        switch error {
        case .emptyCollectionName: "empty-name"
        case .duplicateCollectionName: "duplicate-name"
        case .missingCollection: "missing"
        case .emptyKey: "empty-key"
        case .emptyValue: "empty-value"
        case .duplicateKey: "duplicate-key"
        }
    }
}

// The pre-migration Swift business implementation is an independent test oracle.
@MainActor
private final class PreviousQuickClipboardModel: ObservableObject {
    @Published private(set) var collections: [QuickClipboardCollection] = []
    @Published var selectedCollectionID: UUID?
    @Published private(set) var storageMessage: String?

    private let storage: PreviousQuickClipboardStorage
    private let now: () -> Date

    init(
        storage: PreviousQuickClipboardStorage? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.storage = storage ?? PreviousQuickClipboardStorage()
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

private func previousQuickClipboardSearch(
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

private final class PreviousQuickClipboardStorage {
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
            guard let data = try RustDisk.read(fileURL) else {
                blocked = false
                return []
            }
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
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .millisecondsSince1970
            let data = try encoder.encode(
                Envelope(
                    schemaVersion: Self.schemaVersion,
                    collections: collections
                )
            )
            try RustDisk.write(data, to: fileURL)
        } catch {
            throw (error as? QuickClipboardStorageError) ?? .writeFailed
        }
    }
}
