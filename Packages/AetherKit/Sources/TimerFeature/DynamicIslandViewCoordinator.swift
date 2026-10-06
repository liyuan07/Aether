import SharedSupport
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
    @AppStorage("timerLiveActivityEnabled", store: AppEnvironment.appDefaults) var timerLiveActivityEnabled = true
    @Published var preferredScreen: String {
        didSet {
            AppEnvironment.appDefaults.set(preferredScreen, forKey: "preferred_screen_name")
            selectedScreen = preferredScreen
            NotificationCenter.default.post(name: .selectedScreenChanged, object: nil)
        }
    }

    private init() {
        let screenName = NSScreen.main?.localizedName ?? "Unknown"
        let persisted = AppEnvironment.appDefaults.string(forKey: "preferred_screen_name") ?? screenName
        preferredScreen = persisted
        selectedScreen = persisted
    }
}
