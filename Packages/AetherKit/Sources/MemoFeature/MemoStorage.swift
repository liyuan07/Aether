import Darwin
import Foundation

public enum MemoStorageError: LocalizedError {
    case unreadable, unsupportedVersion, writeFailed

    public var errorDescription: String? {
        switch self {
        case .unreadable: "无法读取备忘录，原文件已保留。请检查文件后重新打开 Aether。"
        case .unsupportedVersion: "备忘录来自较新版本，已停止写入以保留原数据。请更新 Aether。"
        case .writeFailed: "无法保存备忘录，请检查本机存储空间和文件权限。"
        }
    }
}

/// A versioned file prevents a damaged or newer user file from being replaced by an empty list.
public final class MemoStorage {
    private let directory: URL
    private let fileManager = FileManager.default
    private let lock = NSRecursiveLock()
    private var blocked = false
    private static let schemaVersion = 1

    private struct Envelope: Codable {
        var schemaVersion: Int
        var payload: [MemoItem]
    }

    private struct Version: Decodable { var schemaVersion: Int }

    public init(directory: URL) { self.directory = directory }

    public func load() throws -> [MemoItem] {
        lock.lock()
        defer { lock.unlock() }
        let file = directory.appendingPathComponent("items.json")
        do {
            if let type = try? fileManager.attributesOfItem(atPath: file.path)[.type],
               type as? FileAttributeType == .typeSymbolicLink {
                throw MemoStorageError.unreadable
            }
            guard fileManager.fileExists(atPath: file.path) else {
                blocked = false
                return []
            }
            let data = try Data(contentsOf: file)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            guard try decoder.decode(Version.self, from: data).schemaVersion == Self.schemaVersion else {
                throw MemoStorageError.unsupportedVersion
            }
            let items = try decoder.decode(Envelope.self, from: data).payload
            blocked = false
            return items
        } catch {
            blocked = true
            throw (error as? MemoStorageError) ?? MemoStorageError.unreadable
        }
    }

    public func save(_ items: [MemoItem]) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !blocked else { throw MemoStorageError.unreadable }
        _ = try load()
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporary) }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
            guard try fileManager.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType == .typeDirectory else {
                throw MemoStorageError.writeFailed
            }
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .millisecondsSince1970
            let data = try encoder.encode(Envelope(schemaVersion: Self.schemaVersion, payload: items))
            guard fileManager.createFile(atPath: temporary.path, contents: data,
                                         attributes: [.posixPermissions: 0o600]) else {
                throw MemoStorageError.writeFailed
            }
            let destination = directory.appendingPathComponent("items.json")
            guard rename(temporary.path, destination.path) == 0 else { throw MemoStorageError.writeFailed }
        } catch {
            throw MemoStorageError.writeFailed
        }
    }
}
