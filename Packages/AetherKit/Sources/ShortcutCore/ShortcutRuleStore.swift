import Foundation

public struct ShortcutRuleStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static func defaultStore(fileManager: FileManager = .default) -> ShortcutRuleStore {
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return ShortcutRuleStore(
            fileURL: baseURL
                .appendingPathComponent("ShortcutHelper", isDirectory: true)
                .appendingPathComponent("shortcuts.json")
        )
    }

    public func load() throws -> [ShortcutRule] {
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([ShortcutRule].self, from: data)
    }

    public func save(_ rules: [ShortcutRule], fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(rules)
        try data.write(to: fileURL, options: .atomic)
    }
}

