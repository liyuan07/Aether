// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CAetherCore

/// Rust value state; Swift only supplies the continuous clock and renders it.
struct ManualCountdown {
    private var core = AetherCountdown()
    var isActive: Bool { core.phase != 0 }
    var isPaused: Bool { core.phase == 2 }
    mutating func start(duration: TimeInterval, now: TimeInterval) -> Bool {
        guard duration.isFinite, duration > 0 else { return false }
        core = aether_countdown_start(core, duration, now)
        return true
    }
    func remaining(at now: TimeInterval) -> TimeInterval { aether_countdown_remaining(core, now) }
    mutating func pause(at now: TimeInterval) { core = aether_countdown_pause(core, now) }
    mutating func resume(at now: TimeInterval) { core = aether_countdown_resume(core, now) }
    mutating func stop() { core = AetherCountdown() }
}
