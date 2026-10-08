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

import AppKit
import ImageIO
import SwiftUI

let clipboardDetailLoadDelayNanoseconds: UInt64 = 75_000_000

struct ClipboardPanelView: View {
    let onClose: () -> Void

    private let store = ClipboardStore.shared
    @StateObject private var panelModel = ClipboardPanelViewModel()
    @StateObject private var quickClipboardModel = QuickClipboardModel()
    @State private var selectedItemID: UUID?
    @State private var selectedItemIDs = Set<UUID>()
    @State private var selectedGroupID: UUID?
    @State private var lastCompletedQuery = ""
    @State private var lockedTab = ClipboardPanelTabLock.tab()
    @State private var quickClipboardPresented = false

    private var selectedTab: ClipboardTab {
        panelModel.state.selectedTab
    }

    private var filteredItems: [ClipboardItem] {
        panelModel.state.items
    }

    private var filteredGroups: [ClipboardGroup] {
        panelModel.state.groups
    }

    private var selectedItems: [ClipboardItem] {
        filteredItems.filter { selectedItemIDs.contains($0.id) }
    }

    private var selectedItem: ClipboardItem? {
        guard let selectedItemID else { return nil }
        return panelModel.state.item(withID: selectedItemID)
    }

    private var selectedGroup: ClipboardGroup? {
        guard let selectedGroupID else { return nil }
        return panelModel.state.group(withID: selectedGroupID)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if selectedItemIDs.count > 1, selectedTab != .groups {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.blue)
                    Text("已选择 \(selectedItemIDs.count) 项")
                        .font(.system(size: 11, weight: .semibold))
                    Text("按 Enter 保存为分组并粘贴")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("⌘ 点击可增减选择")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(Color.blue.opacity(0.08))
            }

