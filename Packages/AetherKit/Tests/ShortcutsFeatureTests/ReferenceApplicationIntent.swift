// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
// Frozen native state transitions from e8b39b9, independent of the Rust core.
import Foundation

/// Shared with the event-tap thread: interruption is visible before another AX write.
final class ReferenceApplicationIntent: @unchecked Sendable {
    static let shared = ReferenceApplicationIntent()
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var current: ReferenceApplicationActionToken?

    var revision: UInt64 { lock.withLock { generation } }

    func interrupt() {
        lock.withLock {
            generation &+= 1
            current?.cancel()
            current = nil
        }
    }

    func begin(sourcePID: Int32?, targetPID: Int32? = nil) -> ReferenceApplicationActionToken {
        lock.withLock {
            current?.cancel()
            let token = ReferenceApplicationActionToken(sourcePID: sourcePID, targetPID: targetPID)
            current = token
            return token
        }
    }

    func applicationActivated(pid: Int32) {
        lock.withLock {
            guard let current, !current.acceptsActivation(of: pid) else { return }
            generation &+= 1
            current.cancel()
            self.current = nil
        }
    }
}

final class ReferenceApplicationActionToken: @unchecked Sendable {
    let id = UUID()
    private let lock = NSLock()
    private var cancelled = false
    private let sourcePID: Int32?
    private var targetPID: Int32?
    private var targetWasActivated: Bool
    private let deadline: TimeInterval

    init(sourcePID: Int32?, targetPID: Int32? = nil, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self.sourcePID = sourcePID
        self.targetPID = targetPID
        targetWasActivated = targetPID != nil && targetPID == sourcePID
        deadline = now + 15
    }

    func setTarget(_ pid: Int32) { lock.withLock { targetPID = pid } }
    func cancel() { lock.withLock { cancelled = true } }
    func isActive(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        lock.withLock { !cancelled && now < deadline }
    }
    func acceptsActivation(of pid: Int32) -> Bool {
        lock.withLock {
            if pid == targetPID { targetWasActivated = true; return true }
            return !targetWasActivated && pid == sourcePID
        }
    }
    func canSend(to pid: Int32, frontmostPID: Int32?) -> Bool {
        isActive() && lock.withLock { targetPID == pid && frontmostPID == pid }
    }
}

/// Cancellation is visible on the AX queue, including between individual window writes.
final class ReferenceWindowMoveLease: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private let action: ReferenceApplicationActionToken?
    let deadline: TimeInterval
    init(now: TimeInterval = ProcessInfo.processInfo.systemUptime, duration: TimeInterval = 10,
         action: ReferenceApplicationActionToken? = nil) {
        deadline = now + duration
        self.action = action
    }
    func cancel() { lock.withLock { cancelled = true } }
    func isActive(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        lock.withLock { !cancelled && now < deadline } && (action?.isActive(now: now) ?? true)
    }
}
