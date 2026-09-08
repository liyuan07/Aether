import Foundation

/// Versioned, one-way copy. The original stores are never opened for writing.
public struct DataMigration {
    public struct Source: Sendable {
        public let name: String
        public let directory: URL?
        public let preferencesData: Data
        public init(name: String, directory: URL?, preferences: [String: Any]) throws {
            self.name = name; self.directory = directory
            self.preferencesData = try PropertyListSerialization.data(fromPropertyList: preferences, format: .binary, options: 0)
        }
    }
    public struct Receipt: Codable, Sendable {
        public var version: Int = 1
        public var phase: String
        public var importedAt: Date
        public var sources: [String]
    }
    public let destination: URL
    public init(destination: URL) { self.destination = destination }

    public func receipt() -> Receipt? {
        guard let data = try? Data(contentsOf: destination.appendingPathComponent("migration.json")) else { return nil }
        return try? JSONDecoder().decode(Receipt.self, from: data)
    }

    /// A crash after the atomic directory move resumes preference application only.
    @discardableResult public func run(
        sources: [Source],
        validate: (URL) throws -> Void,
        applyPreferences: (String, [String: Any]) throws -> Void
    ) throws -> Receipt {
        if let receipt = receipt(), receipt.phase == "complete" { return receipt }
        let fm = FileManager.default
        var result: Receipt
        if let existing = receipt(), existing.phase == "copied" {
            result = existing
            try validate(destination)
        } else {
            guard !fm.fileExists(atPath: destination.path) else {
                throw MigrationError.existingDestination
            }
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let staging = destination.deletingLastPathComponent().appendingPathComponent(".Aether-import-\(UUID().uuidString)")
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: staging) }
            let preferencesDirectory = staging.appendingPathComponent("LegacyPreferences")
            try fm.createDirectory(at: preferencesDirectory, withIntermediateDirectories: true)
            for source in sources {
                let target = staging.appendingPathComponent(source.name, isDirectory: true)
                if let original = source.directory, fm.fileExists(atPath: original.path) {
                    try fm.copyItem(at: original, to: target)
                } else {
                    try fm.createDirectory(at: target, withIntermediateDirectories: true)
                }
                let data = source.preferencesData
                try data.write(to: preferencesDirectory.appendingPathComponent(source.name + ".plist"), options: .atomic)
            }
            try validate(staging)
            result = Receipt(phase: "copied", importedAt: Date(), sources: sources.map(\.name))
            try write(result, to: staging)
            try fm.moveItem(at: staging, to: destination)
        }
        for source in result.sources {
            let data = try Data(contentsOf: destination.appendingPathComponent("LegacyPreferences/\(source).plist"))
            guard let values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                throw MigrationError.invalidPreferences
            }
            try applyPreferences(source, values)
        }
        result.phase = "complete"
        try write(result, to: destination)
        return result
    }
    private func write(_ receipt: Receipt, to root: URL) throws {
        try JSONEncoder().encode(receipt).write(to: root.appendingPathComponent("migration.json"), options: .atomic)
    }
    public enum MigrationError: LocalizedError {
        case existingDestination, invalidPreferences
        public var errorDescription: String? {
            switch self {
            case .existingDestination: "Aether 数据目录已存在但缺少有效迁移记录。为保护数据，本次导入已停止。"
            case .invalidPreferences: "偏好快照无法读取，原数据未修改。"
            }
        }
    }
}
