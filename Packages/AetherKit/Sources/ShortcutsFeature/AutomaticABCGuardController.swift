import SharedSupport
import AppKit
import Carbon.HIToolbox
import ShortcutCore

@MainActor
final class AutomaticABCGuardController {
    private static let abcSourceID = "com.apple.keylayout.ABC"
    private static let doubaoSourceID = "com.bytedance.inputmethod.doubaoime.pinyin"

    private var isEnabled: Bool
    private var guardState = ABCSwitchGuardState()
    private var generation = 0
    private var inputSourceNotification: NSObjectProtocol?

    init(isEnabled: Bool) { self.isEnabled = isEnabled }

    func start() {
        guard inputSourceNotification == nil else { return }
        inputSourceNotification = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.inputSourceDidChange() }
        }
    }

    func stop() {
        generation += 1
        guardState.reset()
        if let inputSourceNotification {
            DistributedNotificationCenter.default().removeObserver(inputSourceNotification)
        }
        inputSourceNotification = nil
    }

    func update(isEnabled: Bool) {
        guard self.isEnabled != isEnabled else { return }
        self.isEnabled = isEnabled
        guardState.reset()
        generation += 1
        if isEnabled { inputSourceDidChange() }
    }

    func physicalInputSwitchKeyWasPressed() {
        guard isEnabled else { return }
        guardState.physicalInputSwitchKeyWasPressed(at: ProcessInfo.processInfo.systemUptime)
    }

    private func inputSourceDidChange() {
        generation += 1
        let currentGeneration = generation
        let decision = guardState.decision(
            blockAutomaticABC: isEnabled,
            switchedToABC: Self.currentInputSourceID == Self.abcSourceID,
            canObservePhysicalKey: PhysicalModifierMonitor.isAuthorized,
            uptime: ProcessInfo.processInfo.systemUptime
        )
        guard decision == .restoreDoubao else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard let self, currentGeneration == self.generation else { return }
            self.restoreDoubaoIfNeeded()
        }
    }

    private func restoreDoubaoIfNeeded() {
        guard isEnabled, Self.currentInputSourceID == Self.abcSourceID,
              let source = Self.inputSource(withID: Self.doubaoSourceID)
        else { return }
        _ = TISSelectInputSource(source)
    }

    private static var currentInputSourceID: String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
        else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    private static func inputSource(withID id: String) -> TISInputSource? {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let sources = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as NSArray?,
              let source = sources.firstObject
        else { return nil }
        return (source as! TISInputSource)
    }
}
