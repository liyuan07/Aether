// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit
import XCTest
@testable import PromptFeature

private struct SyntheticSettingsError: LocalizedError {
    var errorDescription: String? { "合成存储故障" }
}
private final class SettingsCredentials: PromptCredentialStore {
    var value = "synthetic-old"
    var failRead = false
    var failingWrites: Set<Int> = []
    var events: [String] = []
    var writes = 0
    func load() throws -> String {
        events.append("read")
        if failRead { throw SyntheticSettingsError() }
        return value
    }
    func save(_ key: String) throws {
        writes += 1; events.append("write-\(writes)")
        if failingWrites.contains(writes) { throw SyntheticSettingsError() }
        value = key
    }
}
private struct SettingsFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AetherPromptCommit-\(UUID())")
    var file: URL { directory.appendingPathComponent("configuration.json") }
    var storage: PromptStorage { PromptStorage(directory: directory) }
    func corrupt() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{ invalid synthetic configuration}".utf8).write(to: file)
    }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

final class PromptSettingsPersistenceTests: XCTestCase {
    /// Independent copy of the pre-migration transaction, including native equality and error wording.
    private func reference(_ input: PromptConfiguration, draftKey: String, storage: PromptStorage, credentials: SettingsCredentials) -> PromptSettingsCommit {
        var next = input
        func result(_ outcome: UInt32, _ message: String?) -> PromptSettingsCommit { .init(configuration: next, outcome: outcome, message: message) }
        guard !next.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return result(1, "优化指令不能为空，可以恢复默认指令。")
        }
        let previous: String
        do { previous = try credentials.load() }
        catch { return result(2, "无法读取原 API Key，设置尚未保存，请重试。\(error.localizedDescription)") }
        let key = draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
        next.credentialFingerprint = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        do { if key != previous { try credentials.save(key) } }
        catch { return result(3, "API Key 保存失败，设置尚未应用。\(error.localizedDescription)") }
        do { try storage.saveConfiguration(next) }
        catch {
            let configurationError = error.localizedDescription
            do {
                if key != previous { try credentials.save(previous) }
                return result(4, "设置保存失败，API Key 已保留原值，请重试。\(configurationError)")
            } catch {
                return result(5, "设置保存失败，且 API Key 无法恢复。已暂停优化，请重新保存完整设置。")
            }
        }
        return result(0, nil)
    }
    func testAllTransactionFailuresMatchIndependentNativeReference() throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        for mask in 0..<64 {
            let current = SettingsFixture(), legacy = SettingsFixture()
            defer { current.cleanup(); legacy.cleanup() }
            let a = SettingsCredentials(), b = SettingsCredentials()
            for credentials in [a,b] {
                credentials.failRead = mask & 2 != 0
                if mask & 4 != 0 { credentials.failingWrites.insert(1) }
                if mask & 8 != 0 { credentials.failingWrites.insert(2) }
            }
            if mask & 16 != 0 { try current.corrupt(); try legacy.corrupt() }
            let input = PromptConfiguration(baseURL: "https://synthetic.example/v1", model: "合成模型", systemPrompt: mask & 1 != 0 ? " \n\t" : "合成\u{0000}👩‍💻e\u{301}", historyLimit: 123)
            let key = mask & 32 != 0 ? " synthetic-new \n" : "synthetic-old"
            let actual = promptCommitSettings(input, draftKey: key, storage: current.storage, credentials: a)
            let expected = reference(input, draftKey: key, storage: legacy.storage, credentials: b)
            XCTAssertEqual(actual.outcome, expected.outcome, "failure mask \(mask)")
            XCTAssertEqual(actual.message, expected.message)
            XCTAssertEqual(try encoder.encode(actual.configuration), try encoder.encode(expected.configuration))
            XCTAssertEqual(a.events,b.events)
            XCTAssertTrue(a.value.utf8.elementsEqual(b.value.utf8))
            XCTAssertEqual(try? Data(contentsOf: current.file), try? Data(contentsOf: legacy.file))
        }
    }
    func testCanonicalEqualKeysSkipWriteWhilePreservingOriginalBytesAndFingerprintBehavior() throws {
        let fixture = SettingsFixture(); defer { fixture.cleanup() }
        let credentials = SettingsCredentials(); credentials.value = "synthetic-á"
        let key = "synthetic-a\u{301}"
        let result = promptCommitSettings(.init(), draftKey: " \(key) \n", storage: fixture.storage, credentials: credentials)
        XCTAssertEqual(result.outcome,0)
        XCTAssertEqual(credentials.events,["read"])
        XCTAssertTrue(credentials.value.utf8.elementsEqual("synthetic-á".utf8))
        let expected = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(result.configuration.credentialFingerprint,expected)
        XCTAssertNotEqual(expected,promptCredentialFingerprint(credentials.value))
        XCTAssertEqual(try fixture.storage.loadConfiguration(),result.configuration)
    }
    func testEmptyKeyClearsCredentialAndFailureRestoresItWithoutCreatingKeychainData() throws {
        let fixture = SettingsFixture(); defer { fixture.cleanup() }
        let credentials = LocalPromptCredentialStore(directory: fixture.directory)
        let synthetic = "synthetic-private-local"
        try credentials.save(synthetic)
        try fixture.corrupt()
        let failed = promptCommitSettings(.init(), draftKey: " \n", storage: fixture.storage, credentials: credentials)
        XCTAssertEqual(failed.outcome,4)
        XCTAssertTrue(try credentials.load().utf8.elementsEqual(synthetic.utf8))
        try FileManager.default.removeItem(at: fixture.file)
        let saved = promptCommitSettings(.init(), draftKey: " \n", storage: fixture.storage, credentials: credentials)
        XCTAssertEqual(saved.outcome,0)
        XCTAssertTrue(try credentials.load().isEmpty)
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.directory.appendingPathComponent("api-key.txt").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue,0o600)
    }
}
