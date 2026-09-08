import CoreGraphics
import XCTest
@testable import SharedSupport
final class SyntheticInputTests: XCTestCase {
    func testPasteEventsAreExcludedFromShortcutRedispatch() throws {
        let keyDown = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true))
        let keyUp = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false))
        XCTAssertFalse(SyntheticInput.isOurs(keyDown))
        for event in [keyDown, keyUp] {
            SyntheticInput.tag(event)
            XCTAssertTrue(SyntheticInput.isOurs(event))
            XCTAssertEqual(event.getIntegerValueField(.keyboardEventKeycode), 9)
        }
    }
}
