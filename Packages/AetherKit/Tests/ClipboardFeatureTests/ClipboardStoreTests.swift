/*
 * Clipboard
 * Copyright (C) 2026 Li Yuan
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import XCTest
@testable import Clipboard

final class ClipboardStoreTests: XCTestCase {
    func testBackgroundResultsAreInsertedByCaptureTime() {
        let base = Date(timeIntervalSince1970: 1_000)
        let newest = ClipboardItem(
            stringData: "newest",
            type: .text,
            timestamp: base.addingTimeInterval(30)
        )
        let oldest = ClipboardItem(
            stringData: "oldest",
            type: .text,
            timestamp: base.addingTimeInterval(10)
        )
        let middle = ClipboardItem(
            stringData: "middle",
            type: .text,
            timestamp: base.addingTimeInterval(20)
        )

        let update = clipboardHistoryByInserting(
            middle,
            into: [newest, oldest],
            limit: 10
        )

        XCTAssertEqual(update.items.map(\.id), [newest.id, middle.id, oldest.id])
        XCTAssertTrue(update.didInsert)
    }

    func testLateOlderDuplicateCannotReplaceNewerCapture() {
        let base = Date(timeIntervalSince1970: 1_000)
        let newer = ClipboardItem(
            stringData: "same value",
            type: .text,
            timestamp: base.addingTimeInterval(20)
        )
        let older = ClipboardItem(
            stringData: "same value",
            type: .text,
            timestamp: base.addingTimeInterval(10)
        )

        let update = clipboardHistoryByInserting(
            older,
            into: [newer],
            limit: 10
        )

        XCTAssertEqual(update.items.map(\.id), [newer.id])
        XCTAssertFalse(update.didInsert)
    }

    func testHistoryLimitKeepsProtectedItemWhenPossible() {
        let base = Date(timeIntervalSince1970: 1_000)
        let newest = ClipboardItem(
            stringData: "newest",
            type: .text,
            timestamp: base.addingTimeInterval(30)
        )
        let middle = ClipboardItem(
            stringData: "middle",
            type: .text,
            timestamp: base.addingTimeInterval(20)
        )
        let protected = ClipboardItem(
            stringData: "protected",
            type: .text,
            timestamp: base.addingTimeInterval(10)
        )

        let update = clipboardHistoryByInserting(
            newest,
            into: [middle, protected],
            limit: 2,
            protecting: [protected.id]
        )

        XCTAssertEqual(update.items.map(\.id), [newest.id, protected.id])
    }
}
