// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import SharedSupport

final class ResourceProfileTests: XCTestCase {
    func testAbsentRequestAndValidIsolatedManifest() throws {
        XCTAssertNil(try ResourceProfile.load(path: nil))
        let context = try Context(); defer { context.cleanup() }
        let profile = try XCTUnwrap(ResourceProfile.load(path: context.file.path))
        XCTAssertEqual(profile.dataRoot, context.directory.appendingPathComponent("Data", isDirectory: true))
        XCTAssertTrue(profile.domainPrefix.hasPrefix("com.liyuan.aether.resource-profile."))
        XCTAssertEqual(profile.preferences(feature: "app")["mirrorSystemTimer"] as? Bool, false)
        XCTAssertEqual(profile.preferences(feature: "clipboard")["monitoringEnabled"] as? Bool, true)
        XCTAssertEqual(profile.preferences(feature: "clipboard")["historyLimit"] as? Int, 10_000)
        try profile.recordLaunch(processIdentifier: 1234)
        let runtime = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: context.directory.appendingPathComponent("runtime.json"))) as? [String: Any])
        XCTAssertEqual(runtime["pid"] as? Int, 1234)
        XCTAssertEqual(runtime["clipboardItems"] as? Int, 10_000)
    }
    func testInvalidRequestsCannotSelectUserStorage() throws {
        for path in ["", "relative/profile.json", "/tmp/profile.json", "/tmp/\u{0000}/profile.json"] {
            XCTAssertThrowsError(try ResourceProfile.load(path: path))
        }
        let context = try Context(); defer { context.cleanup() }
        for fixture: [String: Any] in [
            ["schemaVersion": 2, "id": context.id.uuidString, "clipboardItems": 0],
            ["schemaVersion": 1, "id": UUID().uuidString, "clipboardItems": 0],
            ["schemaVersion": 1, "id": context.id.uuidString, "clipboardItems": -1],
            ["schemaVersion": 1, "id": context.id.uuidString, "clipboardItems": 100_001]] {
            try JSONSerialization.data(withJSONObject: fixture).write(to: context.file)
            XCTAssertThrowsError(try ResourceProfile.load(path: context.file.path))
        }
    }
    func testSymbolicLinkInDataRootIsRejectedBeforeFeatureLoading() throws {
        let context = try Context(); defer { context.cleanup() }
        let outside = context.root.appendingPathComponent("outside")
        try Data("synthetic".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: context.directory.appendingPathComponent("Data/link"), withDestinationURL: outside)
        XCTAssertThrowsError(try ResourceProfile.load(path: context.file.path))
    }
    private struct Context {
        let id = UUID()
        let root: URL, directory: URL, file: URL
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("AetherProfileTests-" + UUID().uuidString).resolvingSymlinksInPath()
            directory = root.appendingPathComponent(".build/resource-profiles/" + id.uuidString.lowercased(), isDirectory: true)
            file = directory.appendingPathComponent("profile.json")
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("Data"), withIntermediateDirectories: true)
            try JSONEncoder().encode(ResourceProfile.Manifest(id: id, clipboardItems: 10_000)).write(to: file)
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }
}
