import SwiftUI
import SharedSupport

/// Compact local todo page with optional deadlines.
struct MemoWorkspaceView: View {
    @ObservedObject var model: MemoModel
    @Environment(\.panelBackAction) private var back
    @State private var showingDeadlinePicker = false
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            PanelToolbar("备忘录", back: back) { EmptyView() }
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    composer
                    if let message = model.storageMessage {
                        Label(message, systemImage: "internaldrive.badge.exclamationmark")
                            .font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if model.sortedItems.isEmpty {
                        emptyState
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(model.sortedItems) { item in taskRow(item) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { titleFocused = true }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("写下要做的事", text: $model.draftTitle)
                .textFieldStyle(.roundedBorder)
                .focused($titleFocused)
                .onSubmit(add)
                .accessibilityIdentifier("memo.title")
                .frame(minWidth: 0)
            Button {
                showingDeadlinePicker = true
            } label: {
                Image(systemName: model.draftHasDeadline ? "calendar.badge.clock" : "calendar")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(model.draftHasDeadline ? .indigo : .secondary)
            .help(model.draftHasDeadline ? "修改截止时间" : "设置截止时间")
            .accessibilityLabel(model.draftHasDeadline ? "修改截止时间" : "设置截止时间")
            .popover(isPresented: $showingDeadlinePicker, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("截止时间").font(.headline)
                DatePicker("截止时间", selection: $model.draftDeadline, displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.compact)
                    HStack {
                        if model.draftHasDeadline {
                            Button("清除截止时间", role: .destructive) {
                                model.draftHasDeadline = false
                                showingDeadlinePicker = false
                            }
                        }
                        Spacer()
                        Button("完成") {
                            model.draftHasDeadline = true
                            showingDeadlinePicker = false
                        }
                    }
                }
                .padding(14)
            }
            Button("添加", action: add)
                .disabled(model.draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("memo.add")
        }
        .padding(6)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checklist").font(.title2).foregroundStyle(.tertiary)
            Text("暂时没有待办")
            Text("写下待办，完成后勾选即可删除。")
                .font(.caption2).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 28)
        .foregroundStyle(.secondary)
    }

    private func taskRow(_ item: MemoItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Button { model.complete(item) } label: {
                Image(systemName: "circle")
                    .font(.title3).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("勾选后删除")
            .accessibilityLabel("完成并删除：\(item.title)")

            VStack(alignment: .leading, spacing: 6) {
                Text(item.title).font(.subheadline.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                if let deadline = item.deadline {
                    Label {
                        Text(deadline, format: .dateTime.month().day().hour().minute())
                    } icon: {
                        Image(systemName: "calendar")
                    }
                    .font(.caption2)
                    .foregroundStyle(deadline < Date() ? .orange : .secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func add() {
        guard model.addDraft() else { return }
        titleFocused = true
    }
}
