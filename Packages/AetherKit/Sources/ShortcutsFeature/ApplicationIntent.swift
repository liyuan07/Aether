import Foundation
import CAetherCore

/// Shared with the event-tap thread: interruption is visible before another AX write.
final class ApplicationIntent: @unchecked Sendable {
    static let shared = ApplicationIntent()
    private let lock = NSLock()
    private var state = AetherApplicationIntent()
    private var current: ApplicationActionToken?

    var revision: UInt64 { lock.withLock { state.revision } }

    func interrupt() {
        lock.withLock {
            state = aether_application_intent_update(state, 1, 0)
            if state.cancel != 0 { current?.cancel() }
            if state.clear != 0 { current = nil }
        }
    }

    func begin(sourcePID: Int32?, targetPID: Int32? = nil) -> ApplicationActionToken {
        lock.withLock {
            state = aether_application_intent_update(state, 0, 0)
            if state.cancel != 0 { current?.cancel() }
            let token = ApplicationActionToken(sourcePID: sourcePID, targetPID: targetPID)
            current = token
            return token
        }
    }

    func applicationActivated(pid: Int32) {
        lock.withLock {
            let accepted = current?.acceptsActivation(of: pid) ?? true
            state = aether_application_intent_update(state, 2, accepted ? 1 : 0)
            if state.cancel != 0 { current?.cancel() }
            if state.clear != 0 { current = nil }
        }
    }
}

final class ApplicationActionToken: @unchecked Sendable {
    let id = UUID()
    private let lock = NSLock()
    private var state: AetherApplicationAction

    init(sourcePID: Int32?, targetPID: Int32? = nil, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        state = aether_application_action_create(sourcePID ?? 0, sourcePID == nil ? 0 : 1,
            targetPID ?? 0, targetPID == nil ? 0 : 1, now)
    }

    func setTarget(_ pid: Int32) { lock.withLock { state = aether_application_action_target(state, pid) } }
    func cancel() { lock.withLock { state = aether_application_action_cancel(state) } }
    func isActive(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        lock.withLock { aether_application_action_active(state, now) != 0 }
    }
    func acceptsActivation(of pid: Int32) -> Bool {
        lock.withLock {
            let result = aether_application_action_activate(state, pid)
            state = result.state
            return result.accepted != 0
        }
    }
    func canSend(to pid: Int32, frontmostPID: Int32?) -> Bool {
        isActive() && lock.withLock {
            aether_application_action_matches(state, pid, frontmostPID ?? 0, frontmostPID == nil ? 0 : 1) != 0
        }
    }
}
