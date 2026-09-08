import SharedSupport
/*
 * Clipboard
 * Copyright (C) 2026 Li Yuan
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import AppKit
import CoreGraphics

enum ClipboardGroupPastePlan {
    static func usesSinglePaste(for types: [ClipboardItemType]) -> Bool {
        let textCompatible: Set<ClipboardItemType> = [
            .text, .url, .rtf, .unknown
        ]
        return types.allSatisfy(textCompatible.contains)
            || types.allSatisfy { $0 == .file }
    }

    static func delayNanoseconds(after type: ClipboardItemType) -> UInt64 {
        switch type {
        case .image:
            return 1_500_000_000
        case .file:
            return 1_000_000_000
        case .rtf:
            return 500_000_000
        case .text, .url, .unknown:
            return 250_000_000
        }
    }
}

@MainActor
final class PasteCoordinator {
    static let shared = PasteCoordinator()

    private var targetApplication: NSRunningApplication?
    private var lastExternalApplication: NSRunningApplication?
    private var observer: NSObjectProtocol?
    private var pasteTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    private init() {
        rememberExternalApplication(NSWorkspace.shared.frontmostApplication)
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[
                NSWorkspace.applicationUserInfoKey
            ] as? NSRunningApplication
            Task { @MainActor [weak self] in
                self?.rememberExternalApplication(app)
            }
        }
    }

    func captureCurrentApplication() {
        cancelPendingPaste()
        if let app = externalApplication(
            from: NSWorkspace.shared.frontmostApplication
        ) {
            targetApplication = app
            lastExternalApplication = app
        } else if targetApplication?.isTerminated != false {
            targetApplication = validLastExternalApplication
        }
    }

    func pasteIntoCapturedApplication() {
        AppRouter.shared.send(.dismissPanels)
        cancelPendingPaste()
        let currentGeneration = generation
        guard let application = resolvedTargetApplication else {
            targetApplication = nil
            return
        }
        targetApplication = nil

        guard AccessibilityController.isTrusted else {
            AccessibilityController.requestAccess()
            return
        }

        pasteTask = Task { @MainActor [weak self] in
            application.activate(options: [.activateAllWindows])
            let isFrontmost = await Self.waitForActivation(application)
            guard !Task.isCancelled,
                  self?.generation == currentGeneration,
                  !application.isTerminated else {
                return
            }
            Self.postPaste(
                to: application.processIdentifier,
                globally: isFrontmost
            )
            if self?.generation == currentGeneration {
                self?.pasteTask = nil
            }
        }
    }

    func pasteGroupIntoCapturedApplication(_ group: ClipboardGroup) {
        AppRouter.shared.send(.dismissPanels)
        let usesSinglePaste = ClipboardGroupPastePlan.usesSinglePaste(
            for: group.items.map(\.type)
        )
        guard !usesSinglePaste else {
            pasteIntoCapturedApplication()
            return
        }

        cancelPendingPaste()
        let currentGeneration = generation
        guard let application = resolvedTargetApplication else {
            targetApplication = nil
            return
        }
        targetApplication = nil

        guard AccessibilityController.isTrusted else {
            AccessibilityController.requestAccess()
            return
        }

        pasteTask = Task { @MainActor [weak self] in
            for item in group.items {
                guard !Task.isCancelled,
                      self?.generation == currentGeneration,
                      !application.isTerminated else {
                    return
                }
                application.activate(options: [.activateAllWindows])
                let isFrontmost = await Self.waitForActivation(application)
                guard !Task.isCancelled,
                      self?.generation == currentGeneration,
                      !application.isTerminated else {
                    return
                }
                guard ClipboardStore.shared.copyToClipboard(item) else {
                    continue
                }
                Self.postPaste(
                    to: application.processIdentifier,
                    globally: isFrontmost
                )
                let delay = ClipboardGroupPastePlan.delayNanoseconds(
                    after: item.type
                )
                guard await Self.wait(nanoseconds: delay) else {
                    return
                }
            }
            _ = ClipboardStore.shared.copyGroupToClipboard(group)
            if self?.generation == currentGeneration {
                self?.pasteTask = nil
            }
        }
    }

    private func cancelPendingPaste() {
        generation &+= 1
        pasteTask?.cancel()
        pasteTask = nil
    }

    private var resolvedTargetApplication: NSRunningApplication? {
        if let targetApplication, !targetApplication.isTerminated {
            return targetApplication
        }
        return validLastExternalApplication
    }

    private var validLastExternalApplication: NSRunningApplication? {
        guard let lastExternalApplication,
              !lastExternalApplication.isTerminated else {
            return nil
        }
        return lastExternalApplication
    }

    private func rememberExternalApplication(
        _ application: NSRunningApplication?
    ) {
        guard let app = externalApplication(from: application) else { return }
        lastExternalApplication = app
    }

    private func externalApplication(
        from application: NSRunningApplication?
    ) -> NSRunningApplication? {
        guard let application,
              !application.isTerminated,
              application.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return nil
        }
        return application
    }

    private static func waitForActivation(
        _ application: NSRunningApplication
    ) async -> Bool {
        for _ in 0..<40 {
            guard !Task.isCancelled, !application.isTerminated else {
                return false
            }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier
                == application.processIdentifier {
                return true
            }
            guard await wait(nanoseconds: 25_000_000) else { return false }
        }
        return false
    }

    private static func wait(nanoseconds: UInt64) async -> Bool {
        do {
            try await Task.sleep(nanoseconds: nanoseconds)
            return !Task.isCancelled
        } catch {
            return false
        }
    }

    private static func postPaste(
        to processIdentifier: pid_t,
        globally: Bool
    ) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let keyDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: 9,
            keyDown: true
        ), let keyUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: 9,
            keyDown: false
        ) else {
            return
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        SyntheticInput.tag(keyDown)
        SyntheticInput.tag(keyUp)
        if globally {
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
        } else {
            keyDown.postToPid(processIdentifier)
            keyUp.postToPid(processIdentifier)
        }
    }
}
