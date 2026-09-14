import XCTest
@testable import TimerFeature

final class NotchContentAlignmentTests: XCTestCase {
    func testCountdownStaysOutsidePhysicalNotchAsTextGrows() {
        for rightWidth: CGFloat in [62, 78, 102] {
            assertPhysicalNotchIsClear(leftWidth: 30, rightWidth: rightWidth)
            assertPhysicalNotchIsClear(leftWidth: 38, rightWidth: rightWidth)
        }
    }

    func testEyeCareLabelCanExpandAndCollapseOnEitherSideOfBalance() {
        for leftWidth: CGFloat in [30, 72] {
            assertPhysicalNotchIsClear(leftWidth: leftWidth, rightWidth: 62)
        }
    }

    func testRealtimeClockWithAndWithoutCountdownKeepsNotchClear() {
        assertPhysicalNotchIsClear(leftWidth: 96, rightWidth: 64)
        assertPhysicalNotchIsClear(leftWidth: 96, rightWidth: 0)
    }

    private func assertPhysicalNotchIsClear(
        leftWidth: CGFloat,
        rightWidth: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for screenCenter: CGFloat in [-756, 756, 1920] {
            for physicalWidth: CGFloat in [185, 210] {
                let middleWidth = physicalWidth + 4
                let surfacePadding = cornerRadiusInsets.closed.bottom
                let surfaceWidth = leftWidth + middleWidth + rightWidth + 2 * surfacePadding
                let surfaceOrigin = screenCenter - surfaceWidth / 2
                    + CompactNotchLiveActivityMetrics.horizontalOffset(
                        leftWingWidth: leftWidth,
                        rightWingWidth: rightWidth
                    )
                // Derive the actual HStack boundaries within ContentView's padded surface.
                let leftContentEnd = surfaceOrigin + surfacePadding + leftWidth
                let rightContentStart = leftContentEnd + middleWidth
                let physicalLeftEdge = screenCenter - physicalWidth / 2
                let physicalRightEdge = screenCenter + physicalWidth / 2

                XCTAssertLessThanOrEqual(leftContentEnd, physicalLeftEdge - 2, file: file, line: line)
                XCTAssertGreaterThanOrEqual(rightContentStart, physicalRightEdge + 2, file: file, line: line)
            }
        }
    }
}