            content
        }
        .background(ClipboardBackgroundView())
        .background(SearchSurfaceVisibility { panelModel.setActive($0) }.frame(width: 0, height: 0).allowsHitTesting(false))
        .onDisappear { panelModel.setActive(false) }
        .onAppear {
            if let lockedTab {
                panelModel.selectTab(lockedTab)
            }
            resetSelection()
        }
        .onChange(of: panelModel.state.resultRevision) { _, _ in
            let completedQuery = panelModel.state.query
            if completedQuery != lastCompletedQuery,
               !panelModel.state.isSearching {
                lastCompletedQuery = completedQuery
                resetSelection()
            } else {
                reconcileSelection()
            }
        }
        .onChange(of: quickClipboardPresented) { _, isPresented in
            if !isPresented {
                ClipboardPanelKeyboardRouter.shared.area = .history
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .clipboardPanelActivateSelection
            )
        ) { notification in
            let extending = notification.userInfo?[
                "extendsSelection"
            ] as? Bool ?? false
            activateSelection(extendingSelection: extending)
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .help("关闭")

                Image(systemName: "doc.on.clipboard.fill")
                    .font(.system(size: 20))
                Text("剪切板管理器")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()

                Button {
                    onClose()
                    SettingsWindowController.shared.show()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14, weight: .medium))
                }
                .buttonStyle(.plain)
                .help("设置")

                Button {
                    store.clear(selectedTab)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 14))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .disabled(
                    !panelModel.hasContent(in: selectedTab)
                )
                .help("清空当前分类")

                Button {
                    quickClipboardPresented.toggle()
                    ClipboardPanelKeyboardRouter.shared.area = .quickClipboard
                } label: {
                    Image(systemName: "tray.full.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.indigo)
                }
                .buttonStyle(.plain)
                .help("常用内容")
                .accessibilityLabel("常用内容")
                .popover(isPresented: $quickClipboardPresented, arrowEdge: .top) {
                    QuickClipboardPopoverView(
                        model: quickClipboardModel,
                        onCollapse: {
                            quickClipboardPresented = false
                            ClipboardPanelKeyboardRouter.shared.area = .history
                        }
                    )
                    .frame(width: 320, height: 480)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)

            HStack(spacing: 8) {
                HStack(spacing: 0) {
                    ForEach(ClipboardTab.allCases) { tab in
                        Button {
                            selectTab(tab)
                        } label: {
                            VStack(spacing: 7) {
                                Text(tab.name)
                                    .font(.system(size: 12, weight: .medium))
                                Rectangle()
                                    .fill(
                                        selectedTab == tab
                                            ? Color.primary
                                            : Color.clear
                                    )
                                    .frame(height: 2)
                            }
                            .foregroundStyle(
                                selectedTab == tab ? .primary : .secondary
                            )
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                }

                Button(action: toggleTabLock) {
                    Image(systemName: lockedTab == nil ? "pin" : "pin.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(
                            lockedTab == nil ? Color.secondary : Color.blue
                        )
                        .frame(width: 26, height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(
                                    lockedTab == nil
                                        ? Color.clear
                                        : Color.blue.opacity(0.12)
                                )
                        )
                }
                .buttonStyle(.plain)
                .help(
                    lockedTab == nil
                        ? "锁定当前分类"
                        : "取消锁定并返回“全部”"
                )
                .accessibilityLabel(
                    lockedTab == nil
                        ? "锁定当前分类"
                        : "取消锁定分类"
                )
            }
            .padding(.horizontal, 16)

            ClipboardSearchBar(
                onQueryChange: panelModel.updateQuery,
                onMove: moveSelection,
                onActivate: { activateSelection() },
                onCancel: onClose
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .simultaneousGesture(TapGesture().onEnded {
            ClipboardPanelKeyboardRouter.shared.area = .history
        })
    }

    private var content: some View {
        GeometryReader { geometry in
            let dividerWidth: CGFloat = 1
            let mainWidth = max(0, geometry.size.width - dividerWidth)

            HStack(spacing: 0) {
                listContent
                    .frame(width: mainWidth * 2 / 3)
                    .simultaneousGesture(TapGesture().onEnded {
                        ClipboardPanelKeyboardRouter.shared.area = .history
                    })
                Divider()
                    .frame(width: dividerWidth)
                detailContent
                    .frame(width: mainWidth / 3)
                    .simultaneousGesture(TapGesture().onEnded {
                        ClipboardPanelKeyboardRouter.shared.area = .history
                    })
            }
        }
    }

    @ViewBuilder
    private var listContent: some View {
        if selectedTab == .groups {
            if filteredGroups.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filteredGroups) { group in
                            ClipboardGroupRow(
                                group: group,
                                isSelected: selectedGroupID == group.id,
                                onSelect: {
                                    selectedGroupID = group.id
                                },
                                onActivate: { activate(group) },
                                onCopy: {
                                    store.copyGroupToClipboard(group)
                                },
                                onDelete: { delete(group) }
                            )
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        } else if filteredItems.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filteredItems) { item in
                            ClipboardItemRow(
                                item: item,
                                isSelected: selectedItemIDs.isEmpty
                                    ? selectedItemID == item.id
                                    : selectedItemIDs.contains(item.id),
                                isFocused: selectedItemID == item.id,
                                isPinned: panelModel.state.pinnedIDs.contains(item.id),
                                onSelect: {
                                    if NSEvent.modifierFlags.contains(.command) {
                                        select(item, extending: true)
                                    } else {
                                        select(item, extending: false)
                                    }
                                },
                                onActivate: { activate(item) },
                                onTogglePin: { togglePin(item) },
                                onCopy: { store.copyToClipboard(item) },
                                onDelete: { delete(item) }
                            )
                            .id(item.id)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .onChange(of: selectedItemID) { _, id in
                    guard let id else { return }
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        if selectedTab == .groups {
            if let selectedGroup {
                ClipboardGroupDetailView(
                    title: selectedGroup.title,
                    timestamp: selectedGroup.timestamp,
                    items: selectedGroup.items,
                    primaryActionTitle: "粘贴",
                    onPaste: { activate(selectedGroup) },
                    onCopy: {
                        store.copyGroupToClipboard(selectedGroup)
                    },
                    onDelete: { delete(selectedGroup) }
                )
                .id(selectedGroup.id)
            } else {
                detailEmptyState
            }
        } else if selectedItems.count > 1 {
            ClipboardGroupDetailView(
                title: "已选择 \(selectedItems.count) 项",
                timestamp: selectedItems.map(\.timestamp).max() ?? Date(),
                items: selectedItems,
                primaryActionTitle: "保存并粘贴",
                onPaste: { activateSelection() },
                onCopy: nil,
                onDelete: nil
            )
        } else if let selectedItem {
            ClipboardItemDetailView(
                item: selectedItem,
                isPinned: panelModel.state.pinnedIDs.contains(selectedItem.id),
                onPaste: { activate(selectedItem) },
                onCopy: { store.copyToClipboard(selectedItem) },
                onTogglePin: { togglePin(selectedItem) },
                onDelete: { delete(selectedItem) }
            )
            .id(selectedItem.id)
        } else {
            detailEmptyState
        }
    }

    private var detailEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text("选择一项查看详情")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: panelModel.state.query.isEmpty
                ? selectedTab.icon
                : "magnifyingglass")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(panelModel.state.query.isEmpty
                ? "暂无\(selectedTab.name)内容"
                : "没有找到结果")
                .font(.system(size: 14, weight: .medium))
            Text(panelModel.state.query.isEmpty
                ? "复制内容后会自动出现在这里"
                : "请尝试更准确的关键词")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func resetSelection() {
        selectedItemIDs.removeAll()
        selectedItemID = selectedTab == .groups ? nil : filteredItems.first?.id
        selectedGroupID = selectedTab == .groups
            ? filteredGroups.first?.id
            : nil
    }

    private func reconcileSelection() {
        if selectedTab == .groups {
            selectedItemID = nil
            selectedItemIDs.removeAll()
            if selectedGroupID.flatMap({ id in
                filteredGroups.first { $0.id == id }
            }) == nil {
                selectedGroupID = filteredGroups.first?.id
            }
            return
        }

        selectedGroupID = nil
        let validIDs = panelModel.state.itemIndexByID
        selectedItemIDs = Set(selectedItemIDs.filter(validIDs.contains))
        if selectedItemID.map(validIDs.contains) != true {
            selectedItemID = filteredItems.first?.id
        }
    }

    private func selectTab(_ tab: ClipboardTab) {
        panelModel.selectTab(tab)
        if lockedTab != nil {
            setLockedTab(tab)
        }
        resetSelection()
    }

    private func toggleTabLock() {
        if lockedTab == nil {
            setLockedTab(selectedTab)
        } else {
            setLockedTab(nil)
            panelModel.selectTab(.all)
            resetSelection()
        }
    }

    private func setLockedTab(_ tab: ClipboardTab?) {
        lockedTab = tab
        ClipboardPanelTabLock.set(tab)
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        switch direction {
        case .left, .right:
            let tabs = ClipboardTab.allCases
            guard let index = tabs.firstIndex(of: selectedTab) else { return }
            let offset = direction == .left ? -1 : 1
            selectTab(tabs[(index + offset + tabs.count) % tabs.count])
        case .up, .down:
            if selectedTab == .groups {
                selectedGroupID = movedSelection(
                    currentID: selectedGroupID,
                    ids: panelModel.state.groupIDs,
                    direction: direction
                )
            } else {
                selectedItemID = movedItemSelection(direction)
                if !NSEvent.modifierFlags.contains(.command) {
                    selectedItemIDs.removeAll()
                }
            }
        default:
            break
        }
    }

    private func movedItemSelection(
        _ direction: MoveCommandDirection
    ) -> UUID? {
        let ids = panelModel.state.itemIDs
        guard !ids.isEmpty else { return nil }
        guard let selectedItemID,
              let index = panelModel.state.itemIndexByID[selectedItemID] else {
            return direction == .up ? ids.last : ids.first
        }
        return direction == .up
            ? ids[max(0, index - 1)]
            : ids[min(ids.count - 1, index + 1)]
    }

    private func movedSelection(
        currentID: UUID?,
        ids: [UUID],
        direction: MoveCommandDirection
    ) -> UUID? {
        guard !ids.isEmpty else { return nil }
        guard let currentID, let index = ids.firstIndex(of: currentID) else {
            return direction == .up ? ids.last : ids.first
        }
        return direction == .up
            ? ids[max(0, index - 1)]
            : ids[min(ids.count - 1, index + 1)]
    }

    private func select(_ item: ClipboardItem, extending: Bool) {
        selectedItemID = item.id
        if extending {
            if selectedItemIDs.contains(item.id) {
                selectedItemIDs.remove(item.id)
            } else {
                selectedItemIDs.insert(item.id)
            }
        } else {
            selectedItemIDs.removeAll()
        }
    }

    private func togglePin(_ item: ClipboardItem) {
        let index = panelModel.state.itemIndexByID[item.id] ?? 0
        store.togglePin(for: item)
        selectNeighbor(afterRemoving: item.id, preferredIndex: index)
    }

    private func delete(_ item: ClipboardItem) {
        let index = panelModel.state.itemIndexByID[item.id] ?? 0
        store.delete(item)
        selectNeighbor(afterRemoving: item.id, preferredIndex: index)
    }

    private func selectNeighbor(afterRemoving id: UUID, preferredIndex: Int) {
        selectedItemIDs.remove(id)
        guard selectedItemID == id
                || selectedItemID.flatMap({ panelModel.state.item(withID: $0) }) == nil else {
            return
        }
        guard !filteredItems.isEmpty else {
            selectedItemID = nil
            return
        }
        selectedItemID = filteredItems[min(preferredIndex, filteredItems.count - 1)].id
    }

    private func delete(_ group: ClipboardGroup) {
        let index = filteredGroups.firstIndex { $0.id == group.id } ?? 0
        store.delete(group)
        guard !filteredGroups.isEmpty else {
            selectedGroupID = nil
            return
        }
        selectedGroupID = filteredGroups[min(index, filteredGroups.count - 1)].id
    }

    private func activateSelection(extendingSelection: Bool = false) {
        if selectedTab == .groups {
            guard let selectedGroupID,
                  let group = panelModel.state.group(withID: selectedGroupID) else {
                return
            }
            activate(group)
            return
        }

        if extendingSelection {
            guard let selectedItemID,
                  let item = panelModel.state.item(withID: selectedItemID) else {
                return
            }
            select(item, extending: true)
            return
        }

        let selected = filteredItems.filter {
            selectedItemIDs.contains($0.id)
        }
        if selected.count > 1,
           let group = store.createGroup(from: selected) {
            activate(group)
            return
        }
        let item = selected.first
            ?? selectedItemID.flatMap { id in
                panelModel.state.item(withID: id)
            }
        guard let item else { return }
        activate(item)
    }

    private func activate(_ item: ClipboardItem) {
        selectedItemID = item.id
        guard store.activateItem(item) else { return }
        onClose()
        PasteCoordinator.shared.pasteIntoCapturedApplication()
    }

    private func activate(_ group: ClipboardGroup) {
        selectedGroupID = group.id
        guard store.activateGroup(group) else { return }
        onClose()
        PasteCoordinator.shared.pasteGroupIntoCapturedApplication(group)
    }
}

private enum MoveCommandDirection {
    case left
    case right
    case up
    case down
    case other
}

private struct ClipboardSearchBar: View {
    @StateObject private var search = ClipboardSearchModel()

    let onQueryChange: (String) -> Void
    let onMove: (MoveCommandDirection) -> Void
    let onActivate: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            ClipboardSearchField(
                text: $search.text,
                onMove: onMove,
                onActivate: onActivate,
                onCancel: onCancel
            )
            .frame(height: 20)
            if !search.text.isEmpty {
                Button {
                    search.text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.secondary.opacity(0.10))
        )
        .onChange(of: search.query) { _, query in
            onQueryChange(query)
        }
    }
}

private struct ClipboardSearchField: NSViewRepresentable {
    @Binding var text: String
    let onMove: (MoveCommandDirection) -> Void
    let onActivate: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NativeSearchField {
        let field = NativeSearchField()
        field.delegate = context.coordinator
        field.placeholderString = "搜索剪切板…"
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12)
        field.onMove = onMove
        field.onActivate = onActivate
        field.onCancel = onCancel
        return field
    }

    func updateNSView(_ field: NativeSearchField, context: Context) {
        if field.stringValue != text {
            field.stringValue = text
        }
        field.onMove = onMove
        field.onActivate = onActivate
        field.onCancel = onCancel
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text = field.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy selector: Selector
        ) -> Bool {
            guard let field = control as? NativeSearchField else { return false }
            switch selector {
            case #selector(NSResponder.moveLeft(_:)):
                field.onMove?(.left)
            case #selector(NSResponder.moveRight(_:)):
                field.onMove?(.right)
            case #selector(NSResponder.moveUp(_:)):
                field.onMove?(.up)
            case #selector(NSResponder.moveDown(_:)):
                field.onMove?(.down)
            case #selector(NSResponder.insertNewline(_:)):
                field.onActivate?()
            case #selector(NSResponder.cancelOperation(_:)):
                field.onCancel?()
            default:
                return false
            }
            return true
        }
    }
}

