import Foundation
import Security
import RustCore

public enum PromptStorageError: LocalizedError {
    case unreadable, unsupportedVersion, invalidConfiguration, writeFailed, keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .unreadable:
            return "无法读取提示词数据，原文件已保留。请检查文件后重新打开 Aether。"
        case .unsupportedVersion:
            return "提示词数据来自较新版本，已停止写入以保留原数据。请更新 Aether。"
        case .invalidConfiguration:
            return "历史记录上限应为 1 至 1000 条。"
        case .writeFailed:
            return "无法保存提示词数据，请检查本机存储空间和文件权限。"
        case .keychain:
            return "无法访问钥匙串中的 API Key，请检查钥匙串权限后重试。"
        }
    }
}

/// Each file is validated again before a write, including saves made before the first load.
/// A corrupt or newer-format file is never replaced with fallback defaults.
public final class PromptStorage {
    private let directory: URL
    private let lock = NSRecursiveLock()
    private var blockedFiles: Set<String> = []
    private static let schemaVersion = 1

    private struct Envelope<Value: Codable>: Codable {
        var schemaVersion: Int
        var payload: Value
    }

    private struct Version: Decodable { var schemaVersion: Int }

    public init(directory: URL) { self.directory = directory }

    public func loadConfiguration() throws -> PromptConfiguration {
        lock.lock()
        defer { lock.unlock() }
        let value: PromptConfiguration = try load("configuration.json", fallback: .init())
        guard (1...1000).contains(value.historyLimit) else {
            blockedFiles.insert("configuration.json")
            throw PromptStorageError.invalidConfiguration
        }
        return value
    }

    public func saveConfiguration(_ configuration: PromptConfiguration) throws {
        lock.lock()
        defer { lock.unlock() }
        guard (1...1000).contains(configuration.historyLimit) else {
            throw PromptStorageError.invalidConfiguration
        }
        try checkWritable("configuration.json")
        _ = try loadConfiguration()
        try save(configuration, name: "configuration.json")
    }

    public func loadHistory() throws -> [PromptHistoryEntry] {
        lock.lock()
        defer { lock.unlock() }
        return try load("history.json", fallback: [])
    }

    public func saveHistory(_ history: [PromptHistoryEntry]) throws {
        lock.lock()
        defer { lock.unlock() }
        try checkWritable("history.json")
        _ = try loadHistory()
        try save(history, name: "history.json")
    }

    private func checkWritable(_ name: String) throws {
        guard !blockedFiles.contains(name) else { throw PromptStorageError.unreadable }
    }

    private func load<Value: Codable>(_ name: String, fallback: Value) throws -> Value {
        do {
            let file = directory.appendingPathComponent(name)
            guard let data = try RustDisk.read(file) else {
                blockedFiles.remove(name)
                return fallback
            }
            let decoder = JSONDecoder()
            let version = try decoder.decode(Version.self, from: data).schemaVersion
            guard version == Self.schemaVersion else { throw PromptStorageError.unsupportedVersion }
            let value = try decoder.decode(Envelope<Value>.self, from: data).payload
            blockedFiles.remove(name)
            return value
        } catch {
            blockedFiles.insert(name)
            throw (error as? PromptStorageError) ?? PromptStorageError.unreadable
        }
    }

    private func save<Value: Codable>(_ value: Value, name: String) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(Envelope(schemaVersion: Self.schemaVersion, payload: value))
            try RustDisk.write(data, to: directory.appendingPathComponent(name), synchronize: true)
        } catch {
            throw PromptStorageError.writeFailed
        }
    }
}

public protocol PromptCredentialStore {
    func load() throws -> String
    /// An empty key removes this feature's stored credential.
    func save(_ key: String) throws
}

public final class KeychainPromptCredentialStore: PromptCredentialStore {
    private let service: String
    private let account: String

    public init(service: String = "com.liyuan.aether.prompt", account: String = "api-key") {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    public func load() throws -> String {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            throw PromptStorageError.keychain(status)
        }
        return key
    }

    public func save(_ key: String) throws {
        if key.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw PromptStorageError.keychain(status)
            }
            return
        }
        let attributes: [String: Any] = [kSecValueData as String: Data(key.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query.merging(attributes) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw PromptStorageError.keychain(addStatus) }
        } else if status != errSecSuccess {
            throw PromptStorageError.keychain(status)
        }
    }
}
