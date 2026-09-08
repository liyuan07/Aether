import XCTest
@testable import ClipboardFeature

final class ApplicationLifecycleTests: XCTestCase {
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
