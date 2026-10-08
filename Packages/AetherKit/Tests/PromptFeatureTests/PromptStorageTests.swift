import Foundation
import XCTest
@testable import PromptFeature

final class PromptStorageTests: XCTestCase {
    private var directory: URL!
    private var storage: PromptStorage!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("AetherPromptStorageTests-\(UUID())")
        storage = PromptStorage(directory: directory)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    func testMissingFilesLoadDefaultsWithoutCreatingUserData() throws {
        XCTAssertEqual(try storage.loadConfiguration(), PromptConfiguration())
        XCTAssertEqual(try storage.loadHistory(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testConfigurationAndHistoryRoundTripWithPrivatePermissions() throws {
        let configuration = PromptConfiguration(baseURL: "https://provider.example/v1", model: "test-model",
                                                systemPrompt: "合成测试规则", saveHistory: false, historyLimit: 50)
        let entries = [PromptHistoryEntry(createdAt: Date(timeIntervalSince1970: 123), original: "合成测试输入",
                                           optimized: "合成测试结果", model: "test-model")]
        try storage.saveConfiguration(configuration)
        try storage.saveHistory(entries)
        let reopened = PromptStorage(directory: directory)
        XCTAssertEqual(try reopened.loadConfiguration(), configuration)
        XCTAssertEqual(try reopened.loadHistory(), entries)
        for (path, expected) in [(directory!, 0o700), (file("configuration.json"), 0o600), (file("history.json"), 0o600)] {
            let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, expected)
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(Set(names), ["configuration.json", "history.json"])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file("configuration.json"))) as? [String: Any])
        XCTAssertEqual(json["schemaVersion"] as? Int, 1)
        let payload = try XCTUnwrap(json["payload"] as? [String: Any])
        XCTAssertEqual(Set(payload.keys), ["baseURL", "model", "systemPrompt", "saveHistory", "historyLimit"])
    }

    func testCorruptHistoryBlocksOverwriteEvenInNewStorageInstance() throws {
        let original = Data("{ corrupted synthetic history".utf8)
        try createFile("history.json", data: original)
        XCTAssertThrowsError(try storage.loadHistory())
        XCTAssertThrowsError(try storage.saveHistory([]))
        XCTAssertThrowsError(try PromptStorage(directory: directory).saveHistory([]))
        XCTAssertEqual(try Data(contentsOf: file("history.json")), original)
        // Separate configuration stays usable when history needs repair.
        try storage.saveConfiguration(.init())
    }

    func testFutureConfigurationBlocksSaveBeforeLoadAndPreservesBytes() throws {
        let original = Data("{\"schemaVersion\":99,\"payload\":{\"futureField\":\"synthetic\"}}".utf8)
        try createFile("configuration.json", data: original)
        XCTAssertThrowsError(try storage.saveConfiguration(.init()))
        XCTAssertEqual(try Data(contentsOf: file("configuration.json")), original)
        try storage.saveHistory([])
    }

    func testFutureHistoryIsPreserved() throws {
        let original = Data("{\"schemaVersion\":2,\"payload\":[]}".utf8)
        try createFile("history.json", data: original)
        XCTAssertThrowsError(try storage.loadHistory()) { error in
            guard case PromptStorageError.unsupportedVersion = error else { return XCTFail("Expected unsupported schema") }
        }
        XCTAssertThrowsError(try storage.saveHistory([]))
        XCTAssertEqual(try Data(contentsOf: file("history.json")), original)
    }

    func testExplicitReloadAfterRepairEnablesRetry() throws {
        try createFile("history.json", data: Data("invalid synthetic JSON".utf8))
        XCTAssertThrowsError(try storage.loadHistory())
        try Data("{\"schemaVersion\":1,\"payload\":[]}".utf8).write(to: file("history.json"))
        XCTAssertEqual(try storage.loadHistory(), [])
        let entry = PromptHistoryEntry(original: "合成输入", optimized: "合成输出", model: "test")
        try storage.saveHistory([entry])
        XCTAssertEqual(try storage.loadHistory(), [entry])
    }

