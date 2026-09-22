import AppKit
import SwiftUI

@MainActor
final class ClipboardPanelKeyboardRouter {
    enum Area {
        case history
        case quickClipboard
    }

    static let shared = ClipboardPanelKeyboardRouter()
    var area: Area = .history
    var quickClipboardHandler: ((NSEvent) -> Bool)?

    private init() {}

    func handle(_ event: NSEvent) -> Bool {
        guard area == .quickClipboard else { return false }
        return quickClipboardHandler?(event) ?? false
    }
}

private enum QuickClipboardFocus: Hashable {
    case search
    case collectionName
    case key
    case value
}

private enum QuickClipboardCollectionEditor: Equatable {
    case rename(UUID)
}

private struct QuickClipboardEntryEditor: Equatable {
    let collectionID: UUID
    let entryID: UUID?
    var key: String
    var value: String
}

private enum QuickClipboardUndo {
    case entry(QuickClipboardDeletedEntry)
    case collection(QuickClipboardDeletedCollection)
}

struct QuickClipboardPopoverView: View {
    @ObservedObject var model: QuickClipboardModel
    let onCollapse: () -> Void

    @State private var searchText = ""
    @State private var searchSections: [QuickClipboardSearchSection] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var collectionEditor: QuickClipboardCollectionEditor?
    @State private var collectionNameDraft = ""
    @State private var collectionError: String?
    @State private var conflictingCollectionID: UUID?
    @State private var entryEditor: QuickClipboardEntryEditor?
    @State private var entryError: String?
    @State private var conflictingEntryID: UUID?
    @State private var focusedEntryID: UUID?
    @State private var copiedEntryID: UUID?
    @State private var statusMessage: String?
    @State private var deleteCollectionID: UUID?
    @State private var undoAction: QuickClipboardUndo?
    @State private var undoToken: UUID?
    @FocusState private var focus: QuickClipboardFocus?

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var visibleEntries: [(collectionID: UUID, entry: QuickClipboardEntry)] {
        if !trimmedQuery.isEmpty {
            return searchSections.flatMap { section in
                section.entries.map { (section.collectionID, $0) }
            }
        }
        guard let collection = model.selectedCollection else { return [] }
        return collection.entries.map { (collection.id, $0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            search
            collectionControl
            if let message = model.storageMessage {
                inlineMessage(message, color: .orange)
            }
            if let statusMessage {
                inlineMessage(statusMessage, color: .secondary)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            content
            if undoAction != nil {
                undoBar
            }
        }
        .background(Color.indigo.opacity(0.065))
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded(activateKeyboardArea))
        .onAppear {
            installKeyboardHandler()
            if model.selectedCollectionID == nil {
                model.selectedCollectionID = model.collections.first?.id
            }
        }
        .onDisappear {
            searchTask?.cancel()
            if ClipboardPanelKeyboardRouter.shared.quickClipboardHandler != nil {
                ClipboardPanelKeyboardRouter.shared.quickClipboardHandler = nil
            }
        }
        .onChange(of: searchText) { _, _ in scheduleSearch() }
        .onChange(of: model.collections) { _, _ in
            if !trimmedQuery.isEmpty { scheduleSearch(immediate: true) }
            reconcileFocusedEntry()
        }
        .onExitCommand { _ = cancelTopState() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "tray.full.fill")
                .foregroundStyle(.indigo)
            Text("常用")
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 0)
            Button(action: onCollapse) {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.plain)
            .help("关闭常用内容")
            .accessibilityLabel("关闭常用内容")
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
    }

