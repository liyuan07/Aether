/*
 * Clipboard
 * Copyright (C) 2026 Li Yuan
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
import AppKit
import XCTest
@testable import ClipboardFeature

final class BackgroundTests: XCTestCase {
    func testGeometryFitsDifferentScreensAndExtremeRatios() {
        for screen in [CGSize(width: 1440, height: 900), CGSize(width: 640, height: 400), CGSize(width: 2560, height: 1440)] {
            let base = CGSize(width: min(1000, screen.width * 0.94), height: min(700, screen.height * 0.94))
            for image in [CGSize(width: 1600, height: 900), CGSize(width: 900, height: 1600), CGSize(width: 1, height: 10000), CGSize(width: 10000, height: 1), CGSize(width: 1000, height: 1000)] {
                let size = BackgroundGeometry.windowSize(base: base, image: image, visible: screen)
                XCTAssertLessThanOrEqual(size.width, screen.width * 0.94)
                XCTAssertLessThanOrEqual(size.height, screen.height * 0.94)
                XCTAssertGreaterThanOrEqual(size.width, min(1_120, screen.width * 0.94))
                XCTAssertGreaterThanOrEqual(size.height, min(580, screen.height * 0.94))
            }
            XCTAssertEqual(BackgroundGeometry.windowSize(base: base, image: nil, visible: screen), base)
        }
    }
    func testFillContainStretchAndEveryAnchor() {
        let image = CGSize(width: 400, height: 200), container = CGSize(width: 300, height: 300)
        for anchor in BackgroundAnchor.allCases {
            let fill = BackgroundGeometry.imageRect(image: image, container: container, fit: .fill, anchor: anchor)
            XCTAssertEqual(fill.size, CGSize(width: 600, height: 300))
            XCTAssertEqual(fill.minX, -300 * anchor.fraction.x)
            let contain = BackgroundGeometry.imageRect(image: image, container: container, fit: .contain, anchor: anchor)
            XCTAssertEqual(contain.size, CGSize(width: 300, height: 150))
            XCTAssertEqual(contain.minY, 150 * anchor.fraction.y)
            XCTAssertEqual(BackgroundGeometry.imageRect(image: image, container: container, fit: .stretch, anchor: anchor), CGRect(origin: .zero, size: container))
        }
    }
    func testPreferencesRoundTripAndCorruptValues() {
        let suite = "BackgroundTests-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(BackgroundSettings(defaults: defaults), BackgroundSettings())
        var settings = BackgroundSettings()
        settings.fileName = "test.png"; settings.mode = .windowToImage; settings.fit = .contain; settings.anchor = .bottomRight
        for opacity in [0.0, 0.5, 1.0] {
            settings.opacity = opacity; settings.save(to: defaults)
            XCTAssertEqual(BackgroundSettings(defaults: defaults), settings)
        }
        defaults.set("../history.json", forKey: "backgroundFile")
        defaults.set("unknown", forKey: "backgroundMode")
        defaults.set(99, forKey: "backgroundAnchor")
        defaults.set(2.0, forKey: "backgroundOpacity")
        let restored = BackgroundSettings(defaults: defaults)
        XCTAssertEqual(restored.fileName, ""); XCTAssertEqual(restored.mode, .imageToWindow)
        XCTAssertEqual(restored.anchor, .center); XCTAssertEqual(restored.opacity, 1)
    }
    @MainActor
    func testImportPersistenceInvalidReplacementAndRemoval() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "BackgroundTests-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 120, pixelsHigh: 60, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let source = root.appendingPathComponent("source.png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: source)
        let directory = root.appendingPathComponent("Backgrounds")
        let manager = BackgroundManager(defaults: defaults, directory: directory)
        await manager.importImage(source)
        let imported = manager.settings.fileName
        XCTAssertFalse(imported.isEmpty)
        XCTAssertEqual(manager.payload?.size, CGSize(width: 120, height: 60))
        let cached = manager.payload?.image
        manager.settings.opacity = 0.5; manager.settings.anchor = .topLeft
        manager.loadIfNeeded()
        XCTAssertTrue(manager.payload?.image === cached)
        try FileManager.default.removeItem(at: source)
        let restored = BackgroundSettings(defaults: defaults)
        XCTAssertEqual(restored.fileName, imported)
        let decoded = try await ClipboardImageDecodeQueue.shared.background(from: directory.appendingPathComponent(imported), maxPixels: 100)
        XCTAssertEqual(decoded.size, CGSize(width: 120, height: 60))
        let invalid = root.appendingPathComponent("invalid.png")
        try Data("invalid".utf8).write(to: invalid)
        await manager.importImage(invalid)
        XCTAssertEqual(manager.settings.fileName, imported)
        XCTAssertTrue(manager.payload?.image === cached)
        XCTAssertNotNil(manager.error)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)
        // Background cleanup never touches history or payloads.
        let history = root.appendingPathComponent("history.json")
        try Data("sentinel".utf8).write(to: history)
        manager.removeImage()
        XCTAssertNil(manager.payload); XCTAssertTrue(manager.settings.fileName.isEmpty)
        await ClipboardImageDecodeQueue.shared.removeBackground(imported, directory: directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: history.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(imported).path))
    }
    @MainActor
    func testLatestImportWinsAndMissingImageFallsBack() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "BackgroundTests-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 100, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let source = root.appendingPathComponent("source.png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: source)
        let directory = root.appendingPathComponent("Backgrounds")
        let manager = BackgroundManager(defaults: defaults, directory: directory)
        let first = Task { await manager.importImage(source) }
        await Task.yield()
        let second = Task { await manager.importImage(source) }
        await first.value; await second.value
        XCTAssertFalse(manager.settings.fileName.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)
        let restored = BackgroundManager(defaults: defaults, directory: directory)
        restored.loadIfNeeded()
        for _ in 0..<100 where restored.payload == nil && restored.error == nil {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertNotNil(restored.payload)
        try FileManager.default.removeItem(at: directory.appendingPathComponent(manager.settings.fileName))
        let missing = BackgroundManager(defaults: defaults, directory: directory)
        missing.loadIfNeeded()
        for _ in 0..<100 where missing.error == nil {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertNil(missing.payload)
        XCTAssertNotNil(missing.error)
        XCTAssertEqual(missing.settings.fileName, manager.settings.fileName)
    }

    func testSupplementalMigrationRetriesPreservesExistingPreferencesAndOriginal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "BackgroundMigrationTests-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let source = root.appendingPathComponent("Legacy"), target = root.appendingPathComponent("Aether")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let preferences: [String: Any] = ["backgroundFile": "test.png", "backgroundMode": "windowToImage", "backgroundOpacity": 0.5]
        XCTAssertThrowsError(try BackgroundMigration.run(preferences: preferences, source: source, destination: target, defaults: defaults))
        XCTAssertNil(defaults.object(forKey: BackgroundMigration.marker))
        XCTAssertNil(defaults.object(forKey: "backgroundFile"))
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 20, pixelsHigh: 10, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let data = bitmap.representation(using: .png, properties: [:])!
        try data.write(to: source.appendingPathComponent("test.png"))
        try BackgroundMigration.run(preferences: preferences, source: source, destination: target, defaults: defaults)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("test.png")), data)
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("test.png")), data)
        XCTAssertEqual(BackgroundSettings(defaults: defaults).opacity, 0.5)
        defaults.set("", forKey: "backgroundFile")
        try BackgroundMigration.run(preferences: preferences, source: source, destination: target, defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: "backgroundFile"), "")
        defaults.removePersistentDomain(forName: suite)
        defaults.set(0.25, forKey: "backgroundOpacity")
        try BackgroundMigration.run(preferences: preferences, source: source, destination: target, defaults: defaults)
        XCTAssertEqual(defaults.double(forKey: "backgroundOpacity"), 0.25)
        XCTAssertNil(defaults.object(forKey: "backgroundFile"))
    }

}