private final class NativeSearchField: NSTextField {
    var onMove: ((MoveCommandDirection) -> Void)?
    var onActivate: (() -> Void)?
    var onCancel: (() -> Void)?
    private var requestedFocus = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !requestedFocus else { return }
        requestedFocus = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
        }
    }
}

private struct ClipboardItemRow: View {
    let item: ClipboardItem
    let isSelected: Bool
    let isFocused: Bool
    let isPinned: Bool
    let onSelect: () -> Void
    let onActivate: () -> Void
    let onTogglePin: () -> Void
    let onCopy: () -> Bool
    let onDelete: () -> Void

    @State private var copyResult: Bool?
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                ClipboardLeadingPreview(item: item)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.displayPreview)
                        .font(.system(size: 12))
                        .lineLimit(item.type == .file ? 1 : 2)
                        .multilineTextAlignment(.leading)
                    if let filePath = item.filePathPreview {
                        Text(filePath)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    HStack {
                        Text(item.type.displayName)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(relativeTime(from: item.timestamp))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .gesture(rowGesture)

            if isHovered {
                HStack(spacing: 8) {
                    Button(action: onTogglePin) {
                        Image(systemName: isPinned ? "heart.fill" : "heart")
                            .foregroundStyle(isPinned ? .red : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(isPinned ? "取消收藏" : "收藏")

                    Button {
                        copyResult = onCopy()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                            copyResult = nil
                        }
                    } label: {
                        Image(systemName: copyResult == true
                            ? "checkmark.circle.fill"
                            : (copyResult == false
                                ? "exclamationmark.circle.fill"
                                : "doc.on.doc"))
                            .foregroundStyle(copyResult == false ? .red : .green)
                    }
                    .buttonStyle(.plain)
                    .help("复制")

                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .help("删除")
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(
                    isSelected
                        ? Color.accentColor.opacity(0.22)
                        : (isHovered
                            ? Color.secondary.opacity(0.08)
                            : Color.clear)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(
                    isFocused ? Color.accentColor.opacity(0.75) : .clear,
                    lineWidth: 1
                )
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var rowGesture: some Gesture {
        TapGesture(count: 2)
            .exclusively(before: TapGesture(count: 1))
            .onEnded { result in
                switch result {
                case .first:
                    onActivate()
                case .second:
                    onSelect()
                }
            }
    }
}

private struct ClipboardGroupRow: View {
    let group: ClipboardGroup
    let isSelected: Bool
    let onSelect: () -> Void
    let onActivate: () -> Void
    let onCopy: () -> Bool
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.secondary.opacity(0.10))
                    Image(systemName: "square.stack.3d.up.fill")
                        .foregroundStyle(.blue)
                }
                .frame(width: 64, height: 46)

                VStack(alignment: .leading, spacing: 4) {
                    Text(group.title)
                        .font(.system(size: 12, weight: .semibold))
                    Text(group.preview)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Text(relativeTime(from: group.timestamp))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .gesture(rowGesture)

            if isHovered {
                Button {
                    _ = onCopy()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .foregroundStyle(.green)
                }
                .buttonStyle(.plain)
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(
                    isSelected
                        ? Color.accentColor.opacity(0.22)
                        : (isHovered
                            ? Color.secondary.opacity(0.08)
                            : Color.clear)
                )
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var rowGesture: some Gesture {
        TapGesture(count: 2)
            .exclusively(before: TapGesture(count: 1))
            .onEnded { result in
                switch result {
                case .first:
                    onActivate()
                case .second:
                    onSelect()
                }
            }
    }
}

private struct ClipboardItemDetailView: View {
    let item: ClipboardItem
    let isPinned: Bool
    let onPaste: () -> Void
    let onCopy: () -> Bool
    let onTogglePin: () -> Void
    let onDelete: () -> Void

    @State private var copyResult: Bool?
    @State private var textStatistics: ClipboardTextStatistics?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: item.type.icon)
                        .foregroundStyle(item.type == .file ? .orange : .blue)
                    Text(item.type.displayName)
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(relativeTime(from: item.timestamp))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    Button(action: onPaste) {
                        Label("粘贴", systemImage: "arrow.turn.down.left")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Spacer()

                    Button {
                        copyResult = onCopy()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                            copyResult = nil
                        }
                    } label: {
                        Image(systemName: copyResult == true
                            ? "checkmark.circle.fill"
                            : (copyResult == false
                                ? "exclamationmark.circle.fill"
                                : "doc.on.doc"))
                            .foregroundStyle(copyResult == false ? .red : .green)
                    }
                    .buttonStyle(.plain)
                    .help("复制")

                    Button(action: onTogglePin) {
                        Image(systemName: isPinned ? "heart.fill" : "heart")
                            .foregroundStyle(isPinned ? .red : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(isPinned ? "取消收藏" : "收藏")

                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .help("删除")
                }
            }
            .padding(14)

            Divider()

            ScrollView {
                itemContent
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(14)
            }

            Divider()

            itemMetadata
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
        }
        .task(id: item.id) {
            textStatistics = nil
            guard let text = item.detailText else { return }
            do {
                try await Task.sleep(
                    nanoseconds: clipboardDetailLoadDelayNanoseconds
                )
            } catch {
                return
            }
            let statistics = await ClipboardDetailTextQueue.shared.statistics(
                for: text
            )
            guard !Task.isCancelled else { return }
            textStatistics = statistics
        }
    }

    @ViewBuilder
    private var itemContent: some View {
        switch item.type {
        case .text, .url, .unknown:
            Text(verbatim: item.detailText ?? item.preview)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(item.type == .url ? .blue : .primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .rtf:
            ClipboardRichTextDetailView(item: item)
        case .image:
            ClipboardImageDetailView(item: item)
        case .file:
            ClipboardFileDetailView(paths: item.fileDetailPaths)
        }
    }

    private var itemMetadata: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(item.timestamp.formatted(date: .numeric, time: .standard))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            if let statistics = textStatistics {
                Text(
                    "\(statistics.characterCount) 个字符 · "
                        + "\(statistics.lineCount) 行 · "
                        + ByteCountFormatter.string(
                            fromByteCount: Int64(statistics.utf8ByteCount),
                            countStyle: .file
                        )
                )
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            } else if item.type == .file {
                Text("\(item.fileDetailPaths.count) 个文件")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ClipboardRichTextDetailView: View {
    let item: ClipboardItem
    @State private var attributedText: AttributedString?

    var body: some View {
        Group {
            if let attributedText {
                Text(attributedText)
            } else {
                Text(verbatim: item.detailText ?? item.preview)
                    .font(.system(size: 12))
            }
        }
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .task(id: item.id) {
            attributedText = nil
            do {
                try await Task.sleep(
                    nanoseconds: clipboardDetailLoadDelayNanoseconds
                )
            } catch {
                return
            }
            let loaded = await ClipboardDetailTextQueue.shared.richText(
                for: item
            )
            guard !Task.isCancelled,
                  let loaded else {
                return
            }
            attributedText = loaded
        }
    }
}

private struct ClipboardFileDetailView: View {
    let paths: [String]

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(Array(paths.enumerated()), id: \.offset) { index, path in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.fill")
                            .foregroundStyle(.orange)
                        Text(URL(fileURLWithPath: path).lastPathComponent)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                    }
                    Text(verbatim: path)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(0.08))
                )
                .accessibilityLabel("文件 \(index + 1)")
            }
        }
    }
}

