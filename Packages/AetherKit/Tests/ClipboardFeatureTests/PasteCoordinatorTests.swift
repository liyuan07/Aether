import XCTest
@testable import ClipboardFeature

final class PasteCoordinatorTests: XCTestCase {
    func testTextCompatibleGroupUsesOnePaste() {
        XCTAssertTrue(
            ClipboardGroupPastePlan.usesSinglePaste(
                for: [.text, .url, .rtf]
            )
        )
    }

    func testImageGroupPastesEachImageSeparately() {
        XCTAssertFalse(
            ClipboardGroupPastePlan.usesSinglePaste(
                for: [.image, .image, .image]
            )
        )
    }

    func testMixedGroupPastesEachItemSeparately() {
        XCTAssertFalse(
            ClipboardGroupPastePlan.usesSinglePaste(
                for: [.image, .text]
            )
        )
    }

    func testImageGetsLongerProcessingTimeThanText() {
        let imageDelay = ClipboardGroupPastePlan.delayNanoseconds(after: .image)
        let textDelay = ClipboardGroupPastePlan.delayNanoseconds(after: .text)

        XCTAssertGreaterThanOrEqual(imageDelay, 1_500_000_000)
        XCTAssertGreaterThan(imageDelay, textDelay)
    }
}
