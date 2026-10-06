import Foundation
import RustCore
import CAetherCore

public struct AppPreferencesStore: Sendable {
    public let fileURL: URL
    public let legacyFileURL: URL?

    public init(fileURL: URL, legacyFileURL: URL? = nil) {
        self.fileURL = fileURL
        self.legacyFileURL = legacyFileURL
    }

    public static func defaultStore(fileManager: FileManager = .default) -> AppPreferencesStore {
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        let directory = baseURL.appendingPathComponent("ShortcutHelper", isDirectory: true)
        return AppPreferencesStore(
            fileURL: directory.appendingPathComponent("preferences.json"),
            legacyFileURL: directory.appendingPathComponent("input-automation.json")
        )
    }

    public func load(persistingMigrations: Bool = false) throws -> AppPreferencesConfiguration {
        let sourceURL: URL
        let currentExists = FileManager.default.fileExists(atPath: fileURL.path)
        let legacyExists = currentExists ? false : (legacyFileURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false)
        switch aether_preferences_source(currentExists ? 1 : 0, legacyExists ? 1 : 0) {
        case 0: sourceURL = fileURL
        case 1: sourceURL = legacyFileURL!
        default: throw CocoaError(.fileNoSuchFile)
        }
        guard let data = try RustDisk.read(sourceURL, rejectSymbolicLinks: false) else { throw CocoaError(.fileReadNoSuchFile) }
        let decoder = JSONDecoder()
        let storedSchemaVersion = (try? decoder.decode(SchemaVersion.self, from: data).schemaVersion) ?? Int(RustPreferences.defaults.stored_default)
        let configuration = try decoder.decode(AppPreferencesConfiguration.self, from: data)
        if aether_preferences_should_write(persistingMigrations ? 1 : 0,sourceURL != fileURL ? 1 : 0,Int64(storedSchemaVersion)) != 0 {
            try save(configuration)
        }
        return configuration
    }

    public func save(_ configuration: AppPreferencesConfiguration, fileManager: FileManager = .default) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try RustDisk.write(encoder.encode(configuration), to: fileURL, privateFile: false)
    }

    private struct SchemaVersion: Decodable { let schemaVersion: Int }
}
