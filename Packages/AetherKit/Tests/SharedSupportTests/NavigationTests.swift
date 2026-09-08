import XCTest
@testable import SharedSupport
final class NavigationTests: XCTestCase {
    @MainActor func testRoutesRetainSettingsDestination() {
        var received: AppRoute?
        AppRouter.shared.handler = { received = $0 }
        AppRouter.shared.send(.settings(.timer))
        XCTAssertEqual(received, .settings(.timer))
        AppRouter.shared.handler = nil
    }
}
