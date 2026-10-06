// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
import CAetherCore
@testable import PromptFeature

final class RustPromptParityTests: XCTestCase {
    func testResponsesMatchIndependentPreviousSwiftDecoder() throws {
        let contents: [Any] = [NSNull(), "", " 中文\u{0000}👨‍👩‍👧‍👦\n ", 1, [:],
            [], [["type": "text", "text": "甲"], ["type": "reasoning", "text": "乙"], ["type": "output_text", "text": "丙"]],
            [["type": "text", "text": NSNull()]], [["text": "missing type"]]]
        let reasons: [Any] = [NSNull(), "stop", "length", "content_filter", "tool_calls", "", 1]
        let refusals: [Any] = [NSNull(), "", "拒绝", 1]
        for content in contents {
            for reason in reasons {
                for refusal in refusals {
                    let choice: [String: Any] = ["message": ["content": content, "refusal": refusal], "finish_reason": reason]
                    for extra in [false, true] {
                        let choices: [Any] = extra ? [choice, ["message": 123]] : [choice]
                        let data = try JSONSerialization.data(withJSONObject: ["choices": choices])
                        XCTAssertEqual(outcome { try self.rustResponse(data) }, outcome { try self.referenceResponse(data) })
                    }
                }
            }
        }
    }

    func testHistoryPlansMatchPreviousNativeRules() {
        for seed in 0..<100 {
            let entries = (0..<40).map { index in
                PromptHistoryEntry(createdAt: Date(timeIntervalSinceReferenceDate: Double((index * 37 + seed * 13) % 11)),
                    original: "合成\(index)", optimized: "输出", model: "test")
            }
            XCTAssertEqual(promptHistoryPlan(entries, action: 0), entries.sorted { $0.createdAt > $1.createdAt })
            let id = entries[seed % entries.count].id
            XCTAssertEqual(promptHistoryPlan(entries, action: 1, id: id), entries.filter { $0.id != id })
            XCTAssertEqual(promptHistoryPlan(entries, action: 2, limit: seed), Array(entries.prefix(seed)))
            let match: (PromptHistoryEntry) -> Bool = { $0.original.localizedCaseInsensitiveContains(String(seed % 10)) }
            XCTAssertEqual(promptHistoryPlan(entries, action: 3, matching: match), entries.filter(match))
        }
    }

    func testRequestGenerationRejectsStaleOrRepeatedCompletions() {
        var gate = AetherPromptGate(generation: 0, active: 0, writable: 1, changed: 0)
        for _ in 0..<1000 {
            gate = aether_prompt_begin(gate)
            let old = gate.generation
            gate = aether_prompt_cancel(gate)
            XCTAssertEqual(aether_prompt_finish(gate, old, 1).changed, 0)
            gate = aether_prompt_begin(gate)
            XCTAssertEqual(aether_prompt_finish(gate, old, 1).changed, 0)
            XCTAssertEqual(aether_prompt_finish(gate, gate.generation, 0).changed, 0)
            gate = aether_prompt_finish(gate, gate.generation, 1)
            XCTAssertEqual(gate.changed, 1)
            XCTAssertEqual(aether_prompt_finish(gate, gate.generation, 1).changed, 0)
        }
    }

    private func rustResponse(_ data: Data) throws -> String {
        let text = try data.withUnsafeBytes { bytes in
            try promptCoreText(aether_prompt_response(200, AetherBytes(data: bytes.bindMemory(to: UInt8.self).baseAddress, length: bytes.count)))
        }.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw PromptClientError.emptyResponse }
        return text
    }
    private func referenceResponse(_ data: Data) throws -> String {
        guard let response = try? JSONDecoder().decode(PreviousChatResponse.self, from: data),
              let choice = response.choices.first else { throw PromptClientError.invalidResponse }
        if let reason = choice.finishReason {
            switch reason {
            case "stop": break
            case "content_filter": throw PromptClientError.refused
            default: throw PromptClientError.incompleteResponse
            }
        }
        guard choice.message.refusal?.isEmpty != false else { throw PromptClientError.refused }
        let text = choice.message.content?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { throw PromptClientError.emptyResponse }
        return text
    }
    private func outcome(_ operation: () throws -> String) -> String {
        do { return "success:" + (try operation()) }
        catch { return "error:" + String(describing: error) }
    }
}

// Independent copy of the pre-migration Swift response codec, used only as a test oracle.
private struct PreviousChatResponse: Decodable {
    struct Choice: Decodable {
        let message: Message
        let finishReason: String?
        enum CodingKeys: String, CodingKey { case message; case finishReason = "finish_reason" }
    }
    struct Message: Decodable { let content: Content?; let refusal: String? }
    enum Content: Decodable {
        case string(String)
        case parts([Part])

        struct Part: Decodable { let type: String; let text: String? }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self) { self = .string(string) }
            else { self = .parts(try container.decode([Part].self)) }
        }

        var text: String {
            switch self {
            case .string(let value): return value
            case .parts(let parts):
                return parts.filter { $0.type == "text" || $0.type == "output_text" }
                    .compactMap(\.text).joined(separator: "\n")
            }
        }
    }
    let choices: [Choice]
}
