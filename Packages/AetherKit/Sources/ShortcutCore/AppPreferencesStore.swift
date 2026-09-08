import Foundation

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
        if FileManager.default.fileExists(atPath: fileURL.path) {
            sourceURL = fileURL
        } else if let legacyFileURL, FileManager.default.fileExists(atPath: legacyFileURL.path) {
            sourceURL = legacyFileURL
        } else {
            throw CocoaError(.fileNoSuchFile)
        }
        let data = try Data(contentsOf: sourceURL)
        let decoder = JSONDecoder()
        let storedSchemaVersion = (try? decoder.decode(SchemaVersion.self, from: data).schemaVersion) ?? 1
        let configuration = try decoder.decode(AppPreferencesConfiguration.self, from: data)
        if persistingMigrations,
           (sourceURL != fileURL || storedSchemaVersion < AppPreferencesConfiguration.currentSchemaVersion) {
            try save(configuration)
        }
        return configuration
    }

    public func save(_ configuration: AppPreferencesConfiguration, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(configuration).write(to: fileURL, options: .atomic)
    }

    private struct SchemaVersion: Decodable { let schemaVersion: Int }
}
