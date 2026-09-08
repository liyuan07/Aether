import SharedSupport
import AppKit
import CoreGraphics
import ShortcutCore


private let shortcutEventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let engine = Unmanaged<GlobalShortcutEngine>.fromOpaque(userInfo).takeUnretainedValue()
    return engine.handle(type: type, event: event)
}

final class GlobalShortcutEngine {
    typealias ActionHandler = @MainActor (ShortcutAction) -> Void
    typealias KeyDownObserver = @MainActor () -> Void
    typealias InputSwitchKeyObserver = @MainActor () -> Void
    typealias GuideNavigationHandler = (UInt16, Bool) -> Bool
    typealias ApplicationKeyDownHandler = (UInt16, ShortcutModifiers, PhysicalModifierKeys, Bool) -> Bool
    typealias ApplicationKeyUpHandler = (UInt16) -> Bool
    typealias RecoveryHandler = @MainActor () -> Void

    private let actionHandler: ActionHandler
    private let keyDownObserver: KeyDownObserver
    private let keyDownObservationChord: PhysicalModifierKeys
    private let inputSwitchKeyObserver: InputSwitchKeyObserver
    private let guideNavigationHandler: GuideNavigationHandler
    private let applicationKeyDownHandler: ApplicationKeyDownHandler
    private let applicationKeyUpHandler: ApplicationKeyUpHandler
    private let recoveryHandler: RecoveryHandler
    private let stateLock = NSLock()
    private var rulesByKeyCode: [UInt16: [ShortcutRule]] = [:]
    private var suppressedKeyCodes = Set<UInt16>()
    private var activeRulesByKeyCode: [UInt16: ShortcutRule] = [:]
    private var activeWindowLayoutsByKeyCode: [UInt16: WindowLayout] = [:]
    private var actionsWaitingForKeyUp: [UInt16: ShortcutAction] = [:]
    private var eventTap: CFMachPort?
    private var eventRunLoop: CFRunLoop?
    private var workerThread: Thread?
    private var isStarting = false

    private struct ResolvedRule {
        let rule: ShortcutRule
        let trigger: ResolvedShortcutTrigger
    }

    init(
        actionHandler: @escaping ActionHandler,
        keyDownObserver: @escaping KeyDownObserver = {},
        keyDownObservationChord: PhysicalModifierKeys = [],
        inputSwitchKeyObserver: @escaping InputSwitchKeyObserver = {},
        guideNavigationHandler: @escaping GuideNavigationHandler = { _, _ in false },
        applicationKeyDownHandler: @escaping ApplicationKeyDownHandler = { _, _, _, _ in false },
        applicationKeyUpHandler: @escaping ApplicationKeyUpHandler = { _ in false },
        recoveryHandler: @escaping RecoveryHandler = {}
    ) {
        self.actionHandler = actionHandler
        self.keyDownObserver = keyDownObserver
        self.keyDownObservationChord = keyDownObservationChord
        self.inputSwitchKeyObserver = inputSwitchKeyObserver
        self.guideNavigationHandler = guideNavigationHandler
        self.applicationKeyDownHandler = applicationKeyDownHandler
        self.applicationKeyUpHandler = applicationKeyUpHandler
        self.recoveryHandler = recoveryHandler
    }

    func updateRules(_ rules: [ShortcutRule]) {
        stateLock.withLock {
            rulesByKeyCode = Dictionary(grouping: rules, by: { $0.source.keyCode })
        }
    }

    func start() {
        stateLock.lock()
        guard eventTap == nil, !isStarting else {
            stateLock.unlock()
            return
        }
        isStarting = true
        stateLock.unlock()

        let thread = Thread { [weak self] in
            self?.runEventLoop()
        }
        thread.name = "com.liyuan.keypilot.event-tap"
        thread.qualityOfService = .userInteractive
        workerThread = thread
        thread.start()
    }

