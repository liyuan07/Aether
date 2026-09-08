import XCTest
@testable import Clipboard

final class ApplicationLifecycleTests: XCTestCase {
    @MainActor
    func testStatusMenuIncludesRestartBeforeQuit() {
        let titles = StatusItemController.shared.makeMenu().items
            .filter { !$0.isSeparatorItem }
            .map(\.title)

        guard let restartIndex = titles.firstIndex(of: "重启 Clipboard"),
              let quitIndex = titles.firstIndex(of: "退出 Clipboard") else {
            return XCTFail("Restart and quit items should both be present")
        }
        XCTAssertLessThan(restartIndex, quitIndex)
    }

    @MainActor
    func testRestartHelperPassesPidAndBundlePathAsPositionalArguments() {
        let bundlePath = "/Applications/Clipboard Test.app"
        let arguments = ApplicationRestartController.helperArguments(
            processIdentifier: 12_345,
            bundlePath: bundlePath
        )

        XCTAssertEqual(arguments[3], "12345")
        XCTAssertEqual(arguments[4], bundlePath)
        XCTAssertTrue(arguments[1].contains("kill -0 \"$1\""))
        XCTAssertTrue(arguments[1].contains("open \"$2\""))
    }
}
