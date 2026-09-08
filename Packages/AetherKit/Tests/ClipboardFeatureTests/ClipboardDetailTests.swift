/*
 * Clipboard
 * Copyright (C) 2026 Li Yuan
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import AppKit
import XCTest
@testable import Clipboard

final class ClipboardDetailTests: XCTestCase {
    func testDetailTextUsesFullStringInsteadOfTruncatedPreview() {
        let text = String(repeating: "内容", count: 100)
        let item = ClipboardItem(stringData: text, type: .text)

        XCTAssertEqual(item.detailText, text)
        XCTAssertLessThan(item.preview.count, text.count)
    }

    func testRichTextDetailFallsBackToPlainText() throws {
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "type": "rtf",
          "timestamp": 0,
          "preview": "完整纯文本内容",
          "isPinned": false,
          "stringData": "完整纯文本内容"
        }
        """
        let item = try JSONDecoder().decode(
            ClipboardItem.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(item.detailText, "完整纯文本内容")
    }

    func testTextStatisticsHandleCommonAndUnicodeLineEndings() {
        let statistics = ClipboardTextStatistics(
            text: "第一行\r\nsecond\rthird\u{2028}fourth\u{2029}第五行"
        )

        XCTAssertEqual(statistics.lineCount, 5)
        XCTAssertGreaterThan(statistics.utf8ByteCount, statistics.characterCount)
    }

    func testFileDetailPathsPreserveOrderAndDecodeFileURLs() {
        let item = ClipboardItem(fileURLs: [
            "file:///tmp/First%20Folder/report.pdf",
            "file:///tmp/Second/notes.txt"
        ])

        XCTAssertEqual(item.fileDetailPaths, [
            "/tmp/First Folder/report.pdf",
            "/tmp/Second/notes.txt"
        ])
    }

    func testImageMetadataReadsDimensionsAndFileSize() throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 3,
            pixelsHigh: 2,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let data = try XCTUnwrap(
            bitmap.representation(using: .png, properties: [:])
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-detail-\(UUID().uuidString).png")
        try data.write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        let metadata = try XCTUnwrap(ClipboardImageMetadata.load(from: url))

        XCTAssertEqual(metadata.pixelWidth, 3)
        XCTAssertEqual(metadata.pixelHeight, 2)
        XCTAssertEqual(metadata.byteCount, Int64(data.count))
    }

    func testGroupSummaryKeepsStableTypeOrder() {
        let group = ClipboardGroup(items: [
            ClipboardItem(fileURLs: ["file:///tmp/report.pdf"]),
            ClipboardItem(stringData: "https://example.com", type: .url),
            ClipboardItem(stringData: "text", type: .text)
        ])

        XCTAssertEqual(group.title, "文本 1 · 链接 1 · 文件 1")
    }
}
