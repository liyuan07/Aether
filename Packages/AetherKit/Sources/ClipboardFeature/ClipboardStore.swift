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
import RustCore
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

final class ClipboardPersistenceCoordinator: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "com.liyuan07.clipboard.archive-writer",
        qos: .utility
    )
    private let archiveStore: RustClipboardArchive
    private let imagesDirectory: URL
    private let payloadsDirectory: URL
    private let fileManager: FileManager

    init(archiveURL: URL = ClipboardStorage.archiveURL, imagesDirectory: URL = ClipboardStorage.imagesDirectory,
        payloadsDirectory: URL = ClipboardStorage.payloadsDirectory, fileManager: FileManager = .default) {
        self.archiveStore = RustClipboardArchive(fileURL: archiveURL)
        self.imagesDirectory = imagesDirectory
        self.payloadsDirectory = payloadsDirectory
        self.fileManager = fileManager
    }

    private var pendingArchive: ClipboardArchive?
    private var writerCore = AetherClipboardWriter()
    private var pendingWorkItem: DispatchWorkItem?

    func load() throws -> ClipboardArchive? { try archiveStore.load() }

    func enqueue(_ archive: ClipboardArchive, cleanup: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            pendingArchive = archive
            writerCore = aether_clipboard_writer_enqueue(writerCore, cleanup ? 1 : 0)
            guard writerCore.schedule != 0 else { return }

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
            let step = aether_clipboard_writer_take(writerCore)
            writerCore = step.state
            write(archive, cleanup: step.cleanup != 0)
        }
    }

    private func writePendingArchive() {
        let archive = pendingArchive
        let step = aether_clipboard_writer_take(writerCore)
        writerCore = step.state
        pendingArchive = nil
        pendingWorkItem = nil
        guard step.write != 0, let archive else { return }
        write(archive, cleanup: step.cleanup != 0)
    }

    private func write(_ archive: ClipboardArchive, cleanup: Bool) {
        guard (try? archiveStore.save(archive)) != nil else {
            return
        }
        guard cleanup else { return }

        let allItems = archive.history
            + archive.pinnedItems
            + (archive.groups ?? []).flatMap(\.items)
        removeUnreferencedFiles(
            in: imagesDirectory,
            keeping: allItems.compactMap(\.imageFileName)
        )
        removeUnreferencedFiles(
            in: payloadsDirectory,
            keeping: allItems.compactMap(\.rtfFileName)
        )
    }

    private func removeUnreferencedFiles(
        in directory: URL,
        keeping names: [String]
    ) {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return
        }
        let indices = rustClipboardUnreferencedResources(keeping: names, files: files.map(\.lastPathComponent))
        for index in indices { try? fileManager.removeItem(at: files[index]) }
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
        let rows = history.map { rustClipboardRow($0, matching: $0.hasSameContent(as: item)) }
        return Set(rustClipboardPlan(rows, action: 3).indices.map { history[$0].id })
    }
}

