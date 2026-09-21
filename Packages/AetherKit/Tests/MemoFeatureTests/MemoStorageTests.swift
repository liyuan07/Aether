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
