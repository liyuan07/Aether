// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CAetherCore

extension ClipboardItemType {
    var rustKind: UInt8 {
        switch self {
        case .text: 0
        case .url: 1
        case .file: 2
        case .image: 3
        case .rtf: 4
        case .unknown: 5
        }
    }
}

func rustClipboardContentMatches(_ lhs: ClipboardItem, _ rhs: ClipboardItem) -> Bool {
    var flags: UInt8 = lhs.imageContentHash != nil && rhs.imageContentHash != nil ? 2 : 0
    let fields = aether_clipboard_content_fields(lhs.type.rustKind, rhs.type.rustKind, flags & 2)
    guard fields != 0 else { return false }
    // Preserve native String canonical equivalence and optional array/Data equality.
    if fields & 1 != 0, lhs.stringData == rhs.stringData { flags |= 1 }
    if fields & 4 != 0, lhs.imageContentHash == rhs.imageContentHash { flags |= 4 }
    if fields & 8 != 0, lhs.imageFileName == rhs.imageFileName { flags |= 8 }
    if fields & 16 != 0, lhs.fileURLs == rhs.fileURLs { flags |= 16 }
    let result = aether_clipboard_content_match(lhs.type.rustKind, rhs.type.rustKind, flags)
    if result != 2 { return result == 1 }
    // Only fetch rich-text files after the core accepts the text/type precondition.
    flags |= 32
    if lhs.getRTFData() == rhs.getRTFData() { flags |= 64 }
    return aether_clipboard_content_match(lhs.type.rustKind, rhs.type.rustKind, flags) == 1
}

func rustClipboardGroupItemsMatch(_ lhs: [ClipboardItem], _ rhs: [ClipboardItem]) -> Bool {
    guard lhs.count == rhs.count else { return aether_clipboard_group_equal(nil, lhs.count, rhs.count) != 0 }
    let flags: [UInt8] = zip(lhs, rhs).map { left, right in
        var flags: UInt8 = 0
        if left.type == right.type { flags |= 1 }
        if left.stringData == right.stringData { flags |= 2 }
        if left.imageFileName == right.imageFileName { flags |= 4 }
        if left.fileURLs == right.fileURLs { flags |= 8 }
        if left.rtfFileName == right.rtfFileName { flags |= 16 }
        return flags
    }
    return flags.withUnsafeBufferPointer { aether_clipboard_group_equal($0.baseAddress, lhs.count, rhs.count) != 0 }
}

func rustClipboardRow(_ item: ClipboardItem, matching: Bool = false, protected: Bool = false, valid: Bool = true) -> AetherClipboardRow {
    .init(id: AetherUUID(bytes: item.id.uuid), timestamp: item.timestamp.timeIntervalSinceReferenceDate,
        kind: item.type.rustKind, matching: matching ? 1 : 0, protected: protected ? 1 : 0, valid: valid ? 1 : 0)
}

func rustClipboardPlan(_ rows: [AetherClipboardRow], candidate: AetherClipboardRow = AetherClipboardRow(), action: UInt8,
    limit: Int = Int.max, cutoff: Date? = nil) -> (plan: AetherClipboardPlan, indices: [Int]) {
    var output = Array(repeating: 0, count: rows.count + (action == 0 ? 1 : 0))
    let plan = rows.withUnsafeBufferPointer { rows in
        output.withUnsafeMutableBufferPointer {
            aether_clipboard_history_plan(rows.baseAddress, rows.count, candidate, action, max(0, limit),
                cutoff?.timeIntervalSinceReferenceDate ?? 0, cutoff == nil ? 0 : 1, $0.baseAddress, $0.count)
        }
    }
    output.removeLast(output.count - plan.count)
    return (plan, output)
}

func rustClipboardTrim(_ history: [ClipboardItem], limit: Int, protecting protectedIDs: Set<UUID> = []) -> [ClipboardItem] {
    guard aether_clipboard_history_bounded(history.count, max(0, limit)) == 0 else { return history }
    let rows = history.map { rustClipboardRow($0, protected: protectedIDs.contains($0.id)) }
    return rustClipboardPlan(rows, action: 1, limit: limit).indices.map { history[$0] }
}

func rustClipboardUnique(_ items: [ClipboardItem]) -> [ClipboardItem] {
    rustClipboardPlan(items.map { rustClipboardRow($0) }, action: 5).indices.map { items[$0] }
}
func rustClipboardRemoving(_ items: [ClipboardItem], matching: (ClipboardItem) -> Bool) -> [ClipboardItem] {
    let rows = items.map { rustClipboardRow($0, matching: matching($0)) }
    return rustClipboardPlan(rows, action: 4).indices.map { items[$0] }
}
func rustClipboardPin(_ item: ClipboardItem, history: [ClipboardItem], pinned: [ClipboardItem], action: UInt8,
    limit: Int) -> (history: [ClipboardItem], pinned: [ClipboardItem], isPinned: Bool) {
    let h = history.map { rustClipboardRow($0) }, p = pinned.map { rustClipboardRow($0) }
    var hi = Array(repeating: 0, count: h.count + 1), pi = Array(repeating: 0, count: p.count + 1)
    let result = h.withUnsafeBufferPointer { h in
        p.withUnsafeBufferPointer { p in
            hi.withUnsafeMutableBufferPointer { hi in
                pi.withUnsafeMutableBufferPointer { pi in
                    aether_clipboard_pin_plan(h.baseAddress, h.count, p.baseAddress, p.count, rustClipboardRow(item),
                        item.isPinned ? 1 : 0, action, max(0, limit), hi.baseAddress, hi.count, pi.baseAddress, pi.count)
                }
            }
        }
    }
    var candidate = item
    candidate.isPinned = result.pinned != 0
    return (hi.prefix(result.history_count).map { $0 == history.count ? candidate : history[$0] },
        pi.prefix(result.pinned_count).map { $0 == pinned.count ? candidate : pinned[$0] }, candidate.isPinned)
}

extension ClipboardTab {
    var rustTab: UInt8 {
        switch self {
        case .all: 0
        case .text: 1
        case .images: 2
        case .files: 3
        case .favorites: 4
        case .groups: 5
        }
    }
}
