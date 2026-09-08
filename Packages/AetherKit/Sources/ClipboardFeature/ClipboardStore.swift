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
import Foundation
import ImageIO
import UniformTypeIdentifiers

private enum ClipboardSnapshot: Sendable {
    case string(String, ClipboardItemType, Date)
    case fileURLs([URL], Date)
    case image(Data, String, Date)
    case richText(Data, String?, Date)
}

private final class ClipboardPersistenceCoordinator: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "com.liyuan07.clipboard.archive-writer",
        qos: .utility
    )
    private var pendingArchive: ClipboardArchive?
    private var pendingCleanup = false
    private var pendingWorkItem: DispatchWorkItem?

    func enqueue(_ archive: ClipboardArchive, cleanup: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            pendingArchive = archive
            pendingCleanup = pendingCleanup || cleanup
            guard pendingWorkItem == nil else { return }

            let workItem = DispatchWorkItem { [weak self] in
                self?.writePendingArchive()
            }
            pendingWorkItem = workItem
            queue.asyncAfter(
                deadline: .now() + .milliseconds(120),
                execute: workItem
            )
        }
    }

    func flush(_ archive: ClipboardArchive) {
        queue.sync {
            pendingWorkItem?.cancel()
            pendingWorkItem = nil
            pendingArchive = nil
            let cleanup = pendingCleanup
            pendingCleanup = false
            write(archive, cleanup: cleanup)
        }
    }

    private func writePendingArchive() {
        let archive = pendingArchive
        let cleanup = pendingCleanup
        pendingArchive = nil
        pendingCleanup = false
        pendingWorkItem = nil
        guard let archive else { return }
        write(archive, cleanup: cleanup)
    }

    private func write(_ archive: ClipboardArchive, cleanup: Bool) {
        guard let data = try? JSONEncoder().encode(archive),
              (try? data.write(
                to: ClipboardStorage.archiveURL,
                options: .atomic
              )) != nil else {
            return
        }
        guard cleanup else { return }

        let allItems = archive.history
            + archive.pinnedItems
            + (archive.groups ?? []).flatMap(\.items)
        removeUnreferencedFiles(
            in: ClipboardStorage.imagesDirectory,
            keeping: Set(allItems.compactMap(\.imageFileName))
        )
        removeUnreferencedFiles(
            in: ClipboardStorage.payloadsDirectory,
            keeping: Set(allItems.compactMap(\.rtfFileName))
        )
    }

    private func removeUnreferencedFiles(
        in directory: URL,
        keeping names: Set<String>
    ) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return
        }
        for file in files where !names.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

private actor ClipboardSnapshotProcessor {
    func item(from snapshot: ClipboardSnapshot) -> ClipboardItem? {
        switch snapshot {
        case let .string(value, type, timestamp):
            return ClipboardItem(
                stringData: value,
                type: type,
                timestamp: timestamp
            )
        case let .fileURLs(urls, timestamp):
            for url in urls {
                if let (data, fileExtension) = readableImagePayload(at: url) {
                    return ClipboardItem.makeImage(
                        data: data,
                        fileExtension: fileExtension,
                        timestamp: timestamp
                    )
                }
            }

            let persistentFiles = urls.filter(isPersistentFileURL)
            if !persistentFiles.isEmpty {
                return ClipboardItem(
                    fileURLs: persistentFiles.map(\.absoluteString),
                    timestamp: timestamp
                )
            }
            return nil
        case let .richText(data, suppliedPlainText, timestamp):
            let plainText = suppliedPlainText ?? NSAttributedString(
                rtf: data,
                documentAttributes: nil
            )?.string
            guard let plainText, !plainText.isEmpty else { return nil }
            return ClipboardItem(
                rtfData: data,
                plainText: plainText,
                timestamp: timestamp
            )
        case let .image(data, fileExtension, timestamp):
            return ClipboardItem.makeImage(
                data: data,
                fileExtension: fileExtension,
                timestamp: timestamp
            )
        }
    }

    private func readableImagePayload(at url: URL) -> (Data, String)? {
        guard url.isFileURL,
              FileManager.default.fileExists(atPath: url.path),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let identifier = CGImageSourceGetType(source) as String?,
              let contentType = UTType(identifier),
              contentType.conforms(to: .image),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return nil
        }
        return (
            data,
            contentType.preferredFilenameExtension
                ?? (url.pathExtension.isEmpty ? "png" : url.pathExtension)
        )
    }

    private func isPersistentFileURL(_ url: URL) -> Bool {
        url.isFileURL
            && !url.path.contains("/.file/id=")
            && !url.path.contains("/tmp/")
            && !url.path.hasPrefix("/private/var/")
            && !url.path.contains("/ClipboardViewer")
            && FileManager.default.fileExists(atPath: url.path)
    }

    func duplicateIDs(
        for item: ClipboardItem,
        in history: [ClipboardItem]
    ) -> Set<UUID> {
        Set(history.lazy.filter { $0.hasSameContent(as: item) }.map(\.id))
    }
}

