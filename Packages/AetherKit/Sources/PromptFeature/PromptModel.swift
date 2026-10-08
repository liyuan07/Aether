import AppKit
import Combine
import Foundation
import SharedSupport
import CAetherCore

@MainActor
final class PromptModel: ObservableObject {
    @Published var inputText = ""
    @Published var outputText = ""
    @Published var historyQuery = ""
    @Published var draftConfiguration = PromptConfiguration() { didSet { settingsMessage = nil } }
    @Published var draftAPIKey = "" { didSet { settingsMessage = nil } }
    @Published private(set) var configuration = PromptConfiguration()
    @Published private(set) var history: [PromptHistoryEntry] = []
    @Published private(set) var selectedHistoryID: UUID?
    @Published private(set) var isOptimizing = false
    @Published private(set) var optimizationError: String?
    @Published private(set) var historyMessage: String?
    @Published private(set) var settingsMessage: String?
    @Published private(set) var settingsSaveFailed = false
    @Published private(set) var configurationLoadError: String?
    @Published private(set) var credentialInconsistent = false
    @Published private(set) var outputOriginal = ""

    private let storage: PromptStorage
    private let credentials: any PromptCredentialStore
    private let client: any PromptOptimizing
    private var request: Task<Void, Never>?
    private var core = AetherPromptGate(generation: 0, active: 0, writable: 1, changed: 0)
    private var pendingHistoryWrite: [PromptHistoryEntry]?

    init(
        storage: PromptStorage? = nil,
        credentials: any PromptCredentialStore = LocalPromptCredentialStore(directory: AppEnvironment.directory("Prompt")),
        client: any PromptOptimizing = PromptClient()
    ) {
        self.storage = storage ?? PromptStorage(directory: AppEnvironment.directory("Prompt"))
        self.credentials = credentials
        self.client = client
        do {
            configuration = try self.storage.loadConfiguration()
            draftConfiguration = configuration
        } catch {
            configurationLoadError = "无法读取 Prompt 设置，原文件已保留。\(error.localizedDescription)"
        }
        do { draftAPIKey = try credentials.load() }
        catch {
            settingsMessage = "无法读取 API Key，请重新填写后保存。\(error.localizedDescription)"
            settingsSaveFailed = true
        }
        reloadHistory()
    }

