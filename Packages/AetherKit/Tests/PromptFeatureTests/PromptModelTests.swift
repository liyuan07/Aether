import Foundation
import Testing
@testable import PromptFeature

private enum ModelTestError: Error { case failed }

private final class ModelTestCredentials: PromptCredentialStore {
    var value = "test-old-key"
    var failReads = false
    var saveCalls = 0
    var failingSaveCalls: Set<Int> = []
    func load() throws -> String {
        if failReads { throw ModelTestError.failed }
        return value
    }
    func save(_ key: String) throws {
        saveCalls += 1
        if failingSaveCalls.contains(saveCalls) { throw ModelTestError.failed }
        value = key
    }
}

private actor ModelTestClient: PromptOptimizing {
    struct Call { let input: String; let configuration: PromptConfiguration; let key: String }
    private(set) var calls: [Call] = []
    private var continuations: [CheckedContinuation<String, Error>?] = []

    func optimize(input: String, configuration: PromptConfiguration, apiKey: String) async throws -> String {
        calls.append(Call(input: input, configuration: configuration, key: apiKey))
        return try await withCheckedThrowingContinuation { continuations.append($0) }
    }
    func finish(_ result: Result<String, Error>, at index: Int = 0) {
        continuations[index]?.resume(with: result)
        continuations[index] = nil
    }
    func waitForCallCount(_ count: Int) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if calls.count >= count { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return false
    }
}

@MainActor
private func modelSettled(_ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(3)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return false
}

private func modelTestDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("PromptModelTests-\(UUID().uuidString)")
}

@MainActor
private func configuredModel(directory: URL, credentials: ModelTestCredentials, client: ModelTestClient) throws -> PromptModel {
    let storage = PromptStorage(directory: directory)
    try storage.saveConfiguration(PromptConfiguration(baseURL: "https://old.example/v1", model: "test-model"))
    let model = PromptModel(storage: storage, credentials: credentials, client: client)
    model.saveSettings() // Establish the same persisted credential binding as the real settings UI.
    return model
}

@Test @MainActor
func promptSuccessPersistsOriginalResultAndSupportsSearchWithoutEditingHistory() async throws {
    let directory = modelTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let client = ModelTestClient()
    let model = try configuredModel(directory: directory, credentials: ModelTestCredentials(), client: client)
    model.inputText = "  Synthetic source request  "
    model.optimize()
    try #require(await client.waitForCallCount(1))
    #expect(await client.calls.first?.input == "  Synthetic source request  ")
    await client.finish(.success("Structured synthetic result"))
    #expect(await modelSettled { !model.isOptimizing })
    #expect(model.outputText == "Structured synthetic result")
    #expect(model.history.count == 1)
    #expect(model.history.first?.original == "  Synthetic source request  ")
    model.outputText = "User edited result"
    #expect(try PromptStorage(directory: directory).loadHistory().first?.optimized == "Structured synthetic result")
    model.historyQuery = "STRUCTURED"
    #expect(model.filteredHistory.count == 1)
    model.historyQuery = "source"
    #expect(model.filteredHistory.count == 1)
    model.historyQuery = "no match"
    #expect(model.filteredHistory.isEmpty)
}

@Test @MainActor
func promptCancellationAndNewDraftIgnoreLateNetworkSuccess() async throws {
    let directory = modelTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let client = ModelTestClient()
    let model = try configuredModel(directory: directory, credentials: ModelTestCredentials(), client: client)
    model.inputText = "Synthetic original"
    model.optimize()
    try #require(await client.waitForCallCount(1))
    model.newPrompt()
    model.inputText = "A newer draft"
    await client.finish(.success("Late response"))
    for _ in 0..<20 { await Task.yield() }
    #expect(!model.isOptimizing)
    #expect(model.inputText == "A newer draft")
    #expect(model.outputText.isEmpty)
    #expect(model.history.isEmpty)
}

