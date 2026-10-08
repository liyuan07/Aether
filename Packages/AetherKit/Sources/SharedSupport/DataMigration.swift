// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CAetherCore

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
        try withoutActuallyEscaping(validate) { validate in
            try withoutActuallyEscaping(applyPreferences) { applyPreferences in
                let effects = MigrationEffects(migration: self, sources: sources, validate: validate, applyPreferences: applyPreferences)
                defer { effects.cleanup() }
                let status = aether_data_migration_run({ pointer, step, index in
                    Unmanaged<MigrationEffects>.fromOpaque(pointer!).takeUnretainedValue().perform(step, index: index)
                }, Unmanaged.passUnretained(effects).toOpaque())
                if let error = effects.error { throw error }
                guard status == 0, let result = effects.result else { throw MigrationError.invalidPreferences }
                return result
            }
        }
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

/// A per-call native effects context. Rust owns branch/iteration/commit order; this context is
/// never retained by the core. It preserves original errors and the existing version-one receipt.
private final class MigrationEffects {
    let migration: DataMigration
    let sources: [DataMigration.Source]
    let validate: (URL) throws -> Void
    let applyPreferences: (String, [String: Any]) throws -> Void
    var result: DataMigration.Receipt?
    var error: Error?
    var staging: URL?
    let fm = FileManager.default
    init(migration: DataMigration, sources: [DataMigration.Source], validate: @escaping (URL) throws -> Void,
         applyPreferences: @escaping (String, [String: Any]) throws -> Void) {
        self.migration = migration; self.sources = sources; self.validate = validate; self.applyPreferences = applyPreferences
    }
    func cleanup() { if let staging { try? fm.removeItem(at: staging) } }
    func perform(_ step: UInt8, index: Int) -> AetherMigrationEffectResult {
        do {
            var value = 0
            switch step {
            case 0:
                if let receipt = migration.receipt(), receipt.phase == "complete" { result = receipt; value = 1 }
            case 1:
                if let receipt = migration.receipt(), receipt.phase == "copied" { result = receipt; value = 1 }
            case 2:
                guard !fm.fileExists(atPath: migration.destination.path) else { throw DataMigration.MigrationError.existingDestination }
            case 3:
                let parent = migration.destination.deletingLastPathComponent()
                try fm.createDirectory(at: parent, withIntermediateDirectories: true)
                let root = parent.appendingPathComponent(".Aether-import-\(UUID().uuidString)")
                // Only remove a staging directory created successfully by this call.
                try fm.createDirectory(at: root, withIntermediateDirectories: true)
                staging = root
                try fm.createDirectory(at: root.appendingPathComponent("LegacyPreferences"), withIntermediateDirectories: true)
            case 4: value = sources.count
            case 5:
                let source = sources[index], root = staging!
                let target = root.appendingPathComponent(source.name, isDirectory: true)
                if let original = source.directory, fm.fileExists(atPath: original.path) {
                    try fm.copyItem(at: original, to: target)
                } else { try fm.createDirectory(at: target, withIntermediateDirectories: true) }
                try source.preferencesData.write(to: root.appendingPathComponent("LegacyPreferences").appendingPathComponent(source.name + ".plist"), options: .atomic)
            case 6: try validate(staging!)
            case 7:
                result = .init(phase: "copied", importedAt: Date(), sources: sources.map(\.name))
                try write(to: staging!)
            case 8: try fm.moveItem(at: staging!, to: migration.destination)
            case 9: try validate(migration.destination)
            case 10: value = result!.sources.count
            case 11:
                let source = result!.sources[index]
                let data = try Data(contentsOf: migration.destination.appendingPathComponent("LegacyPreferences/\(source).plist"))
                guard let values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                    throw DataMigration.MigrationError.invalidPreferences
                }
                try applyPreferences(source, values)
            case 12:
                result!.phase = "complete"
                try write(to: migration.destination)
            default: throw DataMigration.MigrationError.invalidPreferences
            }
            return .init(value: value, failed: 0)
        } catch { self.error = error; return .init(value: 0, failed: 1) }
    }
    private func write(to root: URL) throws {
        try JSONEncoder().encode(result!).write(to: root.appendingPathComponent("migration.json"), options: .atomic)
    }
}
