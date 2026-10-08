import Foundation
import RustCore
import CAetherCore

public enum PromptStorageError: LocalizedError {
    case unreadable, unsupportedVersion, invalidConfiguration, writeFailed, credentialReadFailed, credentialWriteFailed

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
        case .credentialReadFailed:
            return "无法读取本机 API Key，请检查文件权限后重试。"
        case .credentialWriteFailed:
            return "无法保存本机 API Key，请检查存储空间和文件权限。"
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
    public func loadConfiguration() throws -> PromptConfiguration {
        try withDecoded(slot: 0) { decoded in
            let value = aether_prompt_decoded_configuration(decoded)
            return PromptConfiguration(baseURL: promptRecordText(value.base_url), model: promptRecordText(value.model),
                systemPrompt: promptRecordText(value.system_prompt), saveHistory: value.save_history != 0,
                historyLimit: Int(value.history_limit),
                credentialFingerprint: value.has_fingerprint == 0 ? nil : promptRecordText(value.credential_fingerprint))
        }
    }
    public func saveConfiguration(_ configuration: PromptConfiguration) throws { try save(configuration, slot: 0) }
    public func loadHistory() throws -> [PromptHistoryEntry] {
        try withDecoded(slot: 1) { decoded in
            try (0..<aether_prompt_decoded_count(decoded)).map { index in
                let value = aether_prompt_decoded_entry(decoded, index)
                guard let id = UUID(uuidString: promptRecordText(value.id)) else { throw PromptStorageError.unreadable }
                return PromptHistoryEntry(id: id, createdAt: Date(timeIntervalSinceReferenceDate: value.created_at),
                    original: promptRecordText(value.original), optimized: promptRecordText(value.optimized), model: promptRecordText(value.model))
            }
        }
    }
    public func saveHistory(_ history: [PromptHistoryEntry]) throws { try save(history, slot: 1) }

    private func withDecoded<T>(slot: UInt32, body: (UnsafeMutableRawPointer?) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        let decoded = aether_prompt_store_load_decoded(core, slot)
        defer { aether_prompt_decoded_destroy(decoded) }
        try check(aether_prompt_decoded_status(decoded))
        return try body(decoded)
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
    /// An empty key clears this feature's stored credential.
    func save(_ key: String) throws
}

/// Local private file storage; no Security/Keychain call can trigger a system password dialog.
public final class LocalPromptCredentialStore: PromptCredentialStore {
    private let file: URL
    public init(directory: URL) { file = directory.appendingPathComponent("api-key.txt") }
    public func load() throws -> String {
        do {
            guard let data = try RustDisk.read(file) else { return "" }
            guard let value = String(data: data, encoding: .utf8) else { throw PromptStorageError.credentialReadFailed }
            return value
        } catch { throw PromptStorageError.credentialReadFailed }
    }
    public func save(_ key: String) throws {
        do { try RustDisk.write(Data(key.utf8), to: file, privateFile: true, synchronize: true) }
        catch { throw PromptStorageError.credentialWriteFailed }
    }
}

private func promptRecordText(_ bytes: AetherBytes) -> String {
    guard bytes.length != 0, let data = bytes.data else { return "" }
    return String(decoding: UnsafeBufferPointer(start: data, count: bytes.length), as: UTF8.self)
}
