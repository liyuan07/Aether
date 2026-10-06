// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Explicit developer workload; never falls back to user data after a bad request.
public struct ResourceProfile: Sendable {
    public struct Manifest: Codable, Sendable {
        public let schemaVersion: Int
        public let id: UUID
        public let clipboardItems: Int
        public init(id: UUID, clipboardItems: Int) { schemaVersion = 1; self.id = id; self.clipboardItems = clipboardItems }
    }
    public let manifest: Manifest
    public let directory: URL
    public var dataRoot: URL { directory.appendingPathComponent("Data", isDirectory: true) }
    public var domainPrefix: String { "com.liyuan.aether.resource-profile." + manifest.id.uuidString.lowercased() }
    public enum Failure: Error { case invalidLocation, invalidManifest, symbolicLink }

    public static func load(path: String?) throws -> ResourceProfile? {
        guard let path else { return nil }
        guard path.hasPrefix("/"), !path.contains("\u{0000}") else { throw Failure.invalidLocation }
        let file = URL(fileURLWithPath: path).standardizedFileURL
        let directory = file.deletingLastPathComponent()
        guard file.lastPathComponent == "profile.json",
              directory.deletingLastPathComponent().lastPathComponent == "resource-profiles",
              directory.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == ".build" else { throw Failure.invalidLocation }
        for url in [file, directory, directory.deletingLastPathComponent(), directory.deletingLastPathComponent().deletingLastPathComponent()] {
            if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw Failure.symbolicLink }
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: file))
        guard manifest.schemaVersion == 1, (0...100_000).contains(manifest.clipboardItems),
              directory.lastPathComponent.lowercased() == manifest.id.uuidString.lowercased() else { throw Failure.invalidManifest }
        let profile = ResourceProfile(manifest: manifest, directory: directory)
        guard try profile.dataRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isDirectory == true else { throw Failure.invalidLocation }
        if let entries = FileManager.default.enumerator(at: profile.dataRoot, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            for case let url as URL in entries {
                if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw Failure.symbolicLink }
            }
        }
        if try profile.dataRoot.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw Failure.symbolicLink }
        return profile
    }
    public func preferences(feature: String) -> [String: Any] {
        switch feature {
        case "app": return ["launchAtLogin": false, "mirrorSystemTimer": false, "enableLockScreenTimerWidget": false]
        case "clipboard": return ["launchAtLogin": false, "shortcutEnabled": false, "monitoringEnabled": true,
                                  "historyLimit": max(5_000, manifest.clipboardItems), "expirationDays": 30]
        default: return [:]
        }
    }
    public func recordLaunch(processIdentifier: Int32) throws {
        let metadata: [String: Any] = ["schemaVersion": 1, "id": manifest.id.uuidString.lowercased(),
                                     "pid": processIdentifier, "clipboardItems": manifest.clipboardItems]
        try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]).write(
            to: directory.appendingPathComponent("runtime.json"), options: .atomic)
    }
}