private struct ClipboardImageDetailView: View {
    let item: ClipboardItem
    @State private var payload: ClipboardDetailImagePayload?
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 10) {
            Group {
                if let image = payload?.image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, minHeight: 180)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.system(size: 28))
                        Text("无法载入图片预览")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 180)
                }
            }

            if let metadata = payload?.metadata {
                Text(
                    "\(metadata.pixelWidth) × \(metadata.pixelHeight) · "
                        + ByteCountFormatter.string(
                            fromByteCount: metadata.byteCount,
                            countStyle: .file
                        )
                )
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }
        }
        .task(id: item.imageFileName) {
            payload = nil
            isLoading = true
            guard let url = item.imageFileURL else {
                isLoading = false
                return
            }
            do {
                try await Task.sleep(
                    nanoseconds: clipboardDetailLoadDelayNanoseconds
                )
            } catch {
                return
            }
            let loaded = await ClipboardImageDecodeQueue.shared.detail(
                from: url
            )
            guard !Task.isCancelled else { return }
            payload = loaded
            isLoading = false
        }
    }
}

private struct ClipboardDetailImagePayload: @unchecked Sendable {
    let image: NSImage?
    let metadata: ClipboardImageMetadata?

    static func load(from url: URL) -> ClipboardDetailImagePayload {
        let metadata = ClipboardImageMetadata.load(from: url)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return ClipboardDetailImagePayload(image: nil, metadata: metadata)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 1_600
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            return ClipboardDetailImagePayload(image: nil, metadata: metadata)
        }
        return ClipboardDetailImagePayload(
            image: NSImage(
                cgImage: thumbnail,
                size: NSSize(width: thumbnail.width, height: thumbnail.height)
            ),
            metadata: metadata
        )
    }
}

