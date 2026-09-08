import SharedSupport
import AppKit
import ShortcutCore
import SwiftUI

struct ShortcutRecorderView: NSViewRepresentable {
    @Binding var shortcut: KeyCombination
    var onRecordingChanged: (Bool) -> Void
    var capturesPhysicalModifiers = true

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let button = ShortcutRecorderButton(frame: NSRect(x: 0, y: 0, width: 150, height: 28))
        button.shortcut = shortcut
        button.onShortcutChanged = { [weak coordinator = context.coordinator] newShortcut in
            coordinator?.parent.shortcut = newShortcut
        }
        button.onRecordingChanged = { [weak coordinator = context.coordinator] isRecording in
            coordinator?.parent.onRecordingChanged(isRecording)
        }
        button.capturesPhysicalModifiers = capturesPhysicalModifiers
        return button
    }

    func updateNSView(_ nsView: ShortcutRecorderButton, context: Context) {
        context.coordinator.parent = self
        nsView.capturesPhysicalModifiers = capturesPhysicalModifiers
        if !nsView.isRecording { nsView.shortcut = shortcut }
    }

    final class Coordinator {
        var parent: ShortcutRecorderView

        init(parent: ShortcutRecorderView) {
            self.parent = parent
        }
    }
}

final class ShortcutRecorderButton: NSButton {
    var shortcut = KeyCombination(keyCode: 0, modifiers: [.option]) {
        didSet { refreshTitle() }
    }
    var onShortcutChanged: ((KeyCombination) -> Void)?
    var onRecordingChanged: ((Bool) -> Void)?
    var capturesPhysicalModifiers = true
    private(set) var isRecording = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        focusRingType = .exterior
        refreshTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        beginRecording()
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == 53 {
            window?.makeFirstResponder(nil)
            return
        }

        let modifiers = ShortcutModifiers(eventModifierFlags: event.modifierFlags)
        guard !modifiers.isEmpty else {
            NSSound.beep()
            title = "请包含修饰键"
            return
        }

        let activePhysicalModifiers = PhysicalModifierMonitor.shared.activeModifiers
        let physicalModifiers = capturesPhysicalModifiers && activePhysicalModifiers.contains(.capsLock)
            ? activePhysicalModifiers
            : []
        let newShortcut = KeyCombination(
            keyCode: event.keyCode,
            modifiers: modifiers,
            physicalModifiers: physicalModifiers
        )
        shortcut = newShortcut
        onShortcutChanged?(newShortcut)
        window?.makeFirstResponder(nil)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if isRecording {
            isRecording = false
            onRecordingChanged?(false)
            refreshTitle()
            needsDisplay = true
        }
        return result
    }

    private func beginRecording() {
        guard !isRecording else { return }
        isRecording = true
        title = "请按快捷键…"
        onRecordingChanged?(true)
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    private func refreshTitle() {
        guard !isRecording else { return }
        title = shortcut.displayString
    }
}

private extension ShortcutModifiers {
    init(eventModifierFlags: NSEvent.ModifierFlags) {
        var result: ShortcutModifiers = []
        let flags = eventModifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.command) { result.insert(.command) }
        self = result
    }
}
