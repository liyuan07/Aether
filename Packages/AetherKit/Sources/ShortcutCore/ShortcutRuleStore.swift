import Foundation
import RustCore

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
        guard let data = try RustDisk.read(fileURL, rejectSymbolicLinks: false) else { throw CocoaError(.fileReadNoSuchFile) }
        return try ShortcutRuleJSON.decode(data)
    }

    public func save(_ rules: [ShortcutRule], fileManager: FileManager = .default) throws {
        let data = try ShortcutRuleJSON.encode(rules)
        try RustDisk.write(data, to: fileURL, privateFile: false)
    }
}