    func stop() {
        let runLoop = stateLock.withLock { () -> CFRunLoop? in
            let current = eventRunLoop
            eventRunLoop = nil
            return current
        }
        if let runLoop { CFRunLoopStop(runLoop) }
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = stateLock.withLock({ eventTap }) {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        if SyntheticInput.isOurs(event) {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        if (type == .flagsChanged || type == .keyDown), PhysicalInputSwitchKey.matches(keyCode: keyCode) {
            Task { @MainActor [inputSwitchKeyObserver] in inputSwitchKeyObserver() }
            if type == .flagsChanged { return Unmanaged.passUnretained(event) }
        }
        if type == .keyUp {
            if applicationKeyUpHandler(keyCode) { return nil }
            let (shouldSuppress, pendingAction) = stateLock.withLock {
                (
                    suppressedKeyCodes.remove(keyCode) != nil,
                    actionsWaitingForKeyUp.removeValue(forKey: keyCode)
                )
            }
            _ = stateLock.withLock { activeRulesByKeyCode.removeValue(forKey: keyCode) }
            _ = stateLock.withLock { activeWindowLayoutsByKeyCode.removeValue(forKey: keyCode) }
            if let pendingAction {
                Task { @MainActor [actionHandler] in
                    actionHandler(pendingAction)
                }
            }
            return shouldSuppress ? nil : Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        let eventModifiers = ShortcutModifiers(eventFlags: event.flags)
        let activePhysicalModifiers = PhysicalModifierMonitor.shared.activeModifiers
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        if !isRepeat, keyCode == 103, eventModifiers == [.option, .command] {
            _ = stateLock.withLock { suppressedKeyCodes.insert(keyCode) }
            Task { @MainActor [recoveryHandler] in recoveryHandler() }
            return nil
        }

        if guideNavigationHandler(keyCode, isRepeat) {
            _ = stateLock.withLock { suppressedKeyCodes.insert(keyCode) }
            return nil
        }

        if applicationKeyDownHandler(keyCode, eventModifiers, activePhysicalModifiers, isRepeat) {
            return nil
        }

        if !isRepeat,
           !keyDownObservationChord.isEmpty,
           activePhysicalModifiers.intersection(keyDownObservationChord) == keyDownObservationChord {
            Task { @MainActor [keyDownObserver] in
                keyDownObserver()
            }
        }

        if isRepeat {
            guard let activeRule = stateLock.withLock({ activeRulesByKeyCode[keyCode] }) else {
                return stateLock.withLock({ suppressedKeyCodes.contains(keyCode) }) ? nil : Unmanaged.passUnretained(event)
            }
            if let trigger = ShortcutTriggerResolver.resolve(
                   rule: activeRule,
                   eventModifiers: eventModifiers,
                   activePhysicalModifiers: activePhysicalModifiers
               ),
               case .remap = trigger.action {
                perform(trigger.action)
            }
            return nil
        }


        guard let resolvedRule = stateLock.withLock({
            rulesByKeyCode[keyCode]?
                .compactMap { rule -> ResolvedRule? in
                    guard let trigger = ShortcutTriggerResolver.resolve(
                        rule: rule,
                        eventModifiers: eventModifiers,
                        activePhysicalModifiers: activePhysicalModifiers
                    ) else { return nil }
                    return ResolvedRule(rule: rule, trigger: trigger)
                }
                .max {
                    if $0.trigger.isExactModifierMatch != $1.trigger.isExactModifierMatch {
                        return !$0.trigger.isExactModifierMatch
                    }
                    return $0.rule.source.physicalModifiers.rawValue.nonzeroBitCount
                        < $1.rule.source.physicalModifiers.rawValue.nonzeroBitCount
                }
        }) else {
            return Unmanaged.passUnretained(event)
        }

        let execution = stateLock.withLock { () -> (waitsForKeyUp: Bool, action: ShortcutAction) in
            suppressedKeyCodes.insert(keyCode)
            activeRulesByKeyCode[keyCode] = resolvedRule.rule
            if case .showDesktop = resolvedRule.trigger.action {
                actionsWaitingForKeyUp[keyCode] = resolvedRule.trigger.action
                return (true, resolvedRule.trigger.action)
            }
            if case let .windowLayout(layout) = resolvedRule.trigger.action {
                activeWindowLayoutsByKeyCode[keyCode] = layout
                let combined = WindowLayout.combining(activeWindowLayoutsByKeyCode.values) ?? layout
                return (false, .windowLayout(combined))
            }
            return (false, resolvedRule.trigger.action)
        }
        if !execution.waitsForKeyUp {
            perform(execution.action)
        }
        return nil
    }

    private func runEventLoop() {
        autoreleasepool {
            let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
                | (CGEventMask(1) << CGEventType.keyUp.rawValue)
                | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
            guard let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: shortcutEventTapCallback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            ) else {
                stateLock.withLock { isStarting = false }
                return
            }

            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            let runLoop = CFRunLoopGetCurrent()
            stateLock.withLock {
                eventTap = tap
                eventRunLoop = runLoop
                isStarting = false
            }
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
            CGEvent.tapEnable(tap: tap, enable: false)
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
            stateLock.withLock {
                eventTap = nil
                eventRunLoop = nil
                workerThread = nil
                suppressedKeyCodes.removeAll()
                actionsWaitingForKeyUp.removeAll()
                activeRulesByKeyCode.removeAll()
                activeWindowLayoutsByKeyCode.removeAll()
            }
        }
    }

    private func perform(_ action: ShortcutAction) {
        Task { @MainActor [actionHandler] in
            actionHandler(action)
        }
    }
}

extension ShortcutModifiers {
    init(eventFlags: CGEventFlags) {
        var result: ShortcutModifiers = []
        if eventFlags.contains(.maskControl) { result.insert(.control) }
        if eventFlags.contains(.maskAlternate) { result.insert(.option) }
        if eventFlags.contains(.maskShift) { result.insert(.shift) }
        if eventFlags.contains(.maskCommand) { result.insert(.command) }
        self = result
    }

    var eventFlags: CGEventFlags {
        var result: CGEventFlags = []
        if contains(.control) { result.insert(.maskControl) }
        if contains(.option) { result.insert(.maskAlternate) }
        if contains(.shift) { result.insert(.maskShift) }
        if contains(.command) { result.insert(.maskCommand) }
        return result
    }
}

enum SyntheticKeySender {
    static func send(_ shortcut: KeyCombination) {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(shortcut.keyCode), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(shortcut.keyCode), keyDown: false)
        else { return }

        for event in [keyDown, keyUp] {
            event.flags = shortcut.modifiers.eventFlags
            SyntheticInput.tag(event)
            event.post(tap: .cgSessionEventTap)
        }
    }
}
