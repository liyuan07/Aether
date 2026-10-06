// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import PromptFeature

final class LocalPromptCredentialTests: XCTestCase {
    func testRoundTripPrivatePermissionsAndClearing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AetherLocalCredentialTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Prompt")
        let store = LocalPromptCredentialStore(directory: directory)
        XCTAssertEqual(try store.load(), "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        // Synthetic credential only; assertion failure never prints the string.
        let synthetic = "synthetic-local-credential-中文"
        try store.save(synthetic)
        XCTAssertTrue(try store.load() == synthetic)
        XCTAssertTrue(try LocalPromptCredentialStore(directory: directory).load() == synthetic)
        let file = directory.appendingPathComponent("api-key.txt")
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        let directoryPermissions = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        XCTAssertEqual(directoryPermissions?.intValue, 0o700)
        try store.save("")
        XCTAssertEqual(try Data(contentsOf: file).count, 0)
        XCTAssertEqual(try store.load(), "")
    }
    func testSymbolicLinkAndMalformedFileCannotBeReadAsCredential() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AetherLocalCredentialTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("api-key.txt")
        let target = root.appendingPathComponent("original")
        let bytes = Data([0xff,0xfe])
        try bytes.write(to: target)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        let store = LocalPromptCredentialStore(directory: root)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save("synthetic"))
        XCTAssertTrue(try Data(contentsOf: target) == bytes)
        try FileManager.default.removeItem(at: file)
        try bytes.write(to: file)
        XCTAssertThrowsError(try store.load())
        XCTAssertTrue(try Data(contentsOf: file) == bytes)
    }
}
