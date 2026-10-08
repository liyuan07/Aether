// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CAetherCore

/// Built synchronously, then immutable. Core owns exact ID sequences independently of native
/// archives; ARC safely shares a maintenance source identity with its asynchronous task.
final class RustClipboardArchiveIdentity: @unchecked Sendable {
    private let handle = aether_clipboard_identity_create()
    init(_ archive: ClipboardArchive) {
        func append(_ id: UUID, _ section: UInt8) {
            precondition(aether_clipboard_identity_append(handle, section, .init(bytes: id.uuid)) != 0)
        }
        for item in archive.history { append(item.id, 0) }
        for item in archive.pinnedItems { append(item.id, 1) }
        for group in archive.groups ?? [] {
            append(group.id, 2)
            for item in group.items { append(item.id, 3) }
        }
    }
    deinit { aether_clipboard_identity_destroy(handle) }
    func changes(from other: RustClipboardArchiveIdentity) -> AetherClipboardIdentityChanges {
        withExtendedLifetime(other) { aether_clipboard_identity_changes(handle, other.handle) }
    }
    func matches(_ other: RustClipboardArchiveIdentity) -> Bool {
        let result = changes(from: other)
        return result.history == 0 && result.pinned == 0 && result.groups == 0
    }
}

private final class ClipboardActivationLookup {
    let id: UUID
    let pinned: [ClipboardItem], history: [ClipboardItem]
    init(id: UUID, pinned: [ClipboardItem], history: [ClipboardItem]) {
        self.id = id; self.pinned = pinned; self.history = history
    }
    func find(_ section: UInt8) -> Int {
        (section == 0 ? pinned : history).firstIndex { $0.id == id } ?? -1
    }
}
func clipboardActivationPlan(id: UUID, pinned: [ClipboardItem], history: [ClipboardItem]) -> AetherClipboardActivation {
    let lookup = ClipboardActivationLookup(id: id, pinned: pinned, history: history)
    return withExtendedLifetime(lookup) {
        aether_clipboard_activation_plan({ context, section in
            Unmanaged<ClipboardActivationLookup>.fromOpaque(context!).takeUnretainedValue().find(section)
        }, Unmanaged.passUnretained(lookup).toOpaque())
    }
}
func clipboardGroupCopiesText(_ items: [ClipboardItem]) -> Bool {
    items.map { rustClipboardRow($0, matching: $0.stringData != nil) }.withUnsafeBufferPointer {
        aether_clipboard_group_copy_text($0.baseAddress, $0.count) != 0
    }
}