    func testSaveChecksForNewerExternalFileAfterSuccessfulLoad() throws {
        try storage.saveHistory([])
        XCTAssertEqual(try storage.loadHistory(), [])
        let updated = Data("{\"schemaVersion\":90,\"payload\":[]}".utf8)
        try updated.write(to: file("history.json"))
        XCTAssertThrowsError(try storage.saveHistory([]))
        XCTAssertEqual(try Data(contentsOf: file("history.json")), updated)
    }

    func testInvalidConfigurationDoesNotReplaceSavedConfiguration() throws {
        try storage.saveConfiguration(.init())
        let original = try Data(contentsOf: file("configuration.json"))
        for invalidLimit in [0, -1, 1001] {
            var invalid = PromptConfiguration()
            invalid.historyLimit = invalidLimit
            XCTAssertThrowsError(try storage.saveConfiguration(invalid))
            XCTAssertEqual(try Data(contentsOf: file("configuration.json")), original)
        }
    }

    func testSymbolicLinkDoesNotRedirectHistoryWrites() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = file("external.json")
        let original = Data("{\"schemaVersion\":1,\"payload\":[]}".utf8)
        try original.write(to: target)
        try FileManager.default.createSymbolicLink(at: file("history.json"), withDestinationURL: target)
        XCTAssertThrowsError(try storage.saveHistory([]))
        XCTAssertEqual(try Data(contentsOf: target), original)
    }


    func testInvalidDateNeverSavesAPartialTypedHistory() throws {
        let original = PromptHistoryEntry(original: "synthetic source", optimized: "synthetic result", model: "test")
        try storage.saveHistory([original])
        let bytes = try Data(contentsOf: file("history.json"))
        for date in [Double.infinity, -Double.infinity, Double.nan] {
            let invalid = PromptHistoryEntry(createdAt: Date(timeIntervalSinceReferenceDate: date),
                original: "synthetic invalid", optimized: "synthetic result", model: "test")
            XCTAssertThrowsError(try storage.saveHistory([original, invalid]))
            XCTAssertEqual(try Data(contentsOf: file("history.json")), bytes)
        }
        XCTAssertEqual(try storage.loadHistory(), [original])
    }

    func testNativeVersionOneFixturesKeepDatePrecisionAndIntegralNumbers() throws {
        let dates = [-987654321.1234567, 0, 0.00000001, 812345678.9876543]
        let entries = dates.map { PromptHistoryEntry(createdAt: Date(timeIntervalSinceReferenceDate: $0),
            original: "合成\u{0000}👨‍👩‍👧‍👦\n", optimized: "输出", model: "test") }
        struct Envelope<T: Encodable>: Encodable { let schemaVersion = 1; let payload: T }
        try createFile("history.json", data: JSONEncoder().encode(Envelope(payload: entries)))
        XCTAssertEqual(try storage.loadHistory(), entries)
        try storage.saveHistory(entries)
        XCTAssertEqual(try PromptStorage(directory: directory).loadHistory(), entries)
        let configuration = try JSONEncoder().encode(Envelope(payload: PromptConfiguration()))
        let fixture = String(decoding: configuration, as: UTF8.self)
            .replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":1.0")
            .replacingOccurrences(of: "\"historyLimit\":200", with: "\"historyLimit\":2e2")
        XCTAssertTrue(fixture.contains("2e2"))
        try createFile("configuration.json", data: Data(fixture.utf8))
        XCTAssertEqual(try storage.loadConfiguration(), PromptConfiguration())
    }

    func testMalformedTypedPayloadsRemainProtected() throws {
        for payload in ["[{\"id\":\"bad-uuid\",\"createdAt\":0,\"original\":\"合成\",\"optimized\":\"输出\",\"model\":\"test\"}]", "[{\"id\":42}]", "{}", "null"] {
            let bytes = Data("{\"schemaVersion\":1,\"payload\":\(payload)}".utf8)
            try createFile("history.json", data: bytes)
            let reader = PromptStorage(directory: directory)
            XCTAssertThrowsError(try reader.loadHistory())
            XCTAssertThrowsError(try reader.saveHistory([]))
            XCTAssertEqual(try Data(contentsOf: file("history.json")), bytes)
        }
    }

    private func file(_ name: String) -> URL { directory.appendingPathComponent(name) }

    private func createFile(_ name: String, data: Data) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: file(name))
    }
}