    var filteredHistory: [PromptHistoryEntry] {
        let query = historyQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return history }
        return promptHistoryPlan(history, action: 3, matching: {
            $0.original.localizedCaseInsensitiveContains(query) || $0.optimized.localizedCaseInsensitiveContains(query)
        })
    }

    var isConfigured: Bool {
        !configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canOptimize: Bool { !isOptimizing && !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var selectedHistory: PromptHistoryEntry? { history.first { $0.id == selectedHistoryID } }

    func saveSettings() {
        var next = draftConfiguration
        next.baseURL = next.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        next.model = next.model.trimmingCharacters(in: .whitespacesAndNewlines)
        next.historyLimit = aether_prompt_limit(next.historyLimit)
        let committed = promptCommitSettings(next, draftKey: draftAPIKey, storage: storage, credentials: credentials)
        guard committed.outcome == 0 else {
            settingsMessage = committed.message
            settingsSaveFailed = true
            if committed.outcome == 5 { credentialInconsistent = true }
            return
        }
        next = committed.configuration
        configuration = next
        draftConfiguration = next
        configurationLoadError = nil
        settingsMessage = "设置已保存。"
        settingsSaveFailed = false
        credentialInconsistent = false
        let currentHistory = pendingHistoryWrite ?? history
        if aether_prompt_settings_trim_required(next.saveHistory ? 1 : 0, currentHistory.count, next.historyLimit) != 0 {
            if !persistHistory(promptHistoryPlan(currentHistory, action: 2, limit: next.historyLimit)) {
                settingsMessage = "设置已保存，但超额历史尚未清理，请在工具窗口重试历史存储。"
                settingsSaveFailed = true
            }
        }
    }

    func restoreDefaultInstruction() { draftConfiguration.systemPrompt = PromptConfiguration.defaultSystemPrompt }

    func reloadConfiguration() {
        do {
            configuration = try storage.loadConfiguration()
            draftConfiguration = configuration
            configurationLoadError = nil
        } catch {
            configurationLoadError = "无法读取 Prompt 设置，原文件已保留。\(error.localizedDescription)"
        }
    }

    func retryHistoryStorage() {
        if let pending = pendingHistoryWrite {
            do {
                _ = try storage.loadHistory()
                core = aether_prompt_history_writable(core, 1)
                persistHistory(pending)
            } catch {
                core = aether_prompt_history_writable(core, 0)
                historyMessage = "无法读取历史文件，原数据和待保存记录已保留。\(error.localizedDescription)"
            }
        } else { reloadHistory() }
    }

    private func reloadHistory() {
        do {
            history = promptHistoryPlan(try storage.loadHistory(), action: 0)
            core = aether_prompt_history_writable(core, 1)
            historyMessage = nil
        } catch {
            core = aether_prompt_history_writable(core, 0)
            historyMessage = "无法读取历史文件，已暂停历史写入以保留原数据。\(error.localizedDescription)"
        }
    }

    func optimize() {
        guard canOptimize else { return }
        guard !credentialInconsistent else {
            optimizationError = "API Key 与服务设置尚未一致保存，请前往设置重新保存后再试。"
            return
        }
        guard isConfigured else {
            optimizationError = "请先在设置中填写 Base URL 和模型名称并保存。"
            return
        }
        let apiKey: String
        do { apiKey = try credentials.load() }
        catch {
            optimizationError = "无法读取 API Key，请在设置中重新保存。\(error.localizedDescription)"
            return
        }
        if aether_prompt_credential_consistent(configuration.credentialFingerprint == nil ? 0 : 1, apiKey.isEmpty ? 1 : 0,
            configuration.credentialFingerprint == promptCredentialFingerprint(apiKey) ? 1 : 0) == 0 {
            credentialInconsistent = true
            optimizationError = "API Key 与服务设置不匹配，请前往设置重新保存后再试。"
            return
        }
        let original = inputText
        let snapshot = configuration
        core = aether_prompt_begin(core)
        let id = core.generation
        isOptimizing = true
        optimizationError = nil
        selectedHistoryID = nil
        // The previous result remains available if this request fails or is cancelled.
        request = Task { [weak self, client] in
            do {
                let result = try await client.optimize(input: original, configuration: snapshot, apiKey: apiKey)
                guard let self, self.finishCoreRequest(id, acceptable: !Task.isCancelled) else { return }
                self.outputText = result
                self.outputOriginal = original
                self.isOptimizing = false
                self.request = nil
                // Respect the current privacy preference even if it changed during the request.
                if self.configuration.saveHistory {
                    let entry = PromptHistoryEntry(original: original, optimized: result, model: snapshot.model)
                    self.selectedHistoryID = entry.id
                    self.persistHistory(promptHistoryPlan([entry] + (self.pendingHistoryWrite ?? self.history), action: 2, limit: self.configuration.historyLimit))
                }
            } catch {
                guard let self, self.finishCoreRequest(id, acceptable: true) else { return }
                self.isOptimizing = false
                self.request = nil
                if !(error is CancellationError) { self.optimizationError = error.localizedDescription }
            }
        }
    }

    func cancelOptimization() {
        core = aether_prompt_cancel(core)
        request?.cancel()
        request = nil
        isOptimizing = false
    }

    func newPrompt() {
        cancelOptimization()
        selectedHistoryID = nil
        inputText = ""
        outputText = ""
        outputOriginal = ""
        optimizationError = nil
    }

    func selectHistory(_ id: UUID?) {
        guard let id, let entry = history.first(where: { $0.id == id }) else { return }
        cancelOptimization()
        selectedHistoryID = id
        inputText = entry.original
        outputText = entry.optimized
        outputOriginal = entry.original
        optimizationError = nil
    }

    func reuseHistory(_ entry: PromptHistoryEntry) {
        newPrompt()
        inputText = entry.original
    }

    func deleteHistory(_ entry: PromptHistoryEntry) {
        let remaining = promptHistoryPlan(pendingHistoryWrite ?? history, action: 1, id: entry.id)
        if persistHistory(remaining), selectedHistoryID == entry.id { selectedHistoryID = nil }
    }

    func clearHistory() {
        if persistHistory([]) { selectedHistoryID = nil }
    }

    func pasteInput() {
        guard !isOptimizing else { return }
        guard let text = AppEnvironment.clipboardPasteboard.string(forType: .string), !text.isEmpty else {
            optimizationError = "剪贴板中没有可粘贴的文本。"
            return
        }
        inputText = text
        selectedHistoryID = nil
        optimizationError = nil
    }

    func copyOutput() {
        guard !outputText.isEmpty else { return }
        AppEnvironment.clipboardPasteboard.clearContents()
        AppEnvironment.clipboardPasteboard.setString(outputText, forType: .string)
    }

    @discardableResult
    private func persistHistory(_ next: [PromptHistoryEntry]) -> Bool {
        guard core.writable != 0 else { return false }
        do {
            try storage.saveHistory(next)
            history = next
            pendingHistoryWrite = nil
            historyMessage = nil
            return true
        } catch {
            pendingHistoryWrite = next
            historyMessage = "历史保存失败，当前优化结果仍可复制。\(error.localizedDescription)"
            return false
        }
    }

    private func finishCoreRequest(_ token: UInt64, acceptable: Bool) -> Bool {
        core = aether_prompt_finish(core, token, acceptable ? 1 : 0)
        return core.changed != 0
    }


}
