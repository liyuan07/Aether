// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import RustCore
import CAetherCore

func withPromptUTF8<T>(_ text: String, _ body: (AetherBytes) throws -> T) rethrows -> T {
    if let result = try text.utf8.withContiguousStorageIfAvailable({ try body(AetherBytes(data: $0.baseAddress, length: $0.count)) }) { return result }
    return try Array(text.utf8).withUnsafeBufferPointer { try body(AetherBytes(data: $0.baseAddress, length: $0.count)) }
}
func promptCoreData(_ handle: UnsafeMutableRawPointer?, httpStatus: Int = 0) throws -> Data {
    do { return try RustBuffer.take(handle) }
    catch let error as RustDiskError {
        switch error.status {
        case 100: throw PromptClientError.redirected
        case 101: throw PromptClientError.authentication
        case 102: throw PromptClientError.endpointUnavailable
        case 103: throw PromptClientError.timedOut
        case 104: throw PromptClientError.rateLimited
        case 105: throw PromptClientError.serverUnavailable
        case 106: throw PromptClientError.httpStatus(httpStatus)
        case 108: throw PromptClientError.incompleteResponse
        case 109: throw PromptClientError.refused
        case 111: throw PromptClientError.missingModel
        case 112: throw PromptClientError.missingRules
        case 114: throw PromptClientError.invalidURL
        case 115: throw PromptClientError.insecureURL
        default: throw PromptClientError.invalidResponse
        }
    }
}
func promptCoreText(_ handle: UnsafeMutableRawPointer?) throws -> String {
    guard let text = String(data: try promptCoreData(handle), encoding: .utf8) else { throw PromptClientError.invalidResponse }
    return text
}
func promptHistoryPlan(_ entries: [PromptHistoryEntry], action: UInt32, id: UUID? = nil, limit: Int = 0, matching: ((PromptHistoryEntry) -> Bool)? = nil) -> [PromptHistoryEntry] {
    let rows = entries.map { AetherHistoryRow(id: AetherUUID(bytes: $0.id.uuid), timestamp: $0.createdAt.timeIntervalSinceReferenceDate, matched: matching?($0) == false ? 0 : 1) }
    var output = Array(repeating: 0, count: entries.count)
    let count = rows.withUnsafeBufferPointer { rows in
        output.withUnsafeMutableBufferPointer { aether_prompt_history_plan(rows.baseAddress, rows.count, action, id.map { AetherUUID(bytes: $0.uuid) } ?? AetherUUID(), max(0,limit), $0.baseAddress, $0.count) }
    }
    return output.prefix(count).map { entries[$0] }
}
