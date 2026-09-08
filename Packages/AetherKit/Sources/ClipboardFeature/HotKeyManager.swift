/*
 * Clipboard
 * Copyright (C) 2026 Li Yuan
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import Carbon
import Foundation

private let clipboardHotKeyHandler: EventHandlerUPP = {
    _, event, _ in
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr, hotKeyID.id == 1 else {
        return status
    }
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            ClipboardPanelController.shared.togglePanel()
        }
    }
    return noErr
}

@MainActor
final class HotKeyManager {
    static let shared = HotKeyManager()

    private var hotKeyReference: EventHotKeyRef?
    private var eventHandlerReference: EventHandlerRef?

    private init() {}

    func refresh() {
        unregister()
        guard UserDefaults.standard.bool(
            forKey: PreferenceKeys.shortcutEnabled
        ) else {
            return
        }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            clipboardHotKeyHandler,
            1,
            &eventType,
            nil,
            &eventHandlerReference
        )

        let hotKeyID = EventHotKeyID(
            signature: OSType(0x434C4950), // CLIP
            id: 1
        )
        RegisterEventHotKey(
            UInt32(kVK_ANSI_J),
            UInt32(cmdKey | shiftKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyReference
        )
    }

    func unregister() {
        if let hotKeyReference {
            UnregisterEventHotKey(hotKeyReference)
            self.hotKeyReference = nil
        }
        if let eventHandlerReference {
            RemoveEventHandler(eventHandlerReference)
            self.eventHandlerReference = nil
        }
    }
}
