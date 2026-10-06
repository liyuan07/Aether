/*
 * Aether
 * Copyright (C) 2026 Li Yuan
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
import Foundation
import ImageIO

/// Supplemental import for installations whose original migration already finished.
enum BackgroundMigration {
    static let marker = "backgroundMigrationVersion"
    static let keys = ["backgroundFile", "backgroundMode", "backgroundFit", "backgroundAnchor", "backgroundOpacity"]

    static func run(preferences: [String: Any], source: URL, destination: URL, defaults: UserDefaults) throws {
        guard defaults.integer(forKey: marker) < 1 else { return }
        // Explicit Aether settings, including a deliberately removed image, always win.
        guard !keys.contains(where: { defaults.object(forKey: $0) != nil }) else {
            defaults.set(1, forKey: marker)
            return
        }
        let name = preferences["backgroundFile"] as? String ?? ""
        if !name.isEmpty {
            guard name == (name as NSString).lastPathComponent, !name.hasPrefix(".") else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let data = try Data(contentsOf: source.appendingPathComponent(name))
            guard let image = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetCount(image) == 1,
                  CGImageSourceCreateThumbnailAtIndex(image, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 64
                  ] as CFDictionary) != nil else { throw CocoaError(.fileReadCorruptFile) }
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let target = destination.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: target.path) {
                guard try Data(contentsOf: target) == data else { throw CocoaError(.fileWriteFileExists) }
            } else {
                try data.write(to: target, options: .atomic)
            }
        }
        // Commit preferences only after the managed image is safely in Aether.
        for key in keys {
            if let value = preferences[key] { defaults.set(value, forKey: key) }
        }
        defaults.set(1, forKey: marker)
        defaults.synchronize()
    }
}

extension ClipboardModule {
    nonisolated public static func migrateBackground(preferences: [String: Any], source: URL, destination: URL, defaults: UserDefaults) throws {
        try BackgroundMigration.run(preferences: preferences, source: source, destination: destination, defaults: defaults)
    }
}
