// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
import RustCore

final class RustDiskTests: XCTestCase {
    func testPrivateAtomicRoundTripsOwnBytesAndLeaveNoTemporaryFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AetherRustDisk-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("合成 data.json")
        XCTAssertNil(try RustDisk.read(file))
        var snapshots: [Data] = []
        for size in [0, 1, 15, 16, 17, 256, 8192, 65536] {
            let data = Data((0..<size).map { UInt8($0 % 251) })
            try RustDisk.write(data, to: file, synchronize: true)
            let loaded = try XCTUnwrap(RustDisk.read(file))
            XCTAssertEqual(loaded, data)
            snapshots.append(loaded)
            XCTAssertEqual(loaded.subdata(in: 0..<min(size,32)), data.prefix(min(size,32)))
        }
        try RustDisk.write(Data([9]), to: file)
        XCTAssertEqual(snapshots.last?.count, 65536)
        XCTAssertEqual(snapshots.last?.first, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [file.lastPathComponent])
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }
    func testSymbolicLinkCannotRedirectPrivateReadOrWrite() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AetherRustDisk-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("target"), link = directory.appendingPathComponent("link")
        let original = Data([1,2,3])
        try original.write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try RustDisk.read(link))
        XCTAssertThrowsError(try RustDisk.write(Data([4]), to: link))
        XCTAssertEqual(try Data(contentsOf: target), original)
        XCTAssertEqual(try RustDisk.read(link, rejectSymbolicLinks: false), original)
    }
    func testFailedRenamePreservesDestinationAndCleansTemporaryFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AetherRustDisk-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("occupied")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let marker = destination.appendingPathComponent("marker")
        try Data([1]).write(to: marker)
        XCTAssertThrowsError(try RustDisk.write(Data([2]), to: destination))
        XCTAssertEqual(try Data(contentsOf: marker), Data([1]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["occupied"])
    }
}
