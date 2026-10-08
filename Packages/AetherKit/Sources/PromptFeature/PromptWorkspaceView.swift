import SharedSupport
import SwiftUI

/// A compact tool hosted directly inside the shared menu-bar popover.
struct PromptWorkspaceView: View {
    private enum Page: String, CaseIterable, Identifiable {
        case input = "输入", result = "结果", history = "历史"
        var id: String { rawValue }
    }

    @Environment(\.panelBackAction) private var back
    @ObservedObject var model: PromptModel
    @State private var page: Page = .input
    @State private var confirmingClear = false
    @State private var copied = false
    @State private var awaitingResult = false
    @FocusState private var focusedEditor: String?

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                PanelToolbar("提示词优化", back: back) {
                    Button {
                        awaitingResult = false
                        model.newPrompt()
                        showInput()
                    } label: { Image(systemName: "square.and.pencil") }
                    .help("新建提示词")
                    .accessibilityLabel("新建提示词")
                    .accessibilityIdentifier("prompt.new")
                    Button { AppRouter.shared.send(.settings(.prompt)) } label: { Image(systemName: "gearshape") }
                        .help("Prompt 优化设置")
                        .accessibilityLabel("Prompt 优化设置")
                        .accessibilityIdentifier("prompt.openSettings")
                }.buttonStyle(.borderless)
                Picker("提示词页面", selection: $page) {
                    ForEach(Page.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                .accessibilityIdentifier("prompt.pages")
                .padding(.horizontal, 12)
            }
            .padding(.bottom, 10)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !model.isConfigured { configurationGuide }
                    switch page {
                    case .input: inputPage
                    case .result: resultPage
                    case .history: historyPage
                    }
                    messages
                    serviceNote
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.bottom, 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            actions.padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: model.outputText) { _, _ in copied = false }
        .onChange(of: model.isOptimizing) { wasOptimizing, optimizing in
            if wasOptimizing, !optimizing, awaitingResult {
                awaitingResult = false
                if model.optimizationError == nil, !model.outputText.isEmpty {
                    page = .result
                    focusedEditor = nil
                }
            }
        }
        .onChange(of: page) { _, newPage in
            confirmingClear = false
            if newPage != .input { focusedEditor = nil }
        }
        .onAppear {
            awaitingResult = model.isOptimizing
            if !model.isOptimizing, !model.outputText.isEmpty, model.outputOriginal == model.inputText {
                page = .result
            } else {
                page = .input
                if !model.isOptimizing { focusedEditor = "prompt.input" }
            }
        }
        // Closing the popover keeps the model and its in-flight request alive.
    }

    private var configurationGuide: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("先配置 API 服务和模型，即可开始优化。")
                .font(.caption).foregroundStyle(.secondary)
            Button("前往设置") { AppRouter.shared.send(.settings(.prompt)) }
                .font(.caption)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private var inputPage: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("原始提示词").font(.subheadline.weight(.medium))
                Spacer()
                Button {
                    model.pasteInput()
                    focusedEditor = "prompt.input"
                } label: { Label("粘贴", systemImage: "doc.on.clipboard") }
                .controlSize(.small).disabled(model.isOptimizing)
                .accessibilityIdentifier("prompt.paste")
            }
            editor(text: $model.inputText,
                   placeholder: "输入目标、背景和要求，零散口述也可以。支持输入法语音输入。",
                   identifier: "prompt.input")
                .disabled(model.isOptimizing)
            HStack {
                Text("\(model.inputText.count) 字")
                Spacer()
                Text("⌘↩ 优化 · ↩ 换行")
            }.font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var resultPage: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("优化结果").font(.subheadline.weight(.medium))
                Spacer()
                Text("\(model.outputText.count) 字").font(.caption2).foregroundStyle(.secondary)
            }
            editor(text: $model.outputText, placeholder: "优化后的提示词会显示在这里，可编辑后复制使用。", identifier: "prompt.output")
                .disabled(model.isOptimizing)
            if model.isOptimizing, !model.outputText.isEmpty {
                Text("当前为上次结果，正在等待更新。")
                    .font(.caption2).foregroundStyle(.secondary)
            } else if !model.outputText.isEmpty, model.inputText != model.outputOriginal {
                Text("原文已修改，当前仍是上次优化结果。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let entry = model.selectedHistory {
                HStack(spacing: 10) {
                    Text("已保存于 \(entry.createdAt.formatted(.dateTime.month().day().hour().minute()))")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("复用原文") { reuse(entry) }
                        .accessibilityIdentifier("prompt.history.reuse")
                    deleteButton(entry)
                }.controlSize(.small)
            }
        }
    }

    private var historyPage: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("历史提示词 · \(model.history.count) 条").font(.subheadline.weight(.medium))
                Spacer()
                Button { confirmingClear = true } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .disabled(model.history.isEmpty)
                    .help("清空历史提示词")
                    .accessibilityLabel("清空历史提示词")
                    .accessibilityIdentifier("prompt.history.clear")
            }
            if confirmingClear {
                VStack(alignment: .leading, spacing: 8) {
                    Text("删除全部本机历史？当前编辑内容会保留。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("取消") { confirmingClear = false }
                        Spacer()
                        Button("确认清空", role: .destructive) {
                            model.clearHistory()
                            confirmingClear = false
                        }.accessibilityIdentifier("prompt.history.confirmClear")
                    }.controlSize(.small)
                }
                .padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
            TextField("搜索原文或结果", text: $model.historyQuery)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("prompt.history.search")
            if model.filteredHistory.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "text.bubble").font(.title2).foregroundStyle(.tertiary)
                    Text(model.historyQuery.isEmpty ? "暂无历史提示词" : "没有匹配的历史")
                    if model.historyQuery.isEmpty {
                        Text(model.configuration.saveHistory ? "成功优化后，原文与结果会保存在这里。" : "历史记录已关闭，可在设置中开启。")
                            .font(.caption2)
                    }
                }
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity).padding(.vertical, 24)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(model.filteredHistory) { historyRow($0) }
                }.accessibilityIdentifier("prompt.history.list")
            }
            Label(model.configuration.saveHistory ? "历史仅保存在本机" : "已关闭新增历史，已有记录保留", systemImage: "internaldrive")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func historyRow(_ entry: PromptHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                select(entry, page: .result)
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.original.replacingOccurrences(of: "\n", with: " "))
                        .font(.caption.weight(.medium)).foregroundStyle(.primary).lineLimit(2)
                    Text(entry.optimized.replacingOccurrences(of: "\n", with: " "))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    HStack {
                        Text(entry.createdAt, format: .dateTime.month().day().hour().minute())
                        Spacer(minLength: 4)
                        Text(entry.model).lineLimit(1)
                    }.font(.caption2).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("查看优化结果")
            HStack(spacing: 10) {
                Button("查看原文") { select(entry, page: .input) }
                Button("复用") { reuse(entry) }
                Spacer(minLength: 0)
                deleteButton(entry)
            }.controlSize(.small)
        }
        .padding(10)
        .background(model.selectedHistoryID == entry.id ? Color.accentColor.opacity(0.09) : Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 8))
    }

    private func deleteButton(_ entry: PromptHistoryEntry) -> some View {
        Button { model.deleteHistory(entry) } label: { Image(systemName: "trash") }
            .buttonStyle(.borderless)
            .help("删除这条历史记录")
            .accessibilityLabel("删除这条历史记录")
            .accessibilityIdentifier("prompt.history.delete")
    }

    @ViewBuilder
    private var messages: some View {
        if let error = model.optimizationError {
            VStack(alignment: .leading, spacing: 6) {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("prompt.error")
                if model.isConfigured {
                    Button("重试") { startOptimization() }.disabled(!model.canOptimize).controlSize(.small)
                }
            }
        }
        if let message = model.historyMessage {
            VStack(alignment: .leading, spacing: 6) {
                Label(message, systemImage: "internaldrive.badge.exclamationmark")
                    .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Button("重试历史存储") { model.retryHistoryStorage() }
                    .controlSize(.small).accessibilityIdentifier("prompt.history.retryStorage")
            }
        }
    }

    private var serviceNote: some View {
        VStack(alignment: .leading, spacing: 4) {
            if model.isConfigured {
                Text("服务：\(serviceDisplay)")
                    .lineLimit(2).truncationMode(.middle).help(model.configuration.baseURL)
                Text("优化时发送输入及优化指令；关闭菜单后继续处理。")
            } else {
                Text("支持键盘、粘贴及输入法语音输入。")
            }
        }.font(.caption2).foregroundStyle(.secondary)
    }

    private var serviceDisplay: String {
        let host = URL(string: model.configuration.baseURL)?.host ?? model.configuration.baseURL
        return "\(host) · \(model.configuration.model)"
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                model.copyOutput()
                copied = true
            } label: { Label(copied ? "已复制" : "复制结果", systemImage: copied ? "checkmark" : "doc.on.doc") }
                .disabled(model.outputText.isEmpty)
                .accessibilityIdentifier("prompt.copy")
            Spacer(minLength: 0)
            if model.isOptimizing {
                ProgressView().controlSize(.small)
                Button("取消") {
                    awaitingResult = false
                    model.cancelOptimization()
                }.accessibilityIdentifier("prompt.cancel")
            } else {
                Button { startOptimization() } label: { Label("优化", systemImage: "sparkles") }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!model.canOptimize)
                    .help("优化提示词（⌘↩）")
                    .accessibilityLabel("优化提示词")
                    .accessibilityIdentifier("prompt.optimize")
            }
        }.controlSize(.regular)
    }

    private func editor(text: Binding<String>, placeholder: String, identifier: String) -> some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: text)
                .focused($focusedEditor, equals: identifier)
                .font(.body).scrollContentBackground(.hidden).padding(6)
                .accessibilityLabel(identifier == "prompt.input" ? "原始提示词" : "优化结果")
                .accessibilityIdentifier(identifier)
            if text.wrappedValue.isEmpty {
                Text(placeholder).font(.body).foregroundStyle(.tertiary)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .frame(height: 200)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary, lineWidth: 1))
    }

    private func startOptimization() {
        if page == .history { page = .input }
        model.optimize()
        awaitingResult = model.isOptimizing
        if model.isOptimizing { focusedEditor = nil }
    }

    private func showInput() {
        page = .input
        confirmingClear = false
        focusedEditor = "prompt.input"
    }

    private func select(_ entry: PromptHistoryEntry, page selectedPage: Page) {
        awaitingResult = false
        model.selectHistory(entry.id)
        page = selectedPage
        if selectedPage == .input { focusedEditor = "prompt.input" }
    }

    private func reuse(_ entry: PromptHistoryEntry) {
        awaitingResult = false
        model.reuseHistory(entry)
        showInput()
    }
}
