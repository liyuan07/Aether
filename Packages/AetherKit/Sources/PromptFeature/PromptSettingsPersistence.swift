// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit
import CAetherCore

func promptCredentialFingerprint(_ key: String) -> String {
    SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
}

struct PromptSettingsCommit {
    let configuration: PromptConfiguration
    let outcome: UInt32
    let message: String?
}

/// Native primitives only. Rust chooses ordering, skipping unchanged keys and rollback eligibility.
/// Context is confined to one synchronous commit; no credential bytes cross this policy ABI.
private final class PromptSettingsEffects {
    var configuration: PromptConfiguration
    let draftKey: String
    let storage: PromptStorage
    let credentials: any PromptCredentialStore
    var previousKey = ""
    var nextKey = ""
    var errors: [UInt8: String] = [:]

    init(configuration: PromptConfiguration, draftKey: String, storage: PromptStorage, credentials: any PromptCredentialStore) {
        self.configuration = configuration; self.draftKey = draftKey
        self.storage = storage; self.credentials = credentials
    }
    func perform(_ step: UInt8) -> UInt8 {
        do {
            switch step {
            case 0:
                previousKey = try credentials.load()
                nextKey = draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
                configuration.credentialFingerprint = promptCredentialFingerprint(nextKey)
                // Preserve native String equality, including canonical Unicode equivalence.
                return nextKey == previousKey ? 0 : 1
            case 1: try credentials.save(nextKey)
            case 2: try storage.saveConfiguration(configuration)
            case 3: try credentials.save(previousKey)
            default: return 1
            }
            return 0
        } catch {
            errors[step] = error.localizedDescription
            return 2
        }
    }
    func message(_ outcome: UInt32) -> String? {
        switch outcome {
        case 0: nil
        case 1: "优化指令不能为空，可以恢复默认指令。"
        case 2: "无法读取原 API Key，设置尚未保存，请重试。\(errors[0] ?? "")"
        case 3: "API Key 保存失败，设置尚未应用。\(errors[1] ?? "")"
        case 4: "设置保存失败，API Key 已保留原值，请重试。\(errors[2] ?? "")"
        default: "设置保存失败，且 API Key 无法恢复。已暂停优化，请重新保存完整设置。"
        }
    }
}

func promptCommitSettings(_ configuration: PromptConfiguration, draftKey: String, storage: PromptStorage,
                          credentials: any PromptCredentialStore) -> PromptSettingsCommit {
    let effects = PromptSettingsEffects(configuration: configuration, draftKey: draftKey, storage: storage, credentials: credentials)
    let valid = !configuration.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let outcome = withExtendedLifetime(effects) {
        aether_prompt_settings_commit(valid ? 1 : 0, { pointer, step in
            Unmanaged<PromptSettingsEffects>.fromOpaque(pointer!).takeUnretainedValue().perform(step)
        }, Unmanaged.passUnretained(effects).toOpaque())
    }
    return .init(configuration: effects.configuration, outcome: outcome, message: effects.message(outcome))
}
