// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CAetherCore

enum ClipboardGroupAction: UInt8 { case create, promote, remove, clear }
struct ClipboardGroupTransition {
    let groups: [ClipboardGroup]
    let selected: ClipboardGroup?
    let accepted: Bool
    let changed: Bool
}
private final class ClipboardGroupComparison {
    let groups: [ClipboardGroup]
    let items: [ClipboardItem]
    init(groups: [ClipboardGroup], items: [ClipboardItem]) { self.groups = groups; self.items = items }
}

/// Core owns group selection/order decisions; the callback only supplies native field equality.
func rustClipboardGroupTransition(_ groups: [ClipboardGroup], action: ClipboardGroupAction,
    candidateID: UUID? = nil, items: [ClipboardItem] = []) -> ClipboardGroupTransition {
    precondition(action == .create || action == .clear || candidateID != nil)
    let unique = action == .create ? rustClipboardUnique(items) : []
    let context = action == .create ? ClipboardGroupComparison(groups: groups, items: unique) : nil
    let matching: @convention(c) (UnsafeMutableRawPointer?, Int) -> UInt8 = { pointer, index in
        let comparison = Unmanaged<ClipboardGroupComparison>.fromOpaque(pointer!).takeUnretainedValue()
        return rustClipboardGroupItemsMatch(comparison.groups[index].items, comparison.items) ? 1 : 0
    }
    let ids = groups.map { AetherUUID(bytes: $0.id.uuid) }
    var output = Array(repeating: 0, count: groups.count + (action == .create ? 1 : 0))
    let plan = withExtendedLifetime(context) {
        ids.withUnsafeBufferPointer { ids in
            output.withUnsafeMutableBufferPointer {
                aether_clipboard_groups_plan(ids.baseAddress, ids.count,
                    candidateID.map { AetherUUID(bytes: $0.uuid) } ?? AetherUUID(), unique.count, action.rawValue,
                    matching, context.map { Unmanaged.passUnretained($0).toOpaque() }, $0.baseAddress, $0.count)
            }
        }
    }
    guard plan.accepted != 0 else { return .init(groups: groups, selected: nil, accepted: false, changed: false) }
    let created = plan.create != 0 ? ClipboardGroup(items: unique) : nil
    let selected = created ?? (plan.selected < groups.count ? groups[plan.selected] : nil)
    let updated = plan.identity == 0 ? output.prefix(plan.count).map { $0 == groups.count ? created! : groups[$0] } : groups
    return .init(groups: updated, selected: selected, accepted: true, changed: plan.changed != 0)
}

/// Swift's Hasher preserves native canonical String/optional-array equality. This is per-pass only.
func clipboardGroupFingerprint(_ items: [ClipboardItem]) -> UInt64 {
    var hasher = Hasher()
    hasher.combine(items.count)
    for item in items {
        hasher.combine(item.type)
        hasher.combine(item.stringData)
        hasher.combine(item.imageFileName)
        hasher.combine(item.fileURLs)
        hasher.combine(item.rtfFileName)
    }
    return UInt64(bitPattern: Int64(hasher.finalize()))
}

private struct ClipboardGroupAccumulatorComparison {
    let owner: ClipboardGroupAccumulator
    let items: [ClipboardItem]
}
/// One maintenance pass, used serially. Rust owns only hash buckets and accepted source positions.
final class ClipboardGroupAccumulator {
    private let handle: UnsafeMutableRawPointer?
    private(set) var groups: [ClipboardGroup] = []
    init() {
        handle = aether_clipboard_group_accumulator_create()
        precondition(handle != nil, "Unable to create group maintenance state")
    }
    deinit { aether_clipboard_group_accumulator_destroy(handle) }

    @discardableResult
    func append(_ group: ClipboardGroup) -> Bool {
        var context = ClipboardGroupAccumulatorComparison(owner: self, items: group.items)
        let matching: @convention(c) (UnsafeMutableRawPointer?, Int) -> UInt8 = { pointer, index in
            let comparison = pointer!.assumingMemoryBound(to: ClipboardGroupAccumulatorComparison.self).pointee
            return rustClipboardGroupItemsMatch(comparison.owner.groups[index].items, comparison.items) ? 1 : 0
        }
        let result = withUnsafeMutablePointer(to: &context) {
            aether_clipboard_group_accumulator_accept(handle, clipboardGroupFingerprint(group.items), group.items.count,
                matching, UnsafeMutableRawPointer($0))
        }
        precondition(result < 2, "Invalid group maintenance state")
        guard result == 1 else { return false }
        groups.append(group)
        return true
    }
}