private struct ClipboardGroupDetailView: View {
    let title: String
    let timestamp: Date
    let items: [ClipboardItem]
    let primaryActionTitle: String
    let onPaste: () -> Void
    let onCopy: (() -> Bool)?
    let onDelete: (() -> Void)?

    @State private var copyResult: Bool?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .foregroundStyle(.blue)
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                    Spacer()
                }

                HStack(spacing: 10) {
                    Button(action: onPaste) {
                        Label(primaryActionTitle, systemImage: "arrow.turn.down.left")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Spacer()

                    if let onCopy {
                        Button {
                            copyResult = onCopy()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                                copyResult = nil
                            }
                        } label: {
                            Image(systemName: copyResult == true
                                ? "checkmark.circle.fill"
                                : (copyResult == false
                                    ? "exclamationmark.circle.fill"
                                    : "doc.on.doc"))
                                .foregroundStyle(copyResult == false ? .red : .green)
                        }
                        .buttonStyle(.plain)
                        .help("复制")
                    }

                    if let onDelete {
                        Button(action: onDelete) {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                        .help("删除")
                    }
                }
            }
            .padding(14)

            Divider()

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(items) { item in
                        ClipboardGroupDetailItem(item: item)
                    }
                }
                .padding(14)
            }

            Divider()

            VStack(alignment: .leading, spacing: 5) {
                Text(timestamp.formatted(date: .numeric, time: .standard))
                Text("\(items.count) 项 · \(ClipboardGroup(items: items).title)")
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
    }
}

