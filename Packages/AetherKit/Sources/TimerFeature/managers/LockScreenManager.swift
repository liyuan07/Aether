/*
 * package counter
 * Derived from Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import AppKit
import SwiftUI

@MainActor
final class LockScreenManager: ObservableObject {
    static let shared = LockScreenManager()

    @Published private(set) var isLocked = false
    private weak var viewModel: DynamicIslandViewModel?

    var currentLockStatus: Bool { isLocked }

    private init() {
        isLocked = Self.queryCurrentLockStatus()
    }

    func configure(viewModel: DynamicIslandViewModel) {
        self.viewModel = viewModel
    }

    func handleScreenLocked() {
        isLocked = true
        viewModel?.closeForLockScreen()
        TimerControlWindowManager.shared.hide(animated: false)
        LockScreenTimerWidgetManager.shared.handleLockStateChange(isLocked: true)
    }

    func handleScreenUnlocked() {
        isLocked = false
        LockScreenTimerWidgetManager.shared.handleLockStateChange(isLocked: false)
    }

    private static func queryCurrentLockStatus() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }
        return (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }
}
