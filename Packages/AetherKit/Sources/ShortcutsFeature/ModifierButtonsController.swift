import SharedSupport
import AppKit
import CoreGraphics
import ShortcutCore

private let modifierButtonsMouseCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let controller = Unmanaged<ModifierButtonsController>.fromOpaque(userInfo).takeUnretainedValue()
    return controller.handleMouseEvent(type: type, event: event)
}

private final class DraggableVisualEffectView: NSVisualEffectView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

private final class DragHandleView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

final class ModifierButtonsController {
    private let panel: NSPanel
    private let rightOptionButton: NSButton
    private let bothShiftsButton: NSButton
    private let copyButton: NSButton
    private let pasteButton: NSButton
    private let selectAllButton: NSButton
    private let billdDeskButton: NSButton
    private let backspaceButton: NSButton
    private let enterButton: NSButton
    private let clipboardButton: NSButton
    private let openBilldDesk: () -> Void
    private let openClipboard: () -> Void
    private var interceptedButton: NSButton?
    private var dragStartMouseLocation: NSPoint?
    private var dragStartPanelOrigin: NSPoint?
    private var mouseEventTap: CFMachPort?
    private var mouseEventTapSource: CFRunLoopSource?
    private var isStarted = false
    private var shouldShow = true
    private var settingsPresented = false

