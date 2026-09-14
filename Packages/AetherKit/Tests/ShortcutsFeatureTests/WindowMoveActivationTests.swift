import Testing
@testable import ShortcutsFeature

@Test @MainActor func existingWindowsActivateOnlyAfterPlacementIsConfirmed() {
    var activations: [Bool] = []
    let activation = WindowMoveActivation(lease: WindowMoveLease()) { activations.append($0) }
    activation.receive(WindowMovePreparation(hasWindows: true, isReady: false))
    #expect(activations.isEmpty)
    #expect(activation.isPending)

    activation.receive(WindowMovePreparation(hasWindows: true, isReady: true))
    activation.activate() // A racing deadline must not activate twice.
    #expect(activations == [true])
    #expect(!activation.isPending)
}

@Test @MainActor func slowWindowPreparationDoesNotBlockActivationDeadline() async {
    var activations: [Bool] = []
    var activation: WindowMoveActivation!
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        activation = WindowMoveActivation(lease: WindowMoveLease()) {
            activations.append($0)
            if activations.count == 1 { continuation.resume() }
        }
        activation.receive(WindowMovePreparation(hasWindows: true, isReady: false))
        activation.startTimeout(nanoseconds: 1_000_000)
        // No scan completion: the deadline must work independently of AX.
    }
    #expect(activations == [true])
    activation.receive(WindowMovePreparation(hasWindows: true, isReady: true))
    #expect(activations == [true])
}

@Test @MainActor func supersededActivationCannotStealFocusAfterLateScan() {
    var events: [String] = []
    let old = WindowMoveActivation(lease: WindowMoveLease()) { _ in events.append("old") }
    old.startTimeout()
    old.cancel()
    let latest = WindowMoveActivation(lease: WindowMoveLease()) { _ in events.append("latest") }
    latest.receive(WindowMovePreparation(hasWindows: true, isReady: true))
    old.receive(WindowMovePreparation(hasWindows: true, isReady: true))
    old.activate()
    #expect(events == ["latest"])
}

@Test @MainActor func cancelledMoveCannotActivateFromAnInFlightScan() {
    let lease = WindowMoveLease()
    var didActivate = false
    let activation = WindowMoveActivation(lease: lease) { _ in didActivate = true }
    lease.cancel()
    activation.receive(WindowMovePreparation(hasWindows: true, isReady: true))
    #expect(!didActivate)
    #expect(!activation.isPending)
}

@Test @MainActor func windowlessApplicationCanReopenImmediately() {
    var activations: [Bool] = []
    let activation = WindowMoveActivation(lease: WindowMoveLease()) { activations.append($0) }
    activation.receive(WindowMovePreparation(hasWindows: false, isReady: true))
    #expect(activations == [false])
}

@Test @MainActor func expiredMoveCannotActivate() {
    var didActivate = false
    let activation = WindowMoveActivation(lease: WindowMoveLease(now: -20)) { _ in didActivate = true }
    activation.activate()
    #expect(!didActivate)
}
