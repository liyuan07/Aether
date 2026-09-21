import SwiftUI

/// Keeps each personal item small: a title, a number of focus blocks, and an optional deadline.
struct MemoWorkspaceView: View {
    @ObservedObject var model: MemoModel
    @State private var title = ""
    @State private var pomodoroCount = 1
    @State private var hasDeadline = false
    @State private var deadline = Date()
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("备忘录", systemImage: "checklist")
                    .font(.headline)
                Spacer()
                Text("1 个番茄 = 25 分钟")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(12)

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
                        LazyVStack(spacing: 8) {
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
        VStack(alignment: .leading, spacing: 8) {
            TextField("写下要做的事", text: $title)
                .textFieldStyle(.roundedBorder)
                .focused($titleFocused)
                .onSubmit(add)
                .accessibilityIdentifier("memo.title")
            HStack(spacing: 10) {
                Stepper(value: $pomodoroCount, in: 1...20) {
                    Label("\(pomodoroCount) 个番茄", systemImage: "timer")
                }
                Spacer(minLength: 0)
                Button("添加", action: add)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("memo.add")
            }
            Toggle("设置截止时间", isOn: $hasDeadline)
                .toggleStyle(.checkbox)
            if hasDeadline {
                DatePicker("截止时间", selection: $deadline, displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.compact)
            }
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checklist").font(.title2).foregroundStyle(.tertiary)
            Text("暂时没有待办")
            Text("按番茄数拆分任务，完成后勾选即可删除。")
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
                HStack(spacing: 6) {
                    Label("\(item.pomodoroCount) 个番茄", systemImage: "timer")
                    if let deadline = item.deadline {
                        Label {
                            Text(deadline, format: .dateTime.month().day().hour().minute())
                        } icon: {
                            Image(systemName: "calendar")
                        }
                            .foregroundStyle(deadline < Date() ? .orange : .secondary)
                    }
                }
                .font(.caption2).foregroundStyle(.secondary)
                Stepper("调整番茄数", value: Binding(
                    get: { item.pomodoroCount },
                    set: { model.updatePomodoroCount(for: item, to: $0) }
                ), in: 1...20)
                .labelsHidden()
                .controlSize(.small)
                .accessibilityLabel("调整 \(item.title) 的番茄数")
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.background.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
    }

    private func add() {
        guard model.add(title: title, pomodoroCount: pomodoroCount, deadline: hasDeadline ? deadline : nil) else { return }
        title = ""
        pomodoroCount = 1
        hasDeadline = false
        titleFocused = true
    }
}
