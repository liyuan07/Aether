import SharedSupport
import AppKit
import Foundation
import IOKit.hid
import ShortcutCore

private let physicalModifierCallback: IOHIDValueCallback = { context, _, _, value in
    guard let context else { return }
    let monitor = Unmanaged<PhysicalModifierMonitor>.fromOpaque(context).takeUnretainedValue()
    monitor.handle(value: value)
}

final class PhysicalModifierMonitor {
    static let shared = PhysicalModifierMonitor()
    var onModifiersChanged: ((PhysicalModifierKeys) -> Void)?
    var onInputSwitchKey: (() -> Void)?

    static var isAuthorized: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    static func requestAuthorization() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    static func openPrivacySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private let stateLock = NSLock()
    private var pressedElements: [UInt: PhysicalModifierKeys] = [:]
    private var manager: IOHIDManager?

    var activeModifiers: PhysicalModifierKeys {
        stateLock.withLock {
            pressedElements.values.reduce(into: PhysicalModifierKeys()) { result, key in
                result.formUnion(key)
            }
        }
    }

    func start() {
        guard manager == nil, Self.isAuthorized else { return }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let keyboardMatch: [String: Any] = [
            kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Keyboard
        ]
        IOHIDManagerSetDeviceMatching(manager, keyboardMatch as CFDictionary)

        IOHIDManagerSetInputValueMatching(
            manager,
            [kIOHIDElementUsagePageKey as String: kHIDPage_KeyboardOrKeypad] as CFDictionary
        )
        IOHIDManagerRegisterInputValueCallback(
            manager,
            physicalModifierCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)

        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            return
        }
        self.manager = manager
    }

    func stop() {
        guard let manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
        stateLock.withLock {
            pressedElements.removeAll()
        }
        onModifiersChanged?([])
    }

    fileprivate func handle(value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        guard IOHIDElementGetUsagePage(element) == kHIDPage_KeyboardOrKeypad else { return }

        let usage = IOHIDElementGetUsage(element)
        let isInputSwitchKey = usage == UInt32(kHIDUsage_KeyboardCapsLock)
        let key = Self.physicalKey(for: usage)
        let identity = UInt(bitPattern: Unmanaged.passUnretained(element).toOpaque())
        let isPressed = IOHIDValueGetIntegerValue(value) != 0
        let result = stateLock.withLock { () -> (PhysicalModifierKeys, Bool) in
            if isPressed {
                if let key { pressedElements[identity] = key }
            } else {
                if key != nil { pressedElements.removeValue(forKey: identity) }
            }
            let modifiers = pressedElements.values.reduce(into: PhysicalModifierKeys()) { result, key in
                result.formUnion(key)
            }
            return (modifiers, isInputSwitchKey && isPressed)
        }
        DispatchQueue.main.async { [weak self] in
            self?.onModifiersChanged?(result.0)
            if result.1 { self?.onInputSwitchKey?() }
        }
    }

    private static func physicalKey(for usage: UInt32) -> PhysicalModifierKeys? {
        switch Int(usage) {
        case kHIDUsage_KeyboardCapsLock: .capsLock
        case kHIDUsage_KeyboardLeftControl: .leftControl
        case kHIDUsage_KeyboardRightControl: .rightControl
        case kHIDUsage_KeyboardLeftAlt: .leftOption
        case kHIDUsage_KeyboardRightAlt: .rightOption
        case kHIDUsage_KeyboardLeftShift: .leftShift
        case kHIDUsage_KeyboardRightShift: .rightShift
        case kHIDUsage_KeyboardLeftGUI: .leftCommand
        case kHIDUsage_KeyboardRightGUI: .rightCommand
        default: nil
        }
    }
}
