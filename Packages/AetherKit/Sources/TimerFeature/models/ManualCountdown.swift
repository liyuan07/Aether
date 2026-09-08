import Foundation

/// The display timer samples this state; missed callbacks never lose elapsed time.
struct ManualCountdown {
    private var deadline: TimeInterval?
    private var pausedRemaining: TimeInterval?
    var isActive: Bool { deadline != nil || pausedRemaining != nil }
    var isPaused: Bool { pausedRemaining != nil }
    mutating func start(duration: TimeInterval, now: TimeInterval) -> Bool {
        guard duration.isFinite, duration > 0 else { return false }
        deadline = now + duration
        pausedRemaining = nil
        return true
    }
    func remaining(at now: TimeInterval) -> TimeInterval {
        pausedRemaining ?? deadline.map { $0 - now } ?? 0
    }
    mutating func pause(at now: TimeInterval) {
        guard deadline != nil else { return }
        pausedRemaining = remaining(at: now)
        deadline = nil
    }
    mutating func resume(at now: TimeInterval) {
        guard let pausedRemaining else { return }
        deadline = now + pausedRemaining
        self.pausedRemaining = nil
    }
    mutating func stop() { deadline = nil; pausedRemaining = nil }
}