    init(openBilldDesk: @escaping () -> Void, openClipboard: @escaping () -> Void) {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 184, height: 110),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        rightOptionButton = Self.makeButton(title: "右⌥", help: "快速轻点一次右 Option")
        bothShiftsButton = Self.makeButton(title: "⇧⇧", help: "同时轻点左右 Shift")
        copyButton = Self.makeButton(title: "⌘C", help: "发送 Command+C")
        pasteButton = Self.makeButton(title: "⌘V", help: "发送 Command+V")
        selectAllButton = Self.makeButton(title: "⌘A", help: "发送 Command+A")
        billdDeskButton = Self.makeButton(title: "Billd", help: "激活或打开 BilldDesk")
        backspaceButton = Self.makeButton(title: "⌫", help: "发送 Backspace")
        enterButton = Self.makeButton(title: "Enter", help: "发送 Enter")
        clipboardButton = Self.makeButton(title: "⌥⇧J", help: "打开 Clipboard")
        self.openBilldDesk = openBilldDesk
        self.openClipboard = openClipboard
        configurePanel()
    }

    func start(isVisible: Bool) {
        isStarted = true
        shouldShow = isVisible
        updateWindowPresentation()
        updateAccessibilityPermission(isGranted: AccessibilityPermission.isGranted)
    }

    func stop() {
        isStarted = false
        uninstallMouseInterceptor()
        panel.orderOut(nil)
    }

    func setVisible(_ visible: Bool) {
        shouldShow = visible
        updateWindowPresentation()
    }

    func setSettingsPresented(_ presented: Bool) {
        settingsPresented = presented
        updateWindowPresentation()
    }

    func updateAccessibilityPermission(isGranted: Bool) {
        for button in allButtons {
            button.isEnabled = isGranted
        }
        if isGranted {
            installMouseInterceptor()
        } else {
            uninstallMouseInterceptor()
        }
    }

    private func configurePanel() {
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false

        let background = DraggableVisualEffectView(frame: panel.contentView?.bounds ?? .zero)
        background.autoresizingMask = [.width, .height]
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 9
        background.layer?.masksToBounds = true
        panel.contentView = background

        let dragHandle = DragHandleView()
        dragHandle.translatesAutoresizingMaskIntoConstraints = false
        dragHandle.wantsLayer = true
        dragHandle.layer?.backgroundColor = NSColor.tertiaryLabelColor.cgColor
        dragHandle.layer?.cornerRadius = 1.5
        background.addSubview(dragHandle)

        for button in allButtons {
            button.target = self
            background.addSubview(button)
        }
        rightOptionButton.action = #selector(pressRightOption)
        bothShiftsButton.action = #selector(pressBothShifts)
        copyButton.action = #selector(pressCopy)
        pasteButton.action = #selector(pressPaste)
        selectAllButton.action = #selector(pressSelectAll)
        billdDeskButton.action = #selector(pressBilldDesk)
        backspaceButton.action = #selector(pressBackspace)
        enterButton.action = #selector(pressEnter)
        clipboardButton.action = #selector(pressClipboard)

        NSLayoutConstraint.activate([
            dragHandle.topAnchor.constraint(equalTo: background.topAnchor, constant: 4),
            dragHandle.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            dragHandle.widthAnchor.constraint(equalToConstant: 24),
            dragHandle.heightAnchor.constraint(equalToConstant: 3),
            rightOptionButton.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 5),
            rightOptionButton.topAnchor.constraint(equalTo: background.topAnchor, constant: 13),
            rightOptionButton.widthAnchor.constraint(equalToConstant: 54),
            rightOptionButton.heightAnchor.constraint(equalToConstant: 28),
            bothShiftsButton.leadingAnchor.constraint(equalTo: rightOptionButton.trailingAnchor, constant: 6),
            bothShiftsButton.topAnchor.constraint(equalTo: rightOptionButton.topAnchor),
            bothShiftsButton.widthAnchor.constraint(equalToConstant: 54),
            bothShiftsButton.heightAnchor.constraint(equalToConstant: 28),
            backspaceButton.leadingAnchor.constraint(equalTo: bothShiftsButton.trailingAnchor, constant: 6),
            backspaceButton.topAnchor.constraint(equalTo: bothShiftsButton.topAnchor),
            backspaceButton.widthAnchor.constraint(equalToConstant: 54),
            backspaceButton.heightAnchor.constraint(equalToConstant: 28),
            copyButton.leadingAnchor.constraint(equalTo: rightOptionButton.leadingAnchor),
            copyButton.topAnchor.constraint(equalTo: rightOptionButton.bottomAnchor, constant: 4),
            copyButton.widthAnchor.constraint(equalToConstant: 54),
            copyButton.heightAnchor.constraint(equalToConstant: 28),
            pasteButton.leadingAnchor.constraint(equalTo: bothShiftsButton.leadingAnchor),
            pasteButton.topAnchor.constraint(equalTo: bothShiftsButton.bottomAnchor, constant: 4),
            pasteButton.widthAnchor.constraint(equalToConstant: 54),
            pasteButton.heightAnchor.constraint(equalToConstant: 28),
            enterButton.leadingAnchor.constraint(equalTo: backspaceButton.leadingAnchor),
            enterButton.topAnchor.constraint(equalTo: pasteButton.topAnchor),
            enterButton.widthAnchor.constraint(equalToConstant: 54),
            enterButton.heightAnchor.constraint(equalToConstant: 28),
            selectAllButton.leadingAnchor.constraint(equalTo: copyButton.leadingAnchor),
            selectAllButton.topAnchor.constraint(equalTo: copyButton.bottomAnchor, constant: 4),
            selectAllButton.widthAnchor.constraint(equalToConstant: 54),
            selectAllButton.heightAnchor.constraint(equalToConstant: 28),
            billdDeskButton.leadingAnchor.constraint(equalTo: pasteButton.leadingAnchor),
            billdDeskButton.topAnchor.constraint(equalTo: pasteButton.bottomAnchor, constant: 4),
            billdDeskButton.widthAnchor.constraint(equalToConstant: 54),
            billdDeskButton.heightAnchor.constraint(equalToConstant: 28),
            clipboardButton.leadingAnchor.constraint(equalTo: enterButton.leadingAnchor),
            clipboardButton.topAnchor.constraint(equalTo: billdDeskButton.topAnchor),
            clipboardButton.widthAnchor.constraint(equalToConstant: 54),
            clipboardButton.heightAnchor.constraint(equalToConstant: 28)
        ])

        let contentSize = panel.contentView?.bounds.size ?? NSSize(width: 184, height: 110)
        if panel.setFrameUsingName("KeyPilotModifierButtonsPanel") {
            panel.setContentSize(contentSize)
        } else {
            panel.center()
        }
        panel.setFrameAutosaveName("KeyPilotModifierButtonsPanel")
    }

    private static func makeButton(title: String, help: String) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        button.bezelStyle = .texturedRounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 12, weight: .semibold)
        button.toolTip = help
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    private var allButtons: [NSButton] {
        [
            rightOptionButton, bothShiftsButton, backspaceButton,
            copyButton, pasteButton, enterButton,
            selectAllButton, billdDeskButton, clipboardButton
        ]
    }

    private func updateWindowPresentation() {
        guard isStarted, shouldShow else {
            interceptedButton?.highlight(false)
            interceptedButton = nil
            dragStartMouseLocation = nil
            dragStartPanelOrigin = nil
            panel.orderOut(nil)
            return
        }

        if settingsPresented {
            interceptedButton?.highlight(false)
            interceptedButton = nil
            dragStartMouseLocation = nil
            dragStartPanelOrigin = nil
            panel.level = .normal
            panel.orderBack(nil)
        } else {
            panel.level = .floating
            panel.orderFrontRegardless()
        }
    }

    private func installMouseInterceptor() {
        guard mouseEventTap == nil else { return }

        let eventMask = (CGEventMask(1) << CGEventType.leftMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.leftMouseUp.rawValue)
            | (CGEventMask(1) << CGEventType.leftMouseDragged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: modifierButtonsMouseCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        mouseEventTap = tap
        mouseEventTapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func uninstallMouseInterceptor() {
        guard let tap = mouseEventTap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source = mouseEventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        mouseEventTap = nil
        mouseEventTapSource = nil
        interceptedButton = nil
        dragStartMouseLocation = nil
        dragStartPanelOrigin = nil
    }

    fileprivate func handleMouseEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let mouseEventTap { CGEvent.tapEnable(tap: mouseEventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        guard panel.isVisible, !settingsPresented else {
            interceptedButton?.highlight(false)
            interceptedButton = nil
            dragStartMouseLocation = nil
            dragStartPanelOrigin = nil
            return Unmanaged.passUnretained(event)
        }

        let appKitPoint = NSPoint(
            x: event.location.x,
            y: (NSScreen.screens.first?.frame.maxY ?? 0) - event.location.y
        )
        let hoveredButton = allButtons.first { button in
            let rectInWindow = button.convert(button.bounds, to: nil)
            return panel.convertToScreen(rectInWindow).contains(appKitPoint)
        }
        let isInsidePanel = panel.frame.contains(appKitPoint)

        switch type {
        case .leftMouseDown where hoveredButton != nil:
            interceptedButton = hoveredButton
            hoveredButton?.highlight(true)
            return nil

        case .leftMouseDown where isInsidePanel:
            dragStartMouseLocation = appKitPoint
            dragStartPanelOrigin = panel.frame.origin
            return nil

        case .leftMouseDragged where dragStartMouseLocation != nil:
            guard let dragStartMouseLocation, let dragStartPanelOrigin else { return nil }
            panel.setFrameOrigin(NSPoint(
                x: dragStartPanelOrigin.x + appKitPoint.x - dragStartMouseLocation.x,
                y: dragStartPanelOrigin.y + appKitPoint.y - dragStartMouseLocation.y
            ))
            return nil

        case .leftMouseDragged where interceptedButton != nil:
            interceptedButton?.highlight(interceptedButton === hoveredButton)
            return nil

        case .leftMouseUp where dragStartMouseLocation != nil:
            dragStartMouseLocation = nil
            dragStartPanelOrigin = nil
            return nil

        case .leftMouseUp where interceptedButton != nil:
            let clickedButton = interceptedButton
            interceptedButton = nil
            clickedButton?.highlight(false)
            if clickedButton === hoveredButton {
                if clickedButton === rightOptionButton {
                    pressRightOption()
                } else if clickedButton === bothShiftsButton {
                    pressBothShifts()
                } else if clickedButton === copyButton {
                    pressCopy()
                } else if clickedButton === pasteButton {
                    pressPaste()
                } else if clickedButton === selectAllButton {
                    pressSelectAll()
                } else if clickedButton === billdDeskButton {
                    pressBilldDesk()
                } else if clickedButton === backspaceButton {
                    pressBackspace()
                } else if clickedButton === enterButton {
                    pressEnter()
                } else if clickedButton === clipboardButton {
                    pressClipboard()
                }
            }
            return nil

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    @objc private func pressRightOption() {
        sendTap(.rightOption)
    }

    @objc private func pressBothShifts() {
        sendTap(.bothShifts)
    }

    @objc private func pressCopy() {
        SyntheticKeySender.send(KeyCombination(keyCode: 8, modifiers: .command))
    }

    @objc private func pressPaste() {
        SyntheticKeySender.send(KeyCombination(keyCode: 9, modifiers: .command))
    }

    @objc private func pressSelectAll() {
        SyntheticKeySender.send(KeyCombination(keyCode: 0, modifiers: .command))
    }

    @objc private func pressBilldDesk() {
        openBilldDesk()
    }

    @objc private func pressBackspace() {
        SyntheticKeySender.send(KeyCombination(keyCode: 51, modifiers: []))
    }

    @objc private func pressEnter() {
        SyntheticKeySender.send(KeyCombination(keyCode: 36, modifiers: []))
    }

    @objc private func pressClipboard() {
        openClipboard()
    }

    private func sendTap(_ kind: ModifierTapKind) {
        guard AccessibilityPermission.isGranted,
              let source = CGEventSource(stateID: .hidSystemState)
        else {
            NSSound.beep()
            return
        }

        let steps = ModifierTapSequence.steps(for: kind)
        post(steps.filter(\.isKeyDown), source: source)
        DispatchQueue.main.asyncAfter(deadline: .now() + ModifierTapSequence.tapDuration) { [weak self] in
            self?.post(steps.filter { !$0.isKeyDown }, source: source)
        }
    }

    private func post(_ steps: [ModifierTapStep], source: CGEventSource) {
        for step in steps {
            guard let event = CGEvent(
                keyboardEventSource: source,
                virtualKey: CGKeyCode(step.keyCode),
                keyDown: step.isKeyDown
            ) else {
                NSSound.beep()
                return
            }
            event.type = .flagsChanged
            event.flags = step.modifiers.eventFlags.union(step.physicalModifiers.deviceEventFlags)
            event.post(tap: .cghidEventTap)
        }
    }
}

private extension PhysicalModifierKeys {
    var deviceEventFlags: CGEventFlags {
        // IOLLEvent.h 中的 NX_DEVICE*KEYMASK；用于让 NSEvent 区分左右修饰键。
        var rawValue: UInt64 = 0
        if contains(.leftControl) { rawValue |= 0x0000_0001 }
        if contains(.leftShift) { rawValue |= 0x0000_0002 }
        if contains(.rightShift) { rawValue |= 0x0000_0004 }
        if contains(.leftCommand) { rawValue |= 0x0000_0008 }
        if contains(.rightCommand) { rawValue |= 0x0000_0010 }
        if contains(.leftOption) { rawValue |= 0x0000_0020 }
        if contains(.rightOption) { rawValue |= 0x0000_0040 }
        if contains(.rightControl) { rawValue |= 0x0000_2000 }
        return CGEventFlags(rawValue: rawValue)
    }
}
