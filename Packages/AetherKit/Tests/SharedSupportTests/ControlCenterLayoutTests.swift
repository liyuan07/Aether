import XCTest
@testable import SharedSupport

final class ControlCenterLayoutTests: XCTestCase {
    func testPermissionDeepLinkUsesSharedStartupPageWithoutChangingRouteIdentity() {
        XCTAssertEqual(SettingsPage.permissions.navigationPage, .general)
        XCTAssertEqual(SettingsPage.permissions.rawValue, "permissions")
        for page in SettingsPage.navigationPages { XCTAssertEqual(page.navigationPage, page) }
        XCTAssertEqual(Set(SettingsPage.navigationPages).count, SettingsPage.allCases.count - 1)
    }

    func testLegacyOrderRetainsUserOrderAndCompletesUnknownOrDuplicateInput() {
        XCTAssertEqual(ControlCenterDestination.entryOrder(saved: ["prompt", "overview", "memo", "prompt", "future"]),
                       [.prompt, .memo, .clipboard, .shortcuts])
        XCTAssertEqual(ControlCenterDestination.entryOrder(saved: []), [.clipboard, .shortcuts, .memo, .prompt])
        let normalized = ControlCenterDestination.entryOrder(saved: ["memo", "clipboard", "shortcuts", "prompt"])
        XCTAssertEqual(ControlCenterDestination.entryOrder(saved: normalized.map(\.rawValue)), normalized)
    }

    func testMoveBeforeWorksInBothDirectionsAndIgnoresInvalidTargets() {
        let original: [ControlCenterDestination] = [.clipboard, .shortcuts, .memo, .prompt]
        XCTAssertEqual(ControlCenterDestination.moving(.clipboard, before: .prompt, in: original),
                       [.shortcuts, .memo, .clipboard, .prompt])
        XCTAssertEqual(ControlCenterDestination.moving(.prompt, before: .clipboard, in: original),
                       [.prompt, .clipboard, .shortcuts, .memo])
        XCTAssertEqual(ControlCenterDestination.moving(.memo, before: .memo, in: original), original)
        XCTAssertEqual(ControlCenterDestination.moving(.overview, before: .memo, in: original), original)
    }

    func testNormalOpenResetsHomeAndExplicitRoutesRemainDirect() {
        XCTAssertEqual(ControlCenterDestination.opening(explicit: nil), .overview)
        for destination in ControlCenterDestination.allCases {
            XCTAssertEqual(ControlCenterDestination.opening(explicit: destination), destination)
        }
    }

    func testSavedWindowFitsDisconnectedScreenAndSmallScreen() {
        let screen = CGRect(x: -1440, y: 40, width: 1440, height: 860)
        let saved = CGRect(x: 2000, y: -800, width: 900, height: 662)
        XCTAssertEqual(SettingsWindowGeometry.fitting(saved, in: screen), CGRect(x: -900, y: 40, width: 900, height: 662))
        let small = CGRect(x: 0, y: 20, width: 800, height: 500)
        XCTAssertEqual(SettingsWindowGeometry.fitting(saved, in: small), small)
        let fitting = CGRect(x: -1300, y: 60, width: 900, height: 662)
        XCTAssertEqual(SettingsWindowGeometry.fitting(fitting, in: screen), fitting)
    }
}
