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

import Foundation
import ServiceManagement

@MainActor
final class LaunchAtLoginManager: ObservableObject {
    static let shared = LaunchAtLoginManager()

    @Published private(set) var isEnabled: Bool
    @Published private(set) var errorMessage: String?

    private static let preferenceKey = "launchAtLogin"

    private init() {
        if let savedValue = UserDefaults.standard.object(forKey: Self.preferenceKey) as? Bool {
            isEnabled = savedValue
        } else {
            isEnabled = true
            UserDefaults.standard.set(true, forKey: Self.preferenceKey)
        }
    }

    func synchronizeWithSavedPreference() {
        apply(isEnabled, reportErrors: false)
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        apply(enabled, reportErrors: true)
    }

    private func apply(_ enabled: Bool, reportErrors: Bool) {
        do {
            let service = SMAppService.mainApp

            if enabled {
                if service.status == .notRegistered || service.status == .notFound {
                    try service.register()
                }
            } else if service.status != .notRegistered {
                try service.unregister()
            }

            isEnabled = enabled
            errorMessage = nil
            UserDefaults.standard.set(enabled, forKey: Self.preferenceKey)
        } catch {
            if reportErrors {
                errorMessage = "无法更新开机启动：\(error.localizedDescription)"
            }
        }
    }
}
