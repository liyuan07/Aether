import XCTest
@testable import TimerFeature

final class SettingsDurationOptionsTests: XCTestCase {
    func testExistingOffGridDurationsRemainSelectableWithoutRounding() {
        let work = SettingsDurationOptions.values(in: 300...3600, step: 300, current: 303)
        XCTAssertTrue(work.contains(303))
        XCTAssertEqual(work.first, 300)
        XCTAssertEqual(work.last, 3600)
        XCTAssertEqual(work.count, 13)
        let rest = SettingsDurationOptions.values(in: 20...300, step: 10, current: 42.5)
        XCTAssertTrue(rest.contains(42.5))
        XCTAssertEqual(rest, rest.sorted())
    }
    func testChoicesIncludeUpperBoundaryAndDoNotDuplicateCurrentValue() {
        XCTAssertEqual(SettingsDurationOptions.values(in: 20...45, step: 10, current: 30), [20, 30, 40, 45])
        XCTAssertEqual(SettingsDurationOptions.values(in: 20...45, step: 10, current: .nan), [20, 30, 40, 45])
    }
}