@Test @MainActor
func promptHistorySelectionCancelsRequestAndReuseKeepsSavedRecord() async throws {
    let directory = modelTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let existing = PromptHistoryEntry(original: "Saved source", optimized: "Saved result", model: "earlier-model")
    try PromptStorage(directory: directory).saveHistory([existing])
    let client = ModelTestClient()
    let model = try configuredModel(directory: directory, credentials: ModelTestCredentials(), client: client)
    model.inputText = "Active request"
    model.optimize()
    try #require(await client.waitForCallCount(1))
    model.selectHistory(existing.id)
    await client.finish(.success("Late response"))
    for _ in 0..<20 { await Task.yield() }
    #expect(model.outputText == "Saved result")
    #expect(model.inputText == "Saved source")
    #expect(model.selectedHistoryID == existing.id)
    model.reuseHistory(existing)
    #expect(model.inputText == existing.original)
    #expect(model.outputText.isEmpty)
    #expect(model.selectedHistoryID == nil)
    #expect(try PromptStorage(directory: directory).loadHistory() == [existing])
}

@Test @MainActor
func promptFailureRetainsResultAndHistoryPreferenceAppliesBeforeCompletion() async throws {
    let directory = modelTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let client = ModelTestClient()
    let model = try configuredModel(directory: directory, credentials: ModelTestCredentials(), client: client)
    model.outputText = "Retained result"
    model.inputText = "Synthetic request"
    model.optimize()
    try #require(await client.waitForCallCount(1))
    await client.finish(.failure(ModelTestError.failed))
    #expect(await modelSettled { !model.isOptimizing })
    #expect(model.outputText == "Retained result")
    #expect(model.optimizationError != nil)
    #expect(model.history.isEmpty)
    model.optimize()
    try #require(await client.waitForCallCount(2))
    model.draftConfiguration.saveHistory = false
    model.saveSettings()
    await client.finish(.success("New result without history"), at: 1)
    #expect(await modelSettled { !model.isOptimizing })
    #expect(model.outputText == "New result without history")
    #expect(model.history.isEmpty)
    #expect(try PromptStorage(directory: directory).loadHistory().isEmpty)
}

@Test @MainActor
func promptPartialSettingsFailureRestoresCredentialForOldEndpoint() async throws {
    let directory = modelTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let credentials = ModelTestCredentials()
    let client = ModelTestClient()
    let model = try configuredModel(directory: directory, credentials: credentials, client: client)
    try Data("invalid configuration".utf8).write(to: directory.appendingPathComponent("configuration.json"))
    model.draftConfiguration.baseURL = "https://new.example/v1"
    model.draftAPIKey = "test-new-key"
    model.saveSettings()
    #expect(model.settingsSaveFailed)
    #expect(credentials.value == "test-old-key")
    #expect(model.configuration.baseURL == "https://old.example/v1")
    model.inputText = "Synthetic request"
    model.optimize()
    try #require(await client.waitForCallCount(1))
    let calls = await client.calls
    #expect(calls.first?.key == "test-old-key")
    #expect(calls.first?.configuration.baseURL == "https://old.example/v1")
    await client.finish(.success("Synthetic result"))
    #expect(await modelSettled { !model.isOptimizing })
}

@Test @MainActor
func promptCredentialMismatchRemainsBlockedAcrossModelReload() async throws {
    let directory = modelTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let credentials = ModelTestCredentials()
    let client = ModelTestClient()
    let model = try configuredModel(directory: directory, credentials: credentials, client: client)
    // Reproduce a credential update whose paired configuration update did not complete.
    credentials.value = "unpaired-new-key"
    let reloaded = PromptModel(storage: PromptStorage(directory: directory), credentials: credentials, client: client)
    reloaded.inputText = "Synthetic request"
    reloaded.optimize()
    #expect(reloaded.credentialInconsistent)
    #expect(reloaded.optimizationError != nil)
    #expect(!reloaded.isOptimizing)
    #expect(await client.calls.isEmpty)
    reloaded.saveSettings()
    #expect(!reloaded.credentialInconsistent)
    reloaded.optimize()
    try #require(await client.waitForCallCount(1))
    await client.finish(.success("Synthetic result"))
    #expect(await modelSettled { !reloaded.isOptimizing })
    _ = model
}

@Test @MainActor
func promptHistoryWriteFailureKeepsResultAndCanRetryAfterFileRepair() async throws {
    let directory = modelTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let client = ModelTestClient()
    let model = try configuredModel(directory: directory, credentials: ModelTestCredentials(), client: client)
    let historyURL = directory.appendingPathComponent("history.json")
    try Data("invalid history".utf8).write(to: historyURL)
    model.inputText = "Synthetic request"
    model.optimize()
    try #require(await client.waitForCallCount(1))
    await client.finish(.success("Recoverable result"))
    #expect(await modelSettled { !model.isOptimizing })
    #expect(model.outputText == "Recoverable result")
    #expect(model.historyMessage != nil)
    #expect(try String(contentsOf: historyURL, encoding: .utf8) == "invalid history")
    try FileManager.default.removeItem(at: historyURL)
    model.retryHistoryStorage()
    #expect(model.historyMessage == nil)
    #expect(try PromptStorage(directory: directory).loadHistory().first?.optimized == "Recoverable result")
}

