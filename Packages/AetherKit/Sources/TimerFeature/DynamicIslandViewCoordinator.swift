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
final class DynamicIslandViewCoordinator: ObservableObject {
    static let shared = DynamicIslandViewCoordinator()

    @Published var currentView: NotchViews = .timer
    @Published var selectedScreen: String
    @AppStorage("timerLiveActivityEnabled") var timerLiveActivityEnabled = true
    @Published var preferredScreen: String {
        didSet {
            UserDefaults.standard.set(preferredScreen, forKey: "preferred_screen_name")
            selectedScreen = preferredScreen
            NotificationCenter.default.post(name: .selectedScreenChanged, object: nil)
        }
    }

    private init() {
        let screenName = NSScreen.main?.localizedName ?? "Unknown"
        let persisted = UserDefaults.standard.string(forKey: "preferred_screen_name") ?? screenName
        preferredScreen = persisted
        selectedScreen = persisted
    }
}
