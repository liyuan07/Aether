import XCTest
@testable import SharedSupport
final class LegacyApplicationTests: XCTestCase {
    func testPredecessorsOpenUnifiedFeatures() {
        XCTAssertEqual(LegacyApplication.route(identifier: "com.liyuan07.clipboard", path: ""), .clipboard)
        XCTAssertEqual(LegacyApplication.route(identifier: "com.liyuan.keypilot", path: ""), .settings(.shortcuts))
        XCTAssertEqual(LegacyApplication.route(identifier: nil, path: "/Applications/package counter.app"), .overview)
    }
    func testExplicitUnrelatedIdentityDoesNotGetHijackedByFilename() {
        XCTAssertNil(LegacyApplication.route(identifier: "org.example.clipboard", path: "/Applications/Clipboard.app"))
        XCTAssertNil(LegacyApplication.route(identifier: nil, path: "/Applications/My Clipboard.app"))
    }
}
