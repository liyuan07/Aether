import SharedSupport
/*
 * Clipboard
 * Copyright (C) 2026 Li Yuan
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import CAetherCore
import AppKit
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ClipboardStorage {
    static let archiveDirectory: URL = {
        return createDirectory(AppEnvironment.directory("Clipboard"))
    }()

    static let imagesDirectory = createDirectory(
        archiveDirectory.appendingPathComponent("Images", isDirectory: true)
    )
    static let payloadsDirectory = createDirectory(
        archiveDirectory.appendingPathComponent("Payloads", isDirectory: true)
    )
    static let exportsDirectory = createDirectory(
        archiveDirectory.appendingPathComponent("Image Exports", isDirectory: true)
    )
    static let archiveURL = archiveDirectory.appendingPathComponent("history.json")

    private static func createDirectory(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }
}

private struct PersistedImagePayload {
    let data: Data
    let fileExtension: String
    let hash: String

    var fileName: String {
        "clipboard_image_\(hash).\(fileExtension)"
    }

    var preview: String {
        "Image (\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)))"
    }
}

private func persistedImagePayload(
    data originalData: Data,
    fileExtension originalExtension: String
) -> PersistedImagePayload {
    let cleanedExtension = originalExtension
        .lowercased()
        .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    var data = originalData
    var fileExtension = cleanedExtension.isEmpty ? "png" : cleanedExtension

    if ["tif", "tiff"].contains(fileExtension),
       let source = CGImageSourceCreateWithData(originalData as CFData, nil),
       CGImageSourceGetCount(source) == 1 {
        let encoded = NSMutableData()
        if let destination = CGImageDestinationCreateWithData(
            encoded,
            UTType.png.identifier as CFString,
            1,
            nil
        ) {
            CGImageDestinationAddImageFromSource(destination, source, 0, nil)
            if CGImageDestinationFinalize(destination), encoded.length > 0 {
                data = encoded as Data
                fileExtension = "png"
            }
        }
    }

    let hash = SHA256.hash(data: data)
        .map { String(format: "%02x", $0) }
        .joined()
    return PersistedImagePayload(
        data: data,
        fileExtension: fileExtension,
        hash: hash
    )
}

enum ClipboardItemType: String, CaseIterable, Codable, Sendable {
    case text
    case url
    case file
    case image
    case rtf
    case unknown

    var icon: String {
        switch self {
        case .text: return "text.alignleft"
        case .url: return "link"
        case .file: return "doc.fill"
        case .image: return "photo"
        case .rtf: return "doc.richtext"
        case .unknown: return "questionmark.circle"
        }
    }

    var displayName: String {
        switch self {
        case .text: return "文本"
        case .url: return "链接"
        case .file: return "文件"
        case .image: return "图片"
        case .rtf: return "富文本"
        case .unknown: return "未知"
        }
    }
}

struct ClipboardItem: Identifiable, Codable, Sendable {
    let id: UUID
    let type: ClipboardItemType
    let timestamp: Date
    var preview: String
    var isPinned: Bool
    let stringData: String?
    var imageFileName: String?
    var imageContentHash: String?
    let fileURLs: [String]?
    var rtfData: Data?
    var rtfFileName: String?

    init(
        id: UUID = UUID(),
        stringData: String,
        type: ClipboardItemType,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.type = type
        self.timestamp = timestamp
        preview = Self.generatePreview(stringData: stringData, type: type)
        isPinned = false
        self.stringData = stringData
        imageFileName = nil
        imageContentHash = nil
        fileURLs = nil
        rtfData = nil
        rtfFileName = nil
    }

    init(
        id: UUID = UUID(),
        fileURLs: [String],
        timestamp: Date = Date()
    ) {
        self.id = id
        type = .file
        self.timestamp = timestamp
        preview = fileURLs.count == 1
            ? Self.fileName(from: fileURLs[0])
            : "\(fileURLs.count) files"
        isPinned = false
        stringData = nil
        imageFileName = nil
        imageContentHash = nil
        self.fileURLs = fileURLs
        rtfData = nil
        rtfFileName = nil
    }

    init(
        id: UUID = UUID(),
        rtfData: Data,
        plainText: String,
        timestamp: Date = Date()
    ) {
        self.id = id
        type = .rtf
        self.timestamp = timestamp
        preview = String(plainText.prefix(120))
        isPinned = false
        stringData = plainText
        imageFileName = nil
        imageContentHash = nil
        fileURLs = nil
        self.rtfData = nil

        let fileName = "clipboard_rtf_\(UUID().uuidString).rtf"
        let fileURL = ClipboardStorage.payloadsDirectory.appendingPathComponent(fileName)
        if (try? rtfData.write(to: fileURL, options: .atomic)) != nil {
            rtfFileName = fileName
        } else {
            rtfFileName = nil
            self.rtfData = rtfData
        }
    }

    static func makeImage(
        id: UUID = UUID(),
        data: Data,
        fileExtension: String,
        timestamp: Date = Date()
    ) -> ClipboardItem? {
        let payload = persistedImagePayload(
            data: data,
            fileExtension: fileExtension
        )
        let fileURL = ClipboardStorage.imagesDirectory
            .appendingPathComponent(payload.fileName)
        do {
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                try payload.data.write(to: fileURL, options: .atomic)
            }
        } catch {
            return nil
        }

        return ClipboardItem(
            id: id,
            type: .image,
            timestamp: timestamp,
            preview: payload.preview,
            isPinned: false,
            stringData: nil,
            imageFileName: payload.fileName,
            imageContentHash: payload.hash,
            fileURLs: nil,
            rtfData: nil,
            rtfFileName: nil
        )
    }

    private init(
        id: UUID,
        type: ClipboardItemType,
        timestamp: Date,
        preview: String,
        isPinned: Bool,
        stringData: String?,
        imageFileName: String?,
        imageContentHash: String?,
        fileURLs: [String]?,
        rtfData: Data?,
        rtfFileName: String?
    ) {
        self.id = id
        self.type = type
        self.timestamp = timestamp
        self.preview = preview
        self.isPinned = isPinned
        self.stringData = stringData
        self.imageFileName = imageFileName
        self.imageContentHash = imageContentHash
        self.fileURLs = fileURLs
        self.rtfData = rtfData
        self.rtfFileName = rtfFileName
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case type
        case timestamp
        case preview
        case isPinned
        case stringData
        case imageFileName
        case imageContentHash
        case fileURLs
        case rtfData
        case rtfFileName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        type = try container.decodeIfPresent(
            ClipboardItemType.self,
            forKey: .type
        ) ?? .unknown
        timestamp = try container.decodeIfPresent(
            Date.self,
            forKey: .timestamp
        ) ?? Date()
        isPinned = try container.decodeIfPresent(
            Bool.self,
            forKey: .isPinned
        ) ?? false
        stringData = try container.decodeIfPresent(
            String.self,
            forKey: .stringData
        )
        imageFileName = try container.decodeIfPresent(
            String.self,
            forKey: .imageFileName
        )
        imageContentHash = try container.decodeIfPresent(
            String.self,
            forKey: .imageContentHash
        )
        fileURLs = try container.decodeIfPresent(
            [String].self,
            forKey: .fileURLs
        )
        rtfData = try container.decodeIfPresent(Data.self, forKey: .rtfData)
        rtfFileName = try container.decodeIfPresent(
            String.self,
            forKey: .rtfFileName
        )
        preview = try container.decodeIfPresent(
            String.self,
            forKey: .preview
        ) ?? Self.generatePreview(stringData: stringData ?? "", type: type)
    }

    /// Platform DTO conversion only; Rust owns parsing, validation and field-presence policy.
    init(archiveRecord record: AetherClipboardArchiveItem, fileURLs: [String]?) throws {
        func has(_ bit: UInt16) -> Bool { record.present & bit != 0 }
        func optional(_ bytes: AetherBytes, _ bit: UInt16) -> String? { has(bit) ? clipboardArchiveText(bytes) : nil }
        if has(1) {
            guard let uuid = UUID(uuidString: clipboardArchiveText(record.id)) else { throw CocoaError(.fileReadCorruptFile) }
            id = uuid
        } else { id = UUID() }
        switch record.kind {
        case 0: type = .text
        case 1: type = .url
        case 2: type = .file
        case 3: type = .image
        case 4: type = .rtf
        default: type = .unknown
        }
        timestamp = has(2) ? Date(timeIntervalSinceReferenceDate: record.timestamp) : Date()
        isPinned = record.pinned != 0
        stringData = optional(record.string_data, 8)
        imageFileName = optional(record.image_file_name, 16)
        imageContentHash = optional(record.image_content_hash, 32)
        self.fileURLs = fileURLs
        if has(128) {
            guard let data = Data(base64Encoded: clipboardArchiveText(record.rtf_data)) else { throw CocoaError(.fileReadCorruptFile) }
            rtfData = data
        } else { rtfData = nil }
        rtfFileName = optional(record.rtf_file_name, 256)
        preview = optional(record.preview, 4) ?? Self.generatePreview(stringData: stringData ?? "", type: type)
    }

    var displayPreview: String {
        type == .url ? (stringData ?? preview) : preview
    }

    var detailText: String? {
        switch type {
        case .text, .url, .rtf, .unknown:
            return stringData ?? preview
        case .file, .image:
            return nil
        }
    }

    var fileDetailPaths: [String] {
        guard type == .file else { return [] }
        return (fileURLs ?? []).map { Self.fileURL(from: $0).path }
    }

    var filePathPreview: String? {
        guard type == .file, let fileURLs, !fileURLs.isEmpty else {
            return nil
        }
        var seen = Set<String>()
        let directories = fileURLs.compactMap(Self.fileDirectory)
            .filter { seen.insert($0).inserted }
        guard let firstDirectory = directories.first else { return nil }
        guard directories.count > 1 else { return firstDirectory }
        return "\(firstDirectory) · 另有 \(directories.count - 1) 个位置"
    }

    var imageFileURL: URL? {
        guard let imageFileName else { return nil }
        let url = ClipboardStorage.imagesDirectory
            .appendingPathComponent(imageFileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    var imagePasteboardType: NSPasteboard.PasteboardType {
        guard let imageFileName,
              let type = UTType(
                filenameExtension: URL(fileURLWithPath: imageFileName).pathExtension
              ) else {
            return .png
        }
        return NSPasteboard.PasteboardType(type.identifier)
    }

    func getImageData() -> Data? {
        guard let imageFileURL else { return nil }
        return try? Data(contentsOf: imageFileURL)
    }

    func getRTFData() -> Data? {
        if let rtfFileName {
            return try? Data(
                contentsOf: ClipboardStorage.payloadsDirectory
                    .appendingPathComponent(rtfFileName)
            )
        }
        return rtfData
    }

    var searchableSegments: [String] {
        switch type {
        case .text, .url, .rtf, .unknown:
            return [stringData, type.displayName].compactMap { $0 }
        case .file:
            return [type.displayName] + (fileURLs ?? []).flatMap { urlString in
                [Self.fileName(from: urlString), Self.fileDirectory(from: urlString)]
                    .compactMap { $0 }
            }
        case .image:
            return [type.displayName]
        }
    }

    func hasSameContent(as other: ClipboardItem) -> Bool {
        rustClipboardContentMatches(self, other)
    }

    private static func generatePreview(
        stringData: String,
        type: ClipboardItemType
    ) -> String {
        switch type {
        case .url:
            return stringData
        case .file:
            return fileName(from: stringData)
        case .image:
            return "Image"
        default:
            return String(stringData.prefix(120))
        }
    }

    private static func fileName(from urlString: String) -> String {
        let name = fileURL(from: urlString).lastPathComponent
        return name.isEmpty ? urlString : name
    }

    private static func fileDirectory(from urlString: String) -> String? {
        let directory = fileURL(from: urlString)
            .deletingLastPathComponent()
            .path
        guard !directory.isEmpty else { return nil }
        return (directory as NSString).abbreviatingWithTildeInPath
    }

    private static func fileURL(from urlString: String) -> URL {
        if let url = URL(string: urlString), url.isFileURL {
            return url
        }
        return URL(fileURLWithPath: urlString)
    }
}

struct ClipboardTextStatistics: Equatable, Sendable {
    let characterCount: Int
    let lineCount: Int
    let utf8ByteCount: Int

    init(text: String) {
        characterCount = text.count
        lineCount = Self.countLines(in: text)
        utf8ByteCount = text.utf8.count
    }

    private static func countLines(in text: String) -> Int {
        guard !text.isEmpty else { return 0 }

        var count = 1
        var previousWasCarriageReturn = false
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0D:
                count += 1
                previousWasCarriageReturn = true
            case 0x0A:
                if !previousWasCarriageReturn {
                    count += 1
                }
                previousWasCarriageReturn = false
            case 0x2028, 0x2029:
                count += 1
                previousWasCarriageReturn = false
            default:
                previousWasCarriageReturn = false
            }
        }
        return count
    }
}

struct ClipboardImageMetadata: Equatable, Sendable {
    let pixelWidth: Int
    let pixelHeight: Int
    let byteCount: Int64

    static func load(from url: URL) -> ClipboardImageMetadata? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(
                  source,
                  0,
                  nil
              ) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            return nil
        }

        let resourceValues = try? url.resourceValues(forKeys: [.fileSizeKey])
        return ClipboardImageMetadata(
            pixelWidth: width.intValue,
            pixelHeight: height.intValue,
            byteCount: Int64(resourceValues?.fileSize ?? 0)
        )
    }
}

struct ClipboardGroup: Identifiable, Codable, Sendable {
    let id: UUID
    let timestamp: Date
    var items: [ClipboardItem]

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        items: [ClipboardItem]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.items = items
    }

    var title: String {
        let counts = Dictionary(grouping: items, by: \.type)
        let order: [ClipboardItemType] = [
            .text, .url, .rtf, .image, .file, .unknown
        ]
        return order.compactMap { type in
            guard let count = counts[type]?.count, count > 0 else { return nil }
            return "\(type.displayName) \(count)"
        }
        .joined(separator: " · ")
    }

    var preview: String {
        items.prefix(3).map(\.displayPreview).joined(separator: " · ")
    }

    var searchableSegments: [String] {
        [title] + items.flatMap(\.searchableSegments)
    }
}

struct ClipboardArchive: Codable, Sendable {
    var history: [ClipboardItem]
    var pinnedItems: [ClipboardItem]
    var groups: [ClipboardGroup]?
}

enum ClipboardTab: String, CaseIterable, Identifiable, Sendable, Hashable {
    case all
    case text
    case images
    case files
    case favorites
    case groups

    var id: String { rawValue }

    var name: String {
        switch self {
        case .all: return "全部"
        case .text: return "文本"
        case .images: return "图片"
        case .files: return "文件"
        case .favorites: return "收藏"
        case .groups: return "分组"
        }
    }

    var icon: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .text: return "text.alignleft"
        case .images: return "photo"
        case .files: return "doc"
        case .favorites: return "heart.fill"
        case .groups: return "square.stack.3d.up.fill"
        }
    }

    func includes(_ item: ClipboardItem) -> Bool {
        aether_clipboard_tab_includes(rustTab, item.type.rustKind, item.isPinned ? 1 : 0) != 0
    }
}

func relativeTime(from date: Date) -> String {
    let interval = Date().timeIntervalSince(date)
    if interval < 60 {
        return "刚刚"
    }
    if interval < 3_600 {
        return "\(Int(interval / 60)) 分钟前"
    }
    if interval < 86_400 {
        return "\(Int(interval / 3_600)) 小时前"
    }
    return "\(Int(interval / 86_400)) 天前"
}
