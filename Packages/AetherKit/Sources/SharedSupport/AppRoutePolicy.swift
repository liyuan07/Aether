// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import CAetherCore

/// Platform-independent readiness/routing decisions; the app owns effect execution and windows.
public enum AppRoutePolicy {
    public static func plan(for route: AppRoute, ready: Bool) -> AetherAppRoutePlan {
        let code: UInt8
        switch route { case .overview: code = 0; case .clipboard: code = 1; case .prompt: code = 2
        case .settings: code = 3; case .dismissPanels: code = 4 }
        return aether_app_route_plan(code, ready ? 1 : 0)
    }
}