private actor ClipboardMaintenanceProcessor {
    func archive(
        from source: ClipboardArchive,
        expirationDays: Int,
        historyLimit: Int,
        now: Date
    ) throws -> ClipboardArchive {
        var history = try validItems(source.history)
        let pinnedItems = try validItems(source.pinnedItems)
        var uniqueGroups: [ClipboardGroup] = []
        for (offset, originalGroup) in (source.groups ?? []).enumerated() {
            if offset.isMultiple(of: 16) {
                try Task.checkCancellation()
            }
            var group = originalGroup
            group.items = try validItems(group.items)
            guard !group.items.isEmpty,
                  !uniqueGroups.contains(where: {
                    hasSameGroupItems($0.items, group.items)
                  }) else {
                continue
            }
            uniqueGroups.append(group)
        }

        if expirationDays > 0,
           let cutoff = Calendar.current.date(
            byAdding: .day,
            value: -expirationDays,
            to: now
           ) {
            history.removeAll { $0.timestamp < cutoff }
        }
        if history.count > historyLimit {
            history = Array(history.prefix(historyLimit))
        }
        try Task.checkCancellation()
        return ClipboardArchive(
            history: history,
            pinnedItems: pinnedItems,
            groups: uniqueGroups
        )
    }

    private func validItems(
        _ items: [ClipboardItem]
    ) throws -> [ClipboardItem] {
        var valid: [ClipboardItem] = []
        valid.reserveCapacity(items.count)
        for (offset, item) in items.enumerated() {
            if offset.isMultiple(of: 128) {
                try Task.checkCancellation()
            }
            guard payloadExists(for: item) else { continue }
            valid.append(item)
        }
        return valid
    }

    private func payloadExists(for item: ClipboardItem) -> Bool {
        if item.type == .image {
            guard let fileName = item.imageFileName else { return false }
            return FileManager.default.fileExists(
                atPath: ClipboardStorage.imagesDirectory
                    .appendingPathComponent(fileName).path
            )
        }
        if item.type == .rtf, let fileName = item.rtfFileName {
            return FileManager.default.fileExists(
                atPath: ClipboardStorage.payloadsDirectory
                    .appendingPathComponent(fileName).path
            )
        }
        return true
    }

    private func hasSameGroupItems(
        _ lhs: [ClipboardItem],
        _ rhs: [ClipboardItem]
    ) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { left, right in
            left.type == right.type
                && left.stringData == right.stringData
                && left.imageFileName == right.imageFileName
                && left.fileURLs == right.fileURLs
                && left.rtfFileName == right.rtfFileName
        }
    }
}

struct ClipboardHistoryUpdate {
    let items: [ClipboardItem]
    let didInsert: Bool
    let needsPayloadCleanup: Bool
}

func clipboardHistoryByInserting(
    _ item: ClipboardItem,
    into history: [ClipboardItem],
    matchingDuplicateIDs: Set<UUID>? = nil,
    limit: Int,
    protecting protectedIDs: Set<UUID> = []
) -> ClipboardHistoryUpdate {
    let duplicateItems: [ClipboardItem]
    if let matchingDuplicateIDs {
        duplicateItems = history.filter { matchingDuplicateIDs.contains($0.id) }
    } else {
        duplicateItems = history.filter { $0.hasSameContent(as: item) }
    }
    if duplicateItems.contains(where: { $0.timestamp >= item.timestamp }) {
        return ClipboardHistoryUpdate(
            items: history,
            didInsert: false,
            needsPayloadCleanup: item.type == .rtf
        )
    }

    let duplicateIDs = Set(duplicateItems.map(\.id))
    var updated = history.filter { existing in
        !duplicateIDs.contains(existing.id)
    }
    let insertionIndex = updated.firstIndex {
        $0.timestamp < item.timestamp
    } ?? updated.endIndex
    updated.insert(item, at: insertionIndex)

    var removedPayload = duplicateItems.contains {
        $0.type == .image || $0.type == .rtf
    }
    while updated.count > limit {
        guard let index = updated.lastIndex(where: {
            !protectedIDs.contains($0.id)
        }) else {
            removedPayload = removedPayload || updated.dropFirst(limit).contains {
                $0.type == .image || $0.type == .rtf
            }
            updated = Array(updated.prefix(limit))
            break
        }
        let removed = updated[index]
        removedPayload = removedPayload
            || removed.type == .image
            || removed.type == .rtf
        updated.remove(at: index)
    }

    return ClipboardHistoryUpdate(
        items: updated,
        didInsert: true,
        needsPayloadCleanup: removedPayload
    )
}

