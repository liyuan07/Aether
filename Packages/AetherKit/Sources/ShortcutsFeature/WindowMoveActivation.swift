import Foundation

struct WindowMovePreparation: Sendable {
    let hasWindows: Bool
    let isReady: Bool
}

/// Activation has its own deadline so a slow AX call cannot hold up a shortcut.
@MainActor
final class WindowMoveActivation {
    private let lease: WindowMoveLease
    private var action: ((Bool) -> Void)?
    private var timeout: Task<Void, Never>?
    private var hasWindows = false

    var isPending: Bool { action != nil }

    init(lease: WindowMoveLease, action: @escaping (Bool) -> Void) {
        self.lease = lease
        self.action = action
    }

    func startTimeout(nanoseconds: UInt64 = 350_000_000) {
        timeout?.cancel()
        timeout = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: nanoseconds) }
            catch { return }
            self?.activate()
        }
    }

    func receive(_ preparation: WindowMovePreparation) {
        hasWindows = preparation.hasWindows
        if preparation.isReady { activate() }
    }

    func activate() {
        let pending = action
        cancel()
        guard lease.isActive() else { return }
        pending?(hasWindows)
    }

    func cancel() {
        action = nil
        timeout?.cancel()
        timeout = nil
    }
}
