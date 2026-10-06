import Foundation
import XCTest
@testable import MemoFeature

final class MemoStorageTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("AetherMemoStorageTests-\(UUID())")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    @MainActor
    func testRustModelOrdersMutationsAndPreservesStateAfterFailure() throws {
        let storage = MemoStorage(directory: directory)
        let date = Date(timeIntervalSince1970: 100)
        let records = [MemoItem(title: "无截止时间", createdAt: date),
            MemoItem(title: "后截止", deadline: date.addingTimeInterval(20), createdAt: date),
            MemoItem(title: "先截止", deadline: date, createdAt: date),
            MemoItem(title: "同截止较早创建", deadline: date, createdAt: date.addingTimeInterval(-10))]
        try storage.save(records)
        let model = MemoModel(storage: storage)
        XCTAssertEqual(model.sortedItems.map(\.id), [records[3].id, records[2].id, records[1].id, records[0].id])
        XCTAssertFalse(model.add(title: " \n\t ", deadline: nil))
        XCTAssertTrue(model.add(title: "  合成新增  ", deadline: nil))
        XCTAssertEqual(model.items.last?.title, "合成新增")
        model.complete(records[2])
        XCTAssertFalse(model.items.contains { $0.id == records[2].id })
        let reopened = try MemoStorage(directory: directory).load()
        XCTAssertEqual(reopened, model.items)
        let previous = model.items
        let newer = Data("{\"schemaVersion\":99,\"payload\":[]}".utf8)
        try newer.write(to: directory.appendingPathComponent("items.json"))
        XCTAssertFalse(model.add(title: "不应写入", deadline: nil))
        XCTAssertEqual(model.items, previous)
        XCTAssertNotNil(model.storageMessage)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("items.json")), newer)
        try Data("{\"schemaVersion\":1,\"payload\":[]}".utf8).write(to: directory.appendingPathComponent("items.json"))
        model.reload()
        XCTAssertNil(model.storageMessage)
        XCTAssertTrue(model.add(title: "修复后重试", deadline: nil))
    }
    func testCorruptMissingRequiredFieldsAndLinksRemainUntouched() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("items.json")
        for invalid in ["{", "{\"schemaVersion\":1,\"payload\":[{\"id\":\"invalid\",\"title\":\"合成\",\"createdAt\":0}]}", "{\"schemaVersion\":1,\"payload\":[{}]}"] {
            let original = Data(invalid.utf8)
            try original.write(to: file)
            let storage = MemoStorage(directory: directory)
            XCTAssertThrowsError(try storage.save([]))
            XCTAssertEqual(try Data(contentsOf: file), original)
        }
        try FileManager.default.removeItem(at: file)
        let target = directory.appendingPathComponent("target")
        let original = Data("{\"schemaVersion\":1,\"payload\":[]}".utf8)
        try original.write(to: target)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        XCTAssertThrowsError(try MemoStorage(directory: directory).load())
        XCTAssertThrowsError(try MemoStorage(directory: directory).save([]))
        XCTAssertEqual(try Data(contentsOf: target), original)
    }

    func testRoundTripPreservesOptionalDeadline() throws {
        let storage = MemoStorage(directory: directory)
        let deadline = Date(timeIntervalSince1970: 1_700_000_000)
        let item = MemoItem(
            title: "合成待办",
            deadline: deadline,
            createdAt: Date(timeIntervalSince1970: 1_700_000_123.456)
        )

        try storage.save([item])

        XCTAssertEqual(try storage.load(), [item])
    }

    func testNewerFormatIsNotOverwritten() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("items.json")
        let newer = "{\"schemaVersion\": 999, \"payload\": []}".data(using: .utf8)!
        try newer.write(to: file)
        let storage = MemoStorage(directory: directory)

        XCTAssertThrowsError(try storage.load())
        XCTAssertThrowsError(try storage.save([]))
        XCTAssertEqual(try Data(contentsOf: file), newer)
    }

    func testLegacyFieldsAreIgnoredWithoutLosingTheTodo() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("items.json")
        let legacy = """
        {"schemaVersion":1,"payload":[{"id":"00000000-0000-0000-0000-000000000001","title":"合成待办","pomodoroCount":3,"deadline":1700000000000,"createdAt":1700000123456}]}
        """.data(using: .utf8)!
        try legacy.write(to: file)

        let items = try MemoStorage(directory: directory).load()

        XCTAssertEqual(items, [MemoItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            title: "合成待办",
            deadline: Date(timeIntervalSince1970: 1_700_000_000),
            createdAt: Date(timeIntervalSince1970: 1_700_000_123.456)
        )])
    }
}