@MainActor
final class ClipboardStore: ObservableObject {
    static let shared = ClipboardStore()

    @Published private(set) var history: [ClipboardItem] = [] {
        didSet {
            historyRevision &+= 1
        }
    }
    @Published private(set) var pinnedItems: [ClipboardItem] = []
    @Published private(set) var groups: [ClipboardGroup] = []
    @Published private(set) var isMonitoring = false

    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var pendingChangeCount: Int?
    private var failedCaptureAttempts = 0
    private var historyRevision: UInt64 = 0
    private var lastMaintenanceDate = Date.distantPast
    private let persistenceCoordinator = ClipboardPersistenceCoordinator()
    private let snapshotProcessor = ClipboardSnapshotProcessor()
    private let maintenanceProcessor = ClipboardMaintenanceProcessor()
    private var maintenanceTask: Task<Void, Never>?
    private var maintenanceGeneration: UInt64 = 0

    private var historyLimit: Int {
        max(50, UserDefaults.standard.integer(forKey: PreferenceKeys.historyLimit))
    }

    private var expirationDays: Int {
        max(0, UserDefaults.standard.integer(forKey: PreferenceKeys.expirationDays))
    }

    private init() {
        loadArchive()
        performMaintenance()

        NotificationCenter.default.addObserver(
            forName: .clipboardPreferencesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.preferencesDidChange()
            }
        }
    }

    deinit {
        timer?.invalidate()
        maintenanceTask?.cancel()
    }

    func items(for tab: ClipboardTab) -> [ClipboardItem] {
        switch tab {
        case .favorites:
            return pinnedItems
        case .groups:
            return []
        case .all:
            return history.filter { !$0.isPinned }
        default:
            return history.filter { tab.includes($0) }
        }
    }

    func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true
        let monitor = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkClipboard()
            }
        }
        monitor.tolerance = 0.05
        RunLoop.main.add(monitor, forMode: .common)
        timer = monitor
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        isMonitoring = false
    }

    @discardableResult
    func copyToClipboard(_ item: ClipboardItem) -> Bool {
        let prepared = pasteboardItems(for: [item])
        guard !prepared.isEmpty else { return false }

        captureCurrentClipboardChangeIfNeeded(protecting: [item.id])

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let didWrite = pasteboard.writeObjects(prepared)
        lastChangeCount = pasteboard.changeCount
        return didWrite
    }

    @discardableResult
    func activateItem(_ item: ClipboardItem) -> Bool {
        guard copyToClipboard(item) else { return false }

        if let index = pinnedItems.firstIndex(where: { $0.id == item.id }) {
            var updated = pinnedItems
            let promoted = updated.remove(at: index)
            updated.insert(promoted, at: 0)
            pinnedItems = updated
        } else if let index = history.firstIndex(where: { $0.id == item.id }) {
            var updated = history
            let promoted = updated.remove(at: index)
            updated.insert(promoted, at: 0)
            history = updated
        }
        saveArchive()
        return true
    }

    @discardableResult
    func copyGroupToClipboard(_ group: ClipboardGroup) -> Bool {
        let textCompatible = group.items.allSatisfy {
            [.text, .url, .rtf, .unknown].contains($0.type)
                && $0.stringData != nil
        }
        let prepared: [NSPasteboardItem]
        if textCompatible,
           let combined = combinedTextPasteboardItem(for: group.items) {
            prepared = [combined]
        } else {
            prepared = pasteboardItems(for: group.items)
        }
        guard !prepared.isEmpty else { return false }

        captureCurrentClipboardChangeIfNeeded()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let didWrite = pasteboard.writeObjects(prepared)
        lastChangeCount = pasteboard.changeCount
        return didWrite
    }

    @discardableResult
    func activateGroup(_ group: ClipboardGroup) -> Bool {
        guard copyGroupToClipboard(group) else { return false }
        if let index = groups.firstIndex(where: { $0.id == group.id }) {
            var updated = groups
            let promoted = updated.remove(at: index)
            updated.insert(promoted, at: 0)
            groups = updated
        }
        saveArchive()
        return true
    }

    @discardableResult
    func createGroup(from items: [ClipboardItem]) -> ClipboardGroup? {
        var seen = Set<UUID>()
        let unique = items.filter { seen.insert($0.id).inserted }
        guard unique.count > 1 else { return nil }

        if let index = groups.firstIndex(where: {
            hasSameGroupItems($0.items, unique)
        }) {
            var updated = groups
            let existing = updated.remove(at: index)
            updated.insert(existing, at: 0)
            groups = updated
            saveArchive()
            return existing
        }

        let group = ClipboardGroup(items: unique)
        groups.insert(group, at: 0)
        saveArchive()
        return group
    }

    func togglePin(for item: ClipboardItem) {
        if item.isPinned || pinnedItems.contains(where: { $0.id == item.id }) {
            unpin(item)
        } else {
            pin(item)
        }
    }

    func delete(_ item: ClipboardItem) {
        history.removeAll { $0.id == item.id }
        pinnedItems.removeAll { $0.id == item.id }
        saveArchive(cleanup: true)
    }

    func delete(_ group: ClipboardGroup) {
        groups.removeAll { $0.id == group.id }
        saveArchive(cleanup: true)
    }

    func clear(_ tab: ClipboardTab) {
        switch tab {
        case .favorites:
            pinnedItems.removeAll()
        case .groups:
            groups.removeAll()
        default:
            history.removeAll { tab.includes($0) }
        }
        saveArchive(cleanup: true)
    }

    func performMaintenance() {
        maintenanceTask?.cancel()
        maintenanceGeneration &+= 1
        let pendingGeneration = maintenanceGeneration
        let source = currentArchive
        let sourceIdentity = archiveIdentity(source)
        let expirationDays = self.expirationDays
        let historyLimit = self.historyLimit
        let now = Date()
        lastMaintenanceDate = Date()
        maintenanceTask = Task { @MainActor [weak self, maintenanceProcessor] in
            do {
                let maintained = try await maintenanceProcessor.archive(
                    from: source,
                    expirationDays: expirationDays,
                    historyLimit: historyLimit,
                    now: now
                )
                guard !Task.isCancelled, let self else { return }
                guard maintenanceGeneration == pendingGeneration else { return }
                defer { maintenanceTask = nil }
                guard archiveIdentity(currentArchive) == sourceIdentity else {
                    return
                }
                let maintainedIdentity = archiveIdentity(maintained)
                if maintainedIdentity.historyIDs != sourceIdentity.historyIDs {
                    history = maintained.history
                }
                if maintainedIdentity.pinnedIDs != sourceIdentity.pinnedIDs {
                    pinnedItems = maintained.pinnedItems
                }
                if maintainedIdentity.groups != sourceIdentity.groups {
                    groups = maintained.groups ?? []
                }
                saveArchive(cleanup: true)
            } catch {
                if let self,
                   maintenanceGeneration == pendingGeneration {
                    maintenanceTask = nil
                }
            }
        }
    }

    func flushArchive() {
        persistenceCoordinator.flush(currentArchive)
    }

    private func preferencesDidChange() {
        if UserDefaults.standard.bool(forKey: PreferenceKeys.monitoringEnabled) {
            startMonitoring()
        } else {
            stopMonitoring()
        }
        performMaintenance()
    }

    private func pin(_ item: ClipboardItem) {
        var pinned = item
        pinned.isPinned = true
        history.removeAll { $0.id == item.id }
        if !pinnedItems.contains(where: { $0.id == item.id }) {
            pinnedItems.insert(pinned, at: 0)
        }
        saveArchive()
    }

    private func unpin(_ item: ClipboardItem) {
        pinnedItems.removeAll { $0.id == item.id }
        var unpinned = item
        unpinned.isPinned = false
        history.insert(unpinned, at: 0)
        trimHistory()
        saveArchive(cleanup: true)
    }

    private func checkClipboard() {
        if Date().timeIntervalSince(lastMaintenanceDate) >= 86_400 {
            performMaintenance()
        }
        captureCurrentClipboardChangeIfNeeded()
    }

    @discardableResult
    private func captureCurrentClipboardChangeIfNeeded(
        protecting protectedIDs: Set<UUID> = []
    ) -> Bool {
        let changeCount = NSPasteboard.general.changeCount
        guard changeCount != lastChangeCount else {
            pendingChangeCount = nil
            failedCaptureAttempts = 0
            return false
        }

        if pendingChangeCount != changeCount {
            pendingChangeCount = changeCount
            failedCaptureAttempts = 0
        }

        guard let snapshot = currentClipboardSnapshot() else {
            failedCaptureAttempts += 1
            if failedCaptureAttempts >= 4 {
                lastChangeCount = changeCount
                pendingChangeCount = nil
                failedCaptureAttempts = 0
            }
            return false
        }

        lastChangeCount = changeCount
        pendingChangeCount = nil
        failedCaptureAttempts = 0
        process(snapshot, protecting: protectedIDs)
        return true
    }

    private func process(
        _ snapshot: ClipboardSnapshot,
        protecting protectedIDs: Set<UUID>
    ) {
        Task { @MainActor [weak self, snapshotProcessor] in
            let item = await snapshotProcessor.item(from: snapshot)
            guard let self, let item else { return }

            while !Task.isCancelled {
                let comparedRevision = historyRevision
                let comparedHistory = history
                let duplicateIDs = await snapshotProcessor.duplicateIDs(
                    for: item,
                    in: comparedHistory
                )
                guard !Task.isCancelled else { return }
                if comparedRevision == historyRevision {
                    addToHistory(
                        item,
                        matchingDuplicateIDs: duplicateIDs,
                        protecting: protectedIDs
                    )
                    return
                }
            }
        }
    }

    private func currentClipboardSnapshot() -> ClipboardSnapshot? {
        let pasteboard = NSPasteboard.general
        let timestamp = Date()
        let fileURLs = (
            pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
        ) ?? []

        let localFileURLs = fileURLs.filter {
            $0.isFileURL && FileManager.default.fileExists(atPath: $0.path)
        }
        if !localFileURLs.isEmpty {
            return .fileURLs(localFileURLs, timestamp)
        }

        if let image = imageSnapshot(from: pasteboard, timestamp: timestamp) {
            return image
        }

        if let rtfData = pasteboard.data(forType: .rtf) {
            return .richText(
                rtfData,
                pasteboard.string(forType: .string),
                timestamp
            )
        }

        if let string = pasteboard.string(forType: .string), !string.isEmpty {
            let type: ClipboardItemType = (
                string.hasPrefix("http://") || string.hasPrefix("https://")
            ) ? .url : .text
            return .string(string, type, timestamp)
        }

        if let url = pasteboard.string(forType: .URL), !url.isEmpty {
            return .string(url, .url, timestamp)
        }
        return nil
    }

    private func imageSnapshot(
        from pasteboard: NSPasteboard,
        timestamp: Date
    ) -> ClipboardSnapshot? {
        let candidates: [(NSPasteboard.PasteboardType, String)] = [
            (.png, "png"),
            (.tiff, "tiff"),
            (NSPasteboard.PasteboardType("public.jpeg"), "jpg"),
            (NSPasteboard.PasteboardType("public.heic"), "heic"),
            (NSPasteboard.PasteboardType("public.heif"), "heif"),
            (NSPasteboard.PasteboardType("com.compuserve.gif"), "gif"),
            (NSPasteboard.PasteboardType("com.microsoft.bmp"), "bmp"),
            (NSPasteboard.PasteboardType("org.webmproject.webp"), "webp")
        ]
        for (type, fileExtension) in candidates {
            if let data = pasteboard.data(forType: type), !data.isEmpty {
                return .image(data, fileExtension, timestamp)
            }
        }

        if let imageType = pasteboard.types?.first(where: {
            UTType($0.rawValue)?.conforms(to: .image) == true
        }),
           let data = pasteboard.data(forType: imageType),
           !data.isEmpty {
            let fileExtension = UTType(imageType.rawValue)?
                .preferredFilenameExtension ?? "png"
            return .image(data, fileExtension, timestamp)
        }

        let hasImageType = pasteboard.types?.contains {
            UTType($0.rawValue)?.conforms(to: .image) == true
        } == true
        guard hasImageType,
              let image = NSImage(pasteboard: pasteboard),
              let tiff = image.tiffRepresentation else {
            return nil
        }
        return .image(tiff, "tiff", timestamp)
    }

    private func addToHistory(
        _ item: ClipboardItem,
        matchingDuplicateIDs: Set<UUID>,
        protecting protectedIDs: Set<UUID>
    ) {
        let update = clipboardHistoryByInserting(
            item,
            into: history,
            matchingDuplicateIDs: matchingDuplicateIDs,
            limit: historyLimit,
            protecting: protectedIDs
        )
        if update.didInsert {
            history = update.items
        }
        if update.didInsert || update.needsPayloadCleanup {
            saveArchive(cleanup: update.needsPayloadCleanup)
        }
    }

    private func pasteboardItems(
        for items: [ClipboardItem]
    ) -> [NSPasteboardItem] {
        items.flatMap { item -> [NSPasteboardItem] in
            let pasteboardItem = NSPasteboardItem()
            switch item.type {
            case .text, .unknown:
                guard let value = item.stringData else { return [] }
                pasteboardItem.setString(value, forType: .string)
            case .url:
                guard let value = item.stringData else { return [] }
                pasteboardItem.setString(value, forType: .string)
                pasteboardItem.setString(value, forType: .URL)
            case .image:
                guard let data = item.getImageData() else { return [] }
                pasteboardItem.setData(data, forType: item.imagePasteboardType)
            case .file:
                return (item.fileURLs ?? []).compactMap { value in
                    guard let url = URL(string: value) else { return nil }
                    let fileItem = NSPasteboardItem()
                    fileItem.setString(url.absoluteString, forType: .fileURL)
                    return fileItem
                }
            case .rtf:
                if let data = item.getRTFData() {
                    pasteboardItem.setData(data, forType: .rtf)
                }
                if let value = item.stringData {
                    pasteboardItem.setString(value, forType: .string)
                }
                guard !pasteboardItem.types.isEmpty else { return [] }
            }
            return [pasteboardItem]
        }
    }

    private func combinedTextPasteboardItem(
        for items: [ClipboardItem]
    ) -> NSPasteboardItem? {
        let text = items.compactMap(\.stringData).joined(separator: "\n")
        guard !text.isEmpty else { return nil }
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        return item
    }

    private func trimHistory(protecting protectedIDs: Set<UUID> = []) {
        var updated = history
        while updated.count > historyLimit {
            guard let index = updated.lastIndex(where: {
                !protectedIDs.contains($0.id)
            }) else {
                updated = Array(updated.prefix(historyLimit))
                break
            }
            updated.remove(at: index)
        }
        if updated.count != history.count {
            history = updated
        }
    }

    private func hasSameGroupItems(
        _ lhs: [ClipboardItem],
        _ rhs: [ClipboardItem]
    ) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { left, right in
            left.type == right.type
                && left.stringData == right.stringData
                && left.imageFileName == right.imageFileName
                && left.fileURLs == right.fileURLs
                && left.rtfFileName == right.rtfFileName
        }
    }

    private func saveArchive(cleanup: Bool = false) {
        persistenceCoordinator.enqueue(currentArchive, cleanup: cleanup)
    }

    private var currentArchive: ClipboardArchive {
        ClipboardArchive(
            history: history,
            pinnedItems: pinnedItems,
            groups: groups
        )
    }

    private func archiveIdentity(
        _ archive: ClipboardArchive
    ) -> ClipboardArchiveIdentity {
        ClipboardArchiveIdentity(
            historyIDs: archive.history.map(\.id),
            pinnedIDs: archive.pinnedItems.map(\.id),
            groups: (archive.groups ?? []).map {
                ClipboardArchiveIdentity.Group(
                    id: $0.id,
                    itemIDs: $0.items.map(\.id)
                )
            }
        )
    }

    private func loadArchive() {
        guard let data = try? Data(contentsOf: ClipboardStorage.archiveURL),
              let archive = try? JSONDecoder().decode(
                  ClipboardArchive.self,
                  from: data
              ) else {
            return
        }
        history = archive.history
        pinnedItems = archive.pinnedItems
        groups = archive.groups ?? []
    }
}

private struct ClipboardArchiveIdentity: Equatable {
    struct Group: Equatable {
        let id: UUID
        let itemIDs: [UUID]
    }

    let historyIDs: [UUID]
    let pinnedIDs: [UUID]
    let groups: [Group]
}