@Test @MainActor
func promptHistoryLimitAndDeletionPersistWithoutChangingDisplayedText() throws {
    let directory = modelTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let entries = (0..<3).map {
        PromptHistoryEntry(createdAt: Date(timeIntervalSince1970: Double($0)), original: "Source \($0)", optimized: "Result \($0)", model: "test")
    }
    try PromptStorage(directory: directory).saveHistory(entries)
    let model = try configuredModel(directory: directory, credentials: ModelTestCredentials(), client: ModelTestClient())
    model.draftConfiguration.historyLimit = 2
    model.saveSettings()
    #expect(model.history.map(\.id) == [entries[2].id, entries[1].id])
    model.selectHistory(entries[2].id)
    model.deleteHistory(entries[2])
    #expect(model.outputText == "Result 2")
    #expect(model.history.count == 1)
    model.clearHistory()
    #expect(try PromptStorage(directory: directory).loadHistory().isEmpty)
    #expect(model.outputText == "Result 2")
}

@Test @MainActor
func promptRollbackFailureRemainsBlockedUntilRepairedConfigurationIsCompletelySaved() async throws {
    let directory = modelTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let credentials = ModelTestCredentials(), client = ModelTestClient()
    let model = try configuredModel(directory: directory, credentials: credentials, client: client)
    let file = directory.appendingPathComponent("configuration.json")
    let original = try Data(contentsOf: file)
    let corrupt = Data("{ invalid synthetic configuration}".utf8)
    try corrupt.write(to: file)
    model.outputText = "Retained synthetic output"
    model.draftConfiguration.baseURL = "https://new.example/v1"
    model.draftAPIKey = "test-new-key"
    credentials.failingSaveCalls = [2]
    model.saveSettings()
    #expect(model.settingsSaveFailed)
    #expect(model.credentialInconsistent)
    #expect(model.configuration.baseURL == "https://old.example/v1")
    #expect(model.outputText == "Retained synthetic output")
    #expect(try Data(contentsOf: file) == corrupt)
    model.inputText = "Synthetic request"
    model.optimize()
    #expect(!model.isOptimizing)
    #expect(await client.calls.isEmpty)
    try original.write(to: file)
    model.reloadConfiguration()
    #expect(model.credentialInconsistent)
    model.draftConfiguration.baseURL = "https://new.example/v1"
    model.saveSettings()
    #expect(!model.settingsSaveFailed)
    #expect(!model.credentialInconsistent)
    #expect(model.configuration.baseURL == "https://new.example/v1")
    model.optimize()
    try #require(await client.waitForCallCount(1))
    let calls = await client.calls
    #expect(calls.first?.key == "test-new-key")
    #expect(calls.first?.configuration.baseURL == "https://new.example/v1")
    await client.finish(.success("Synthetic result"))
    #expect(await modelSettled { !model.isOptimizing })
}

@Test @MainActor
func promptReadAndKeyWriteFailuresRetainPublishedConfiguration() throws {
    let directory = modelTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let credentials = ModelTestCredentials()
    let model = try configuredModel(directory: directory, credentials: credentials, client: ModelTestClient())
    let file = directory.appendingPathComponent("configuration.json")
    let original = try Data(contentsOf: file)
    model.draftConfiguration.baseURL = "https://new.example/v1"
    model.draftAPIKey = "test-new-key"
    credentials.failReads = true
    model.saveSettings()
    #expect(model.settingsSaveFailed)
    #expect(model.configuration.baseURL == "https://old.example/v1")
    #expect(try Data(contentsOf: file) == original)
    #expect(credentials.saveCalls == 0)
    credentials.failReads = false
    credentials.failingSaveCalls = [1]
    model.saveSettings()
    #expect(model.settingsSaveFailed)
    #expect(!model.credentialInconsistent)
    #expect(model.configuration.baseURL == "https://old.example/v1")
    #expect(credentials.value == "test-old-key")
    #expect(try Data(contentsOf: file) == original)
}