private struct ClipboardGroupDetailItem: View {
    let item: ClipboardItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ClipboardLeadingPreview(item: item)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.type.displayName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(verbatim: summary)
                    .font(.system(size: 11))
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    private var summary: String {
        if item.type == .file {
            return item.fileDetailPaths.joined(separator: "\n")
        }
        return item.detailText ?? item.displayPreview
    }
}

private struct ClipboardLeadingPreview: View {
    let item: ClipboardItem
    @State private var thumbnail: NSImage?

    var body: some View {
        Group {
            if item.type == .image, let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: 64, height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(
                            item.type == .file
                                ? Color.orange.opacity(0.16)
                                : Color.secondary.opacity(0.08)
                        )
                    Image(systemName: item.type.icon)
                        .font(.system(size: 16))
                        .foregroundStyle(item.type == .file ? .orange : .blue)
                }
                .frame(width: 64, height: 46)
            }
        }
        .task(id: item.imageFileName) {
            thumbnail = nil
            guard item.type == .image, let fileName = item.imageFileName else {
                return
            }
            thumbnail = await ThumbnailCache.shared.thumbnail(fileName: fileName)
        }
    }
}

private actor ThumbnailCache {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, NSImage>()
    private var tasks: [String: Task<NSImage?, Never>] = [:]

    init() {
        cache.countLimit = 160
        cache.totalCostLimit = 48 * 1_024 * 1_024
    }

    func thumbnail(fileName: String) async -> NSImage? {
        let key = fileName as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        if let task = tasks[fileName] {
            return await task.value
        }

        let url = ClipboardStorage.imagesDirectory
            .appendingPathComponent(fileName)
        let task = Task(priority: .utility) {
            await ClipboardImageDecodeQueue.shared.thumbnail(from: url)
        }
        tasks[fileName] = task
        let image = await task.value
        tasks[fileName] = nil
        if let image {
            let cost = max(
                1,
                Int(image.size.width * image.size.height * 4)
            )
            cache.setObject(image, forKey: key, cost: cost)
        }
        return image
    }

    nonisolated static func makeThumbnail(url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 240
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            return nil
        }
        return NSImage(
            cgImage: image,
            size: NSSize(width: image.width, height: image.height)
        )
    }
}

actor ClipboardImageDecodeQueue {
    static let shared = ClipboardImageDecodeQueue()

    fileprivate func detail(from url: URL) -> ClipboardDetailImagePayload {
        ClipboardDetailImagePayload.load(from: url)
    }

    func thumbnail(from url: URL) -> NSImage? {
        ThumbnailCache.makeThumbnail(url: url)
    }
}

private actor ClipboardDetailTextQueue {
    static let shared = ClipboardDetailTextQueue()

    func statistics(for text: String) -> ClipboardTextStatistics {
        ClipboardTextStatistics(text: text)
    }

    func richText(for item: ClipboardItem) -> AttributedString? {
        guard !Task.isCancelled,
              let data = item.getRTFData(),
              !Task.isCancelled,
              let richText = NSAttributedString(
                rtf: data,
                documentAttributes: nil
              ),
              !richText.string.isEmpty,
              !Task.isCancelled else {
            return nil
        }
        return AttributedString(richText)
    }
}
