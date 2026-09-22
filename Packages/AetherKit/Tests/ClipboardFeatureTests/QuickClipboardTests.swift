import Foundation
import XCTest
@testable import ClipboardFeature

final class QuickClipboardTests: XCTestCase {
    func testStorageRoundTripPreservesCollectionsEntriesAndPrivatePermissions() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = QuickClipboardStorage(directory: directory)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let collections = [
            QuickClipboardCollection(
                name: "测试环境",
                createdAt: date,
                entries: [
                    QuickClipboardEntry(
                        key: "API_KEY",
                        value: "first line\nsecond line",
                        createdAt: date
                    )
                ]
            )
        ]

        try storage.save(collections)

        XCTAssertEqual(try storage.load(), collections)
        let directoryMode = try permissions(at: directory)
        let fileMode = try permissions(at: storage.fileURL)
        XCTAssertEqual(directoryMode & 0o777, 0o700)
        XCTAssertEqual(fileMode & 0o777, 0o600)
    }

    func testNewerStorageVersionIsPreservedAndBlocksOverwrite() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let storage = QuickClipboardStorage(directory: directory)
        let original = Data("{\"schemaVersion\":99,\"collections\":[]}".utf8)
        try original.write(to: storage.fileURL)

        XCTAssertThrowsError(try storage.load()) { error in
            XCTAssertEqual(error as? QuickClipboardStorageError, .unsupportedVersion)
        }
        XCTAssertThrowsError(try storage.save([]))
        XCTAssertEqual(try Data(contentsOf: storage.fileURL), original)
    }

    @MainActor
    func testCollectionNamesAreTrimmedAndComparedCaseInsensitively() {
        let context = modelContext()
        defer { context.cleanup() }
        let model = context.model

        XCTAssertNotNil(try? model.createCollection(name: "  Production  ").get())
        let duplicate = model.createCollection(name: "production")

        guard case let .failure(error) = duplicate,
              case let .duplicateCollectionName(existingID) = error else {
            return XCTFail("Expected a duplicate collection name")
        }
        XCTAssertEqual(existingID, model.collections[0].id)
        XCTAssertEqual(model.collections[0].name, "Production")
    }

    @MainActor
    func testDefaultCollectionNamesAreAvailableImmediatelyAndDoNotCollide() throws {
        let context = modelContext()
        defer { context.cleanup() }
        let model = context.model

        let firstID = try model.createDefaultCollection().get()
        _ = try model.createCollection(name: "常用 2").get()
        let thirdID = try model.createDefaultCollection().get()

        XCTAssertEqual(model.collections.map(\.name), ["常用 1", "常用 2", "常用 3"])
        XCTAssertEqual(model.selectedCollectionID, thirdID)
        XCTAssertNotEqual(firstID, thirdID)
    }

    @MainActor
    func testKeysUseExactMatchingAndStableEntryOrder() throws {
        let context = modelContext()
        defer { context.cleanup() }
        let model = context.model
        let collectionID = try model.createCollection(name: "环境").get()
        let upperID = try model.addEntry(
            collectionID: collectionID,
            key: "API_KEY",
            value: "upper"
        ).get()
        let lowerID = try model.addEntry(
            collectionID: collectionID,
            key: "api_key",
            value: "lower"
        ).get()

        let duplicate = model.addEntry(
            collectionID: collectionID,
            key: " API_KEY ",
            value: "replacement"
        )
        guard case let .failure(error) = duplicate,
              case let .duplicateKey(existingID) = error else {
            return XCTFail("Expected an exact duplicate key")
        }
        XCTAssertEqual(existingID, upperID)
        XCTAssertEqual(
            model.selectedCollection?.entries.map(\.id),
            [upperID, lowerID]
        )
    }

    @MainActor
    func testEditingKeepsIdentityAndDeletingCanBeUndone() throws {
        let context = modelContext()
        defer { context.cleanup() }
        let model = context.model
        let collectionID = try model.createCollection(name: "个人信息").get()
        let entryID = try model.addEntry(
            collectionID: collectionID,
            key: "邮箱",
            value: "old@example.com"
        ).get()

        try model.updateEntry(
            collectionID: collectionID,
            entryID: entryID,
            key: "联系邮箱",
            value: "new@example.com"
        ).get()
        XCTAssertEqual(model.selectedCollection?.entries.first?.id, entryID)
        XCTAssertEqual(model.selectedCollection?.entries.first?.key, "联系邮箱")

        let deleted = try XCTUnwrap(model.deleteEntry(
            collectionID: collectionID,
            entryID: entryID
        ))
        XCTAssertTrue(model.selectedCollection?.entries.isEmpty == true)
        XCTAssertTrue(model.restoreEntry(deleted))
        XCTAssertEqual(model.selectedCollection?.entries.first?.id, entryID)
    }

    @MainActor
    func testDeletingCollectionDoesNotAffectOtherCollectionsAndCanBeUndone() throws {
        let context = modelContext()
        defer { context.cleanup() }
        let model = context.model
        let firstID = try model.createCollection(name: "第一组").get()
        let secondID = try model.createCollection(name: "第二组").get()

        let deleted = try XCTUnwrap(model.deleteCollection(id: firstID))
        XCTAssertEqual(model.collections.map(\.id), [secondID])
        XCTAssertTrue(model.restoreCollection(deleted))
        XCTAssertEqual(model.collections.map(\.id), [firstID, secondID])
    }

    func testSearchRankingUsesCollectionThenKeyThenPrefixThenValue() {
        let base = Date(timeIntervalSince1970: 1_000)
        let exactCollection = QuickClipboardCollection(
            name: "token",
            createdAt: base,
            entries: [QuickClipboardEntry(key: "任意", value: "值", createdAt: base)]
        )
        let exactKey = QuickClipboardCollection(
            name: "开发",
            createdAt: base.addingTimeInterval(1),
            entries: [QuickClipboardEntry(key: "TOKEN", value: "exact", createdAt: base)]
        )
        let prefixKey = QuickClipboardCollection(
            name: "测试",
            createdAt: base.addingTimeInterval(2),
            entries: [QuickClipboardEntry(key: "token-url", value: "prefix", createdAt: base)]
        )
        let valueMatch = QuickClipboardCollection(
            name: "个人",
            createdAt: base.addingTimeInterval(3),
            entries: [QuickClipboardEntry(key: "密码", value: "my-token-value", createdAt: base)]
        )

        let results = quickClipboardSearch(
            query: "ToKeN",
            collections: [valueMatch, prefixKey, exactKey, exactCollection]
        )

        XCTAssertEqual(results.map(\.collectionID), [
            exactCollection.id,
            exactKey.id,
            prefixKey.id,
            valueMatch.id
        ])
        XCTAssertEqual(results[0].entries, exactCollection.entries)
    }

    func testSearchSupportsChineseSubstringAndWidthNormalization() {
        let collection = QuickClipboardCollection(
            name: "生产环境",
            entries: [
                QuickClipboardEntry(key: "ＡＰＩ 地址", value: "上海节点")
            ]
        )

        XCTAssertEqual(
            quickClipboardSearch(query: "api", collections: [collection])
                .first?.entries.first?.id,
            collection.entries.first?.id
        )
        XCTAssertEqual(
            quickClipboardSearch(query: "上海", collections: [collection])
                .first?.entries.first?.id,
            collection.entries.first?.id
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "QuickClipboardTests-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
    }

    @MainActor
    private func modelContext() -> ModelContext {
        let directory = temporaryDirectory()
        return ModelContext(
            model: QuickClipboardModel(
                storage: QuickClipboardStorage(directory: directory),
                now: { Date(timeIntervalSince1970: 1_700_000_000) }
            ),
            directory: directory
        )
    }
}

private struct ModelContext {
    let model: QuickClipboardModel
    let directory: URL

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}
