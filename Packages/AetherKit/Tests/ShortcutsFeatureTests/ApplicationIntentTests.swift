import Testing
@testable import ShortcutsFeature

@Test func newerActionInvalidatesEveryStageOfThePreviousAction() {
    let intent = ApplicationIntent()
    let old = intent.begin(sourcePID: 1, targetPID: 2)
    let oldMove = WindowMoveLease(action: old)
    let latest = intent.begin(sourcePID: 1, targetPID: 3)
    #expect(!old.isActive() && !oldMove.isActive())
    #expect(!old.canSend(to: 2, frontmostPID: 2))
    #expect(latest.canSend(to: 3, frontmostPID: 3))
}

@Test func physicalInputInvalidatesQueuedActivationAndNewWindowCommand() {
    let intent = ApplicationIntent()
    let before = intent.revision
    let action = intent.begin(sourcePID: 1, targetPID: 2)
    intent.interrupt()
    #expect(intent.revision != before)
    #expect(!action.isActive() && !action.canSend(to: 2, frontmostPID: 2))
}

@Test func delayedColdLaunchCompletionCannotReviveCancelledAction() {
    let intent = ApplicationIntent()
    let launch = intent.begin(sourcePID: 1)
    intent.applicationActivated(pid: 3)
    launch.setTarget(2) // NSWorkspace completion arrives later.
    #expect(!launch.isActive())
    #expect(!launch.canSend(to: 2, frontmostPID: 2))
}

@Test func targetActivationIsAllowedButAnotherApplicationCancelsTheRequest() {
    let intent = ApplicationIntent()
    let action = intent.begin(sourcePID: 1, targetPID: 2)
    intent.applicationActivated(pid: 2)
    #expect(action.isActive())
    intent.applicationActivated(pid: 3)
    #expect(!action.isActive())
}

@Test func commandRequiresBothTheExpectedProcessAndActualForeground() {
    let token = ApplicationActionToken(sourcePID: 1, targetPID: 2)
    #expect(token.canSend(to: 2, frontmostPID: 2))
    #expect(!token.canSend(to: 2, frontmostPID: 3))
    #expect(!token.canSend(to: 3, frontmostPID: 3))
    #expect(!token.canSend(to: 2, frontmostPID: nil))
}

@Test func movementTimeoutDoesNotCancelIntentButPreventsFurtherWrites() {
    let token = ApplicationActionToken(sourcePID: 1, targetPID: 2)
    let move = WindowMoveLease(duration: 0.35, action: token)
    #expect(move.isActive(now: move.deadline - 0.01))
    #expect(!move.isActive(now: move.deadline))
    move.cancel()
    #expect(!move.isActive() && token.isActive())
}

@Test func switchingBackToTheOriginalApplicationAlsoCancelsAfterTargetActivation() {
    let intent = ApplicationIntent()
    let action = intent.begin(sourcePID: 1, targetPID: 2)
    intent.applicationActivated(pid: 2)
    intent.applicationActivated(pid: 1)
    #expect(!action.isActive())
}