actor ClipboardMaintenanceProcessor {
    func archive(
        from source: ClipboardArchive,
        expirationDays: Int,
        historyLimit: Int,
        now: Date
    ) throws -> ClipboardArchive {
        let cutoff = expirationDays > 0 ? Calendar.current.date(byAdding: .day, value: -expirationDays, to: now) : nil
        let history = try validItems(source.history, cutoff: cutoff, limit: historyLimit)
        let pinnedItems = try validItems(source.pinnedItems)
        let groupAccumulator = ClipboardGroupAccumulator()
        for (offset, originalGroup) in (source.groups ?? []).enumerated() {
            if offset.isMultiple(of: 16) {
                try Task.checkCancellation()
            }
            var group = originalGroup
            group.items = try validItems(group.items)
            groupAccumulator.append(group)
        }

        try Task.checkCancellation()
        return ClipboardArchive(
            history: history,
            pinnedItems: pinnedItems,
            groups: groupAccumulator.groups
        )
    }

    private func validItems(_ items: [ClipboardItem], cutoff: Date? = nil, limit: Int = Int.max) throws -> [ClipboardItem] {
        var rows: [AetherClipboardRow] = []
        rows.reserveCapacity(items.count)
        for (offset, item) in items.enumerated() {
            if offset.isMultiple(of: 128) { try Task.checkCancellation() }
            rows.append(rustClipboardRow(item, valid: payloadExists(for: item)))
        }
        try Task.checkCancellation()
        return rustClipboardPlan(rows, action: 2, limit: limit, cutoff: cutoff).indices.map { items[$0] }
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
    let rows = history.map { existing in
        rustClipboardRow(existing, matching: matchingDuplicateIDs.map { $0.contains(existing.id) } ?? existing.hasSameContent(as: item),
            protected: protectedIDs.contains(existing.id))
    }
    let candidate = rustClipboardRow(item, protected: protectedIDs.contains(item.id))
    let result = rustClipboardPlan(rows, candidate: candidate, action: 0, limit: limit)
    return ClipboardHistoryUpdate(items: result.plan.inserted == 0 ? history : result.indices.map { $0 == history.count ? item : history[$0] },
        didInsert: result.plan.inserted != 0, needsPayloadCleanup: result.plan.cleanup != 0)
}

@MainActor
final class ClipboardStore: ObservableObject {
    static let shared = ClipboardStore()

    @Published private(set) var history: [ClipboardItem] = [] {
        didSet {
            workCore = aether_clipboard_history_changed(workCore)
        }
    }
    @Published private(set) var pinnedItems: [ClipboardItem] = []
    @Published private(set) var groups: [ClipboardGroup] = []
    @Published private(set) var isMonitoring = false

    private var timer: Timer?
    private var captureCore = AetherClipboardCapture(last_change: Int64(AppEnvironment.clipboardPasteboard.changeCount), pending_change: 0, pending: 0, failures: 0, needed: 0)
    private var workCore = AetherClipboardWork(history_revision: 0, maintenance_generation: 0,
        last_maintenance: Date.distantPast.timeIntervalSinceReferenceDate)
    private let persistenceCoordinator = ClipboardPersistenceCoordinator()
    private let snapshotProcessor = ClipboardSnapshotProcessor()
    private let maintenanceProcessor = ClipboardMaintenanceProcessor()
    private var maintenanceTask: Task<Void, Never>?

    private var historyLimit: Int {
        max(50, AppEnvironment.clipboardDefaults.integer(forKey: PreferenceKeys.historyLimit))
    }

    private var expirationDays: Int {
        max(0, AppEnvironment.clipboardDefaults.integer(forKey: PreferenceKeys.expirationDays))
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
    func copyPlainTextToClipboard(_ value: String) -> Bool {
        captureCurrentClipboardChangeIfNeeded()

        let item = NSPasteboardItem()
        guard item.setString(value, forType: .string) else { return false }
        let pasteboard = AppEnvironment.clipboardPasteboard
        pasteboard.clearContents()
        let didWrite = pasteboard.writeObjects([item])
        captureCore = aether_clipboard_capture_observed(captureCore, Int64(pasteboard.changeCount))
        return didWrite
    }

    @discardableResult
    func copyToClipboard(_ item: ClipboardItem) -> Bool {
        let prepared = pasteboardItems(for: [item])
        guard !prepared.isEmpty else { return false }

        captureCurrentClipboardChangeIfNeeded(protecting: [item.id])

        let pasteboard = AppEnvironment.clipboardPasteboard
        pasteboard.clearContents()
        let didWrite = pasteboard.writeObjects(prepared)
        captureCore = aether_clipboard_capture_observed(captureCore, Int64(pasteboard.changeCount))
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
        let pasteboard = AppEnvironment.clipboardPasteboard
        pasteboard.clearContents()
        let didWrite = pasteboard.writeObjects(prepared)
        captureCore = aether_clipboard_capture_observed(captureCore, Int64(pasteboard.changeCount))
        return didWrite
    }

    @discardableResult
    func activateGroup(_ group: ClipboardGroup) -> Bool {
        guard copyGroupToClipboard(group) else { return false }
        let transition = rustClipboardGroupTransition(groups, action: .promote, candidateID: group.id)
        if transition.changed { groups = transition.groups }
        saveArchive()
        return true
    }

    @discardableResult
    func createGroup(from items: [ClipboardItem]) -> ClipboardGroup? {
        let transition = rustClipboardGroupTransition(groups, action: .create, items: items)
        guard transition.accepted else { return nil }
        groups = transition.groups
        saveArchive()
        return transition.selected
    }

    func togglePin(for item: ClipboardItem) {
        applyPin(item, action: 2)
    }

    func delete(_ item: ClipboardItem) {
        history = rustClipboardRemoving(history) { $0.id == item.id }
        pinnedItems = rustClipboardRemoving(pinnedItems) { $0.id == item.id }
        saveArchive(cleanup: true)
    }

    func delete(_ group: ClipboardGroup) {
        groups = rustClipboardGroupTransition(groups, action: .remove, candidateID: group.id).groups
        saveArchive(cleanup: true)
    }

    func clear(_ tab: ClipboardTab) {
        switch tab {
        case .favorites:
            pinnedItems.removeAll()
        case .groups:
            groups = rustClipboardGroupTransition(groups, action: .clear).groups
        default:
            history = rustClipboardRemoving(history) { tab.includes($0) }
        }
        saveArchive(cleanup: true)
    }

    func performMaintenance() {
        maintenanceTask?.cancel()
        let source = currentArchive
        let sourceIdentity = archiveIdentity(source)
        let expirationDays = self.expirationDays
        let historyLimit = self.historyLimit
        let now = Date()
        workCore = aether_clipboard_maintenance_begin(workCore, Date().timeIntervalSinceReferenceDate)
        let pendingGeneration = workCore.maintenance_generation
        maintenanceTask = Task { @MainActor [weak self, maintenanceProcessor] in
            do {
                let maintained = try await maintenanceProcessor.archive(
                    from: source,
                    expirationDays: expirationDays,
                    historyLimit: historyLimit,
                    now: now
                )
                guard !Task.isCancelled, let self else { return }
                guard aether_clipboard_maintenance_current(workCore, pendingGeneration) != 0 else { return }
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
                   aether_clipboard_maintenance_current(workCore, pendingGeneration) != 0 {
                    maintenanceTask = nil
                }
            }
        }
    }

    func flushArchive() {
        persistenceCoordinator.flush(currentArchive)
    }

    private func preferencesDidChange() {
        if AppEnvironment.clipboardDefaults.bool(forKey: PreferenceKeys.monitoringEnabled) {
            startMonitoring()
        } else {
            stopMonitoring()
        }
        performMaintenance()
    }

    private func applyPin(_ item: ClipboardItem, action: UInt8) {
        let result = rustClipboardPin(item, history: history, pinned: pinnedItems, action: action, limit: historyLimit)
        history = result.history
        pinnedItems = result.pinned
        saveArchive(cleanup: !result.isPinned)
    }

    private func checkClipboard() {
        if aether_clipboard_maintenance_due(workCore, Date().timeIntervalSinceReferenceDate) != 0 {
            performMaintenance()
        }
        captureCurrentClipboardChangeIfNeeded()
    }

    @discardableResult
    private func captureCurrentClipboardChangeIfNeeded(
        protecting protectedIDs: Set<UUID> = []
    ) -> Bool {
        let changeCount = AppEnvironment.clipboardPasteboard.changeCount
        captureCore = aether_clipboard_capture_probe(captureCore, Int64(changeCount))
        guard captureCore.needed != 0 else { return false }
        guard let snapshot = currentClipboardSnapshot() else {
            captureCore = aether_clipboard_capture_failed(captureCore, Int64(changeCount))
            return false
        }
        captureCore = aether_clipboard_capture_committed(captureCore, Int64(changeCount))
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
                let comparedRevision = workCore.history_revision
                let comparedHistory = history
                let duplicateIDs = await snapshotProcessor.duplicateIDs(
                    for: item,
                    in: comparedHistory
                )
                guard !Task.isCancelled else { return }
                if aether_clipboard_revision_current(workCore, comparedRevision) != 0 {
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
        let pasteboard = AppEnvironment.clipboardPasteboard
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
        guard let archive = try? persistenceCoordinator.load() else { return }
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
