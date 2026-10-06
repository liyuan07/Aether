import Foundation
import Security
import RustCore
import CAetherCore

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
    private let lock = NSRecursiveLock()
    private let core: UnsafeMutableRawPointer?

    public init(directory: URL) {
        let fallback = (try? JSONEncoder().encode(PromptConfiguration())) ?? Data()
        core = directory.withUnsafeFileSystemRepresentation { directory in
            fallback.withUnsafeBytes { aether_prompt_store_create(directory, AetherBytes(data: $0.bindMemory(to: UInt8.self).baseAddress, length: $0.count)) }
        }
    }
    deinit { aether_prompt_store_destroy(core) }
    public func loadConfiguration() throws -> PromptConfiguration { try load(slot: 0) }
    public func saveConfiguration(_ configuration: PromptConfiguration) throws { try save(configuration, slot: 0) }
    public func loadHistory() throws -> [PromptHistoryEntry] { try load(slot: 1) }
    public func saveHistory(_ history: [PromptHistoryEntry]) throws { try save(history, slot: 1) }

    private func load<T: Decodable>(slot: UInt32) throws -> T {
        lock.lock(); defer { lock.unlock() }
        do {
            return try JSONDecoder().decode(T.self, from: RustBuffer.take(aether_prompt_store_load(core, slot)))
        } catch let error as RustDiskError {
            try check(error.status)
            throw PromptStorageError.unreadable
        } catch { throw PromptStorageError.unreadable }
    }
    private func save<T: Encodable>(_ value: T, slot: UInt32) throws {
        lock.lock(); defer { lock.unlock() }
        let data: Data
        do { data = try JSONEncoder().encode(value) } catch { throw PromptStorageError.writeFailed }
        try check(data.withUnsafeBytes { aether_prompt_store_save(core, slot, AetherBytes(data: $0.bindMemory(to: UInt8.self).baseAddress, length: $0.count)) })
    }
    private func check(_ status: UInt32) throws {
        switch status {
        case 0: return
        case 2: throw PromptStorageError.unreadable
        case 4: throw PromptStorageError.unsupportedVersion
        case 5: throw PromptStorageError.invalidConfiguration
        default: throw PromptStorageError.writeFailed
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