    private var search: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索", text: $searchText)
                .textFieldStyle(.plain)
                .focused($focus, equals: .search)
                .accessibilityIdentifier("quick-clipboard.search")
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 10)
        .padding(.top, 10)
    }

    @ViewBuilder
    private var collectionControl: some View {
        VStack(alignment: .leading, spacing: 7) {
            if collectionEditor != nil {
                HStack(spacing: 7) {
                    TextField(
                        "新名称",
                        text: $collectionNameDraft
                    )
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .collectionName)
                    .onSubmit(saveCollectionEditor)
                    Button("取消", action: cancelCollectionEditor)
                        .buttonStyle(.borderless)
                    Button("保存", action: saveCollectionEditor)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                if let collectionError {
                    HStack(spacing: 6) {
                        Text(collectionError)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                        if conflictingCollectionID != nil {
                            Button("打开已有内容", action: openConflictingCollection)
                                .buttonStyle(.link)
                                .font(.caption2)
                        }
                    }
                }
            } else if model.collections.isEmpty {
                Button {
                    createDefaultCollection()
                } label: {
                    Label("新建", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            } else {
                HStack(spacing: 7) {
                    Menu {
                        ForEach(model.collections) { collection in
                            Button(collection.name) {
                                model.selectedCollectionID = collection.id
                                focusedEntryID = collection.entries.first?.id
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Text(model.selectedCollection?.name ?? "常用")
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Text("\(model.selectedCollection?.entries.count ?? 0)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 28)
                        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .menuStyle(.borderlessButton)
                    .frame(maxWidth: .infinity)

                    Button {
                        createDefaultCollection()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("新建（⇧⌘N）")
                    .accessibilityLabel("新建")

                    Menu {
                        Button("重命名") {
                            guard let id = model.selectedCollection?.id else { return }
                            beginCollectionEditor(.rename(id))
                        }
                        Button("删除", role: .destructive) {
                            deleteCollectionID = model.selectedCollection?.id
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .help("更多操作")
                    .accessibilityLabel("更多操作")

                    Button {
                        beginNewEntry()
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .buttonStyle(.borderless)
                    .help("添加内容（⌘N）")
                    .accessibilityLabel("添加内容")
                }
            }

            if let id = deleteCollectionID,
               let collection = model.collections.first(where: { $0.id == id }) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("删除“\(collection.name)”及其中 \(collection.entries.count) 项？")
                        .font(.caption)
                    HStack {
                        Button("取消") { deleteCollectionID = nil }
                        Spacer()
                        Button("删除", role: .destructive) {
                            deleteCollection(id)
                        }
                    }
                    .controlSize(.small)
                }
                .padding(8)
                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
            }
        }
        .padding(10)
    }

    @ViewBuilder
    private var content: some View {
        if model.collections.isEmpty {
            emptyState(
                icon: "tray.full",
                title: "还没有常用内容",
                detail: ""
            )
        } else if !trimmedQuery.isEmpty {
            searchContent
        } else if let collection = model.selectedCollection {
            collectionContent(collection)
        } else {
            emptyState(
                icon: "tray.full",
                title: "选择内容",
                detail: ""
            )
        }
    }

    private func collectionContent(_ collection: QuickClipboardCollection) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 5) {
                    if let editor = entryEditor,
                       editor.entryID == nil,
                       editor.collectionID == collection.id {
                        entryEditorView(editor)
                    }
                    if collection.entries.isEmpty, entryEditor == nil {
                        emptyState(
                            icon: "text.badge.plus",
                            title: "还没有内容",
                            detail: ""
                        )
                    } else {
                        entryRows(collection.entries, collectionID: collection.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
            }
            .onChange(of: focusedEntryID) { _, id in
                guard let id else { return }
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }

    @ViewBuilder
    private var searchContent: some View {
        if searchSections.isEmpty {
            emptyState(
                icon: "magnifyingglass",
                title: "没有找到结果",
                detail: "没有与“\(trimmedQuery)”匹配的内容。",
                actionTitle: "清除搜索",
                action: { searchText = "" }
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(searchSections) { section in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(section.collectionName)
                                    .font(.caption.weight(.semibold))
                                Spacer()
                                Text("\(section.entries.count) 项")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 5)
                            if section.entries.isEmpty {
                                Text("暂无内容")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 5)
                            } else {
                                entryRows(section.entries, collectionID: section.collectionID)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
            }
        }
    }

    private func entryRows(
        _ entries: [QuickClipboardEntry],
        collectionID: UUID
    ) -> some View {
        ForEach(entries) { entry in
            VStack(spacing: 4) {
                entryRow(entry, collectionID: collectionID)
                    .id(entry.id)
                if let editor = entryEditor,
                   editor.entryID == entry.id,
                   editor.collectionID == collectionID {
                    entryEditorView(editor)
                }
            }
        }
    }

    private func entryRow(
        _ entry: QuickClipboardEntry,
        collectionID: UUID
    ) -> some View {
        HStack(spacing: 5) {
            Button {
                copy(entry, collectionID: collectionID)
            } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.key)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        Text(entry.value)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: copiedEntryID == entry.id ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                        .foregroundStyle(copiedEntryID == entry.id ? .green : .indigo)
                }
                .padding(.vertical, 8)
                .padding(.leading, 9)
                .padding(.trailing, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("复制“\(entry.key)”的内容")

            Menu {
                Button("编辑") { beginEditing(entry, collectionID: collectionID) }
                Button("删除", role: .destructive) {
                    deleteEntry(entry.id, collectionID: collectionID)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 18, height: 28)
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("“\(entry.key)”的更多操作")
        }
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(focusedEntryID == entry.id
                    ? Color.indigo.opacity(0.15)
                    : Color.primary.opacity(0.055))
        )
        .contextMenu {
            Button("复制内容") { copy(entry, collectionID: collectionID) }
            Button("编辑") { beginEditing(entry, collectionID: collectionID) }
            Divider()
            Button("删除", role: .destructive) {
                deleteEntry(entry.id, collectionID: collectionID)
            }
        }
    }

    private func entryEditorView(_ editor: QuickClipboardEntryEditor) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            TextField("标题", text: Binding(
                get: { entryEditor?.key ?? "" },
                set: { entryEditor?.key = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .focused($focus, equals: .key)
            .accessibilityIdentifier("quick-clipboard.entry.key")

            TextEditor(text: Binding(
                get: { entryEditor?.value ?? "" },
                set: { entryEditor?.value = $0 }
            ))
            .font(.system(size: 11))
            .scrollContentBackground(.hidden)
            .padding(4)
            .frame(minHeight: 72, maxHeight: 112)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            .focused($focus, equals: .value)
            .accessibilityLabel("内容")
            .accessibilityIdentifier("quick-clipboard.entry.value")

            if let entryError {
                HStack(spacing: 6) {
                    Text(entryError)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    if conflictingEntryID != nil {
                        Button("编辑已有条目", action: editConflictingEntry)
                            .buttonStyle(.link)
                            .font(.caption2)
                    }
                }
            }

            HStack {
                Button("取消", action: cancelEntryEditor)
                Spacer()
                Button("保存", action: saveEntryEditor)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .controlSize(.small)
        }
        .padding(9)
        .background(Color.indigo.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }

    private var undoBar: some View {
        HStack(spacing: 8) {
            Text("已删除")
                .font(.caption)
            Spacer()
            Button("撤销", action: undoDeletion)
                .buttonStyle(.link)
                .font(.caption)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(.regularMaterial)
    }

    private func emptyState(
        icon: String,
        title: String,
        detail: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.subheadline.weight(.medium))
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    private func inlineMessage(_ message: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: color == .orange
                ? "exclamationmark.triangle.fill"
                : "checkmark.circle.fill")
            Text(message)
                .lineLimit(2)
        }
        .font(.caption2)
        .foregroundStyle(color)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    private func activateKeyboardArea() {
        ClipboardPanelKeyboardRouter.shared.area = .quickClipboard
    }

    private func installKeyboardHandler() {
        ClipboardPanelKeyboardRouter.shared.quickClipboardHandler = { event in
            handleKey(event)
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command) {
            switch event.keyCode {
            case 3: // F
                focus = .search
                return true
            case 45: // N
                if modifiers.contains(.shift) {
                    createDefaultCollection()
                } else {
                    beginNewEntry()
                }
                return true
            case 8: // C
                return copyFocusedEntry()
            case 18, 19, 20, 21, 23, 22, 26, 28, 25:
                let codes = [18, 19, 20, 21, 23, 22, 26, 28, 25]
                guard let index = codes.firstIndex(of: Int(event.keyCode)),
                      visibleEntries.indices.contains(index) else { return false }
                copy(
                    visibleEntries[index].entry,
                    collectionID: visibleEntries[index].collectionID
                )
                return true
            default:
                return false
            }
        }

        switch event.keyCode {
        case 125:
            moveFocusedEntry(by: 1)
            return true
        case 126:
            moveFocusedEntry(by: -1)
            return true
        case 36, 76:
            return copyFocusedEntry()
        case 53:
            return cancelTopState()
        default:
            return false
        }
    }

    private func moveFocusedEntry(by offset: Int) {
        guard !visibleEntries.isEmpty else { return }
        let current = focusedEntryID.flatMap { id in
            visibleEntries.firstIndex { $0.entry.id == id }
        } ?? (offset > 0 ? -1 : visibleEntries.count)
        focusedEntryID = visibleEntries[
            min(max(current + offset, 0), visibleEntries.count - 1)
        ].entry.id
    }

    private func copyFocusedEntry() -> Bool {
        guard let target = focusedEntryID.flatMap({ id in
            visibleEntries.first { $0.entry.id == id }
        }) ?? visibleEntries.first else { return false }
        copy(target.entry, collectionID: target.collectionID)
        return true
    }

    private func copy(_ entry: QuickClipboardEntry, collectionID: UUID) {
        activateKeyboardArea()
        focusedEntryID = entry.id
        guard ClipboardStore.shared.copyPlainTextToClipboard(entry.value) else {
            statusMessage = "复制失败，请重试。"
            return
        }
        copiedEntryID = entry.id
        statusMessage = "已复制：\(entry.key)"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if copiedEntryID == entry.id { copiedEntryID = nil }
            if statusMessage == "已复制：\(entry.key)" { statusMessage = nil }
        }
    }

    private func beginCollectionEditor(_ mode: QuickClipboardCollectionEditor) {
        activateKeyboardArea()
        collectionEditor = mode
        collectionError = nil
        conflictingCollectionID = nil
        switch mode {
        case let .rename(id):
            collectionNameDraft = model.collections.first { $0.id == id }?.name ?? ""
        }
        DispatchQueue.main.async { focus = .collectionName }
    }

    private func createDefaultCollection() {
        activateKeyboardArea()
        switch model.createDefaultCollection() {
        case .success:
            collectionError = nil
            conflictingCollectionID = nil
        case let .failure(error):
            collectionError = error.localizedDescription
        }
    }

    private func saveCollectionEditor() {
        guard let collectionEditor else { return }
        let result: Result<Void, QuickClipboardValidationError>
        switch collectionEditor {
        case let .rename(id):
            result = model.renameCollection(id: id, name: collectionNameDraft)
        }
        switch result {
        case .success:
            cancelCollectionEditor()
        case let .failure(error):
            collectionError = error.localizedDescription
            if case let .duplicateCollectionName(id) = error {
                conflictingCollectionID = id
            }
        }
    }

    private func cancelCollectionEditor() {
        collectionEditor = nil
        collectionError = nil
        conflictingCollectionID = nil
        focus = nil
    }

    private func openConflictingCollection() {
        guard let conflictingCollectionID else { return }
        model.selectedCollectionID = conflictingCollectionID
        searchText = ""
        cancelCollectionEditor()
    }

    private func deleteCollection(_ id: UUID) {
        guard let deleted = model.deleteCollection(id: id) else { return }
        deleteCollectionID = nil
        beginUndo(.collection(deleted))
    }

    private func beginNewEntry() {
        guard let collectionID = model.selectedCollection?.id else {
            switch model.createDefaultCollection() {
            case .success:
                beginNewEntry()
            case let .failure(error):
                collectionError = error.localizedDescription
            }
            return
        }
        searchText = ""
        entryEditor = QuickClipboardEntryEditor(
            collectionID: collectionID,
            entryID: nil,
            key: "",
            value: ""
        )
        entryError = nil
        conflictingEntryID = nil
        DispatchQueue.main.async { focus = .key }
    }

    private func beginEditing(_ entry: QuickClipboardEntry, collectionID: UUID) {
        activateKeyboardArea()
        model.selectedCollectionID = collectionID
        entryEditor = QuickClipboardEntryEditor(
            collectionID: collectionID,
            entryID: entry.id,
            key: entry.key,
            value: entry.value
        )
        entryError = nil
        conflictingEntryID = nil
        DispatchQueue.main.async { focus = .key }
    }

    private func saveEntryEditor() {
        guard let editor = entryEditor else { return }
        let result: Result<Void, QuickClipboardValidationError>
        if let entryID = editor.entryID {
            result = model.updateEntry(
                collectionID: editor.collectionID,
                entryID: entryID,
                key: editor.key,
                value: editor.value
            )
        } else {
            result = model.addEntry(
                collectionID: editor.collectionID,
                key: editor.key,
                value: editor.value
            ).map { id in
                focusedEntryID = id
            }
        }
        switch result {
        case .success:
            cancelEntryEditor()
        case let .failure(error):
            entryError = error.localizedDescription
            if case let .duplicateKey(id) = error {
                conflictingEntryID = id
            }
        }
    }

    private func cancelEntryEditor() {
        entryEditor = nil
        entryError = nil
        conflictingEntryID = nil
        focus = nil
    }

    private func editConflictingEntry() {
        guard let editor = entryEditor,
              let conflictingEntryID,
              let collection = model.collections.first(where: {
                  $0.id == editor.collectionID
              }),
              let entry = collection.entries.first(where: {
                  $0.id == conflictingEntryID
              }) else { return }
        beginEditing(entry, collectionID: collection.id)
    }

    private func deleteEntry(_ entryID: UUID, collectionID: UUID) {
        guard let deleted = model.deleteEntry(
            collectionID: collectionID,
            entryID: entryID
        ) else { return }
        if focusedEntryID == entryID { focusedEntryID = nil }
        if entryEditor?.entryID == entryID { cancelEntryEditor() }
        beginUndo(.entry(deleted))
    }

    private func beginUndo(_ action: QuickClipboardUndo) {
        let token = UUID()
        undoAction = action
        undoToken = token
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard undoToken == token else { return }
            undoAction = nil
            undoToken = nil
        }
    }

    private func undoDeletion() {
        guard let undoAction else { return }
        switch undoAction {
        case let .entry(deleted):
            if model.restoreEntry(deleted) {
                model.selectedCollectionID = deleted.collectionID
                focusedEntryID = deleted.entry.id
            }
        case let .collection(deleted):
            _ = model.restoreCollection(deleted)
        }
        self.undoAction = nil
        undoToken = nil
    }

    private func scheduleSearch(immediate: Bool = false) {
        searchTask?.cancel()
        let query = trimmedQuery
        guard !query.isEmpty else {
            searchSections = []
            reconcileFocusedEntry()
            return
        }
        let collections = model.collections
        searchTask = Task { @MainActor in
            if !immediate {
                do { try await Task.sleep(for: .milliseconds(150)) }
                catch { return }
            }
            guard !Task.isCancelled,
                  query == trimmedQuery else { return }
            searchSections = quickClipboardSearch(
                query: query,
                collections: collections
            )
            reconcileFocusedEntry()
        }
    }

    private func reconcileFocusedEntry() {
        guard focusedEntryID.flatMap({ id in
            visibleEntries.first { $0.entry.id == id }
        }) == nil else { return }
        focusedEntryID = visibleEntries.first?.entry.id
    }

    @discardableResult
    private func cancelTopState() -> Bool {
        if entryEditor != nil {
            cancelEntryEditor()
            return true
        }
        if collectionEditor != nil {
            cancelCollectionEditor()
            return true
        }
        if deleteCollectionID != nil {
            deleteCollectionID = nil
            return true
        }
        if !searchText.isEmpty {
            searchText = ""
            return true
        }
        return false
    }
}
