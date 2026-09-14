import SharedSupport
import SwiftUI

struct PromptWorkspaceView: View {
    @ObservedObject var model: PromptModel
    @State private var confirmingClear = false
    @State private var copied = false
    @FocusState private var focusedEditor: String?

    var body: some View {
        HSplitView {
            historySidebar
                .frame(minWidth: 200, idealWidth: 220, maxWidth: 280)
            workspace
                .frame(minWidth: 610, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 840, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("清空所有历史提示词？", isPresented: $confirmingClear) {
            Button("取消", role: .cancel) {}
            Button("清空历史", role: .destructive) { model.clearHistory() }
        } message: {
            Text("此操作会删除本机保存的全部原始提示词和优化结果，当前编辑区内容会保留。")
        }
        .onChange(of: model.outputText) { _, _ in copied = false }
        .onAppear { focusedEditor = "prompt.input" }
    }

    private var historySidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("历史提示词", systemImage: "clock.arrow.circlepath")
                    .font(.headline)
                Spacer()
                Text("\(model.history.count)").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 16).padding(.top, 20).padding(.bottom, 12)
            TextField("搜索原文或优化结果", text: $model.historyQuery)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("prompt.history.search")
                .padding(.horizontal, 12).padding(.bottom, 10)
            if model.filteredHistory.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "text.bubble").font(.largeTitle).foregroundStyle(.tertiary)
                    Text(model.historyQuery.isEmpty ? "暂无历史提示词" : "没有匹配的历史")
                        .font(.callout).foregroundStyle(.secondary)
                    if model.historyQuery.isEmpty {
                        Text(model.configuration.saveHistory ? "成功优化后，原文与结果会保存在这里。" : "历史记录已关闭，可在设置中开启。")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: Binding(get: { model.selectedHistoryID }, set: { model.selectHistory($0) })) {
                    ForEach(model.filteredHistory) { entry in
                        historyRow(entry).tag(entry.id)
                            .contextMenu {
                                Button("复用原文") { model.reuseHistory(entry) }
                                Divider()
                                Button("删除记录", role: .destructive) { model.deleteHistory(entry) }
                            }
                    }
                }
                .listStyle(.sidebar)
                .accessibilityIdentifier("prompt.history.list")
            }
            Divider()
            HStack {
                Label(model.configuration.saveHistory ? "仅保存在本机" : "历史记录已关闭", systemImage: "internaldrive")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button { confirmingClear = true } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("清空历史提示词")
                    .accessibilityLabel("清空历史提示词")
                    .accessibilityIdentifier("prompt.history.clear")
                    .disabled(model.history.isEmpty)
            }.padding(12)
        }
    }

    private func historyRow(_ entry: PromptHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.original.replacingOccurrences(of: "\n", with: " "))
                .font(.callout.weight(.medium)).lineLimit(2)
            Text(entry.optimized.replacingOccurrences(of: "\n", with: " "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            HStack {
                Text(entry.createdAt, format: .dateTime.month().day().hour().minute())
                Spacer(minLength: 3)
                Text(entry.model).lineLimit(1)
            }.font(.caption2).foregroundStyle(.tertiary)
        }.padding(.vertical, 6)
    }

    private var workspace: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Prompt 优化").font(.title2.weight(.semibold))
                    Text("把零散想法整理成可直接使用的提示词")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.newPrompt(); focusedEditor = "prompt.input" } label: { Label("新建", systemImage: "square.and.pencil") }
                    .accessibilityIdentifier("prompt.new")
                Button { AppRouter.shared.send(.settings(.prompt)) } label: {
                    Image(systemName: "gearshape")
                }
                .help("Prompt 优化设置")
                .accessibilityLabel("Prompt 优化设置")
                .accessibilityIdentifier("prompt.openSettings")
            }
            if !model.isConfigured {
                HStack(spacing: 10) {
                    Image(systemName: "network")
                    Text("先配置兼容 OpenAI 的 API 服务，再开始优化。")
                        .font(.callout)
                    Spacer(minLength: 0)
                    Button("前往设置") { AppRouter.shared.send(.settings(.prompt)) }
                }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            }
            HSplitView {
                inputPanel.frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
                outputPanel.frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
            }
            .layoutPriority(1)
            if let error = model.optimizationError {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(error).textSelection(.enabled)
                    Spacer(minLength: 0)
                    if model.isConfigured {
                        Button("重试") { model.optimize() }.disabled(!model.canOptimize)
                    }
                }.font(.callout).foregroundStyle(.orange)
                    .accessibilityIdentifier("prompt.error")
            }
            if let message = model.historyMessage {
                HStack(alignment: .top) {
                    Label(message, systemImage: "internaldrive.badge.exclamationmark")
                        .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    Spacer(minLength: 4)
                    Button("重试历史存储") { model.retryHistoryStorage() }
                        .accessibilityIdentifier("prompt.history.retryStorage")
                }
            }
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    if model.isConfigured {
                        Text("服务：\(serviceDisplay)")
                            .lineLimit(1).truncationMode(.middle).help(model.configuration.baseURL)
                        Text("点击优化会将输入及优化指令发送给此服务。")
                    } else {
                        Text("支持键盘输入、粘贴及输入法语音输入。")
                    }
                }.font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if model.isOptimizing {
                    ProgressView().controlSize(.small)
                    Text("正在优化…").font(.callout).foregroundStyle(.secondary)
                    Button("取消") { model.cancelOptimization() }
                        .accessibilityIdentifier("prompt.cancel")
                } else {
                    Button { model.optimize() } label: { Label("优化提示词", systemImage: "sparkles") }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!model.canOptimize)
                        .help("优化提示词（⌘↩）")
                        .accessibilityIdentifier("prompt.optimize")
                }
            }
        }.padding(20)
    }

    private var serviceDisplay: String {
        let host = URL(string: model.configuration.baseURL)?.host ?? model.configuration.baseURL
        return "\(host) · \(model.configuration.model)"
    }

    private var inputPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("原始提示词").font(.headline)
                Spacer()
                Button { model.pasteInput() } label: { Label("粘贴", systemImage: "doc.on.clipboard") }
                    .disabled(model.isOptimizing)
                    .accessibilityIdentifier("prompt.paste")
            }
            editor(text: $model.inputText, placeholder: "输入你的目标、背景、要求和已有想法，零散口述也可以。", identifier: "prompt.input")
                .disabled(model.isOptimizing)
            HStack {
                Text("\(model.inputText.count) 字")
                Spacer()
                Text("⌘↩ 优化 · ↩ 换行")
            }.font(.caption).foregroundStyle(.secondary)
        }.padding(.trailing, 8)
    }

    private var outputPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("优化结果").font(.headline)
                Spacer()
                Button {
                    model.copyOutput()
                    copied = true
                } label: { Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc") }
                    .disabled(model.outputText.isEmpty)
                    .accessibilityIdentifier("prompt.copy")
            }
            editor(text: $model.outputText, placeholder: "优化后的提示词会显示在这里，可继续编辑并复制使用。", identifier: "prompt.output")
                .disabled(model.isOptimizing)
            HStack(spacing: 8) {
                Text("\(model.outputText.count) 字")
                Spacer()
                if model.isOptimizing, !model.outputText.isEmpty {
                    Text("上次结果 · 等待更新")
                } else if !model.outputText.isEmpty, model.inputText != model.outputOriginal {
                    Text("上次结果 · 原文已修改")
                } else if let entry = model.selectedHistory {
                    Button("复用原文") { model.reuseHistory(entry) }
                        .buttonStyle(.link).accessibilityIdentifier("prompt.history.reuse")
                    Button { model.deleteHistory(entry) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("删除这条历史记录")
                        .accessibilityLabel("删除这条历史记录")
                        .accessibilityIdentifier("prompt.history.delete")
                } else {
                    Text("可编辑后复制")
                }
            }.font(.caption).foregroundStyle(.secondary)
        }.padding(.leading, 8)
    }

    private func editor(text: Binding<String>, placeholder: String, identifier: String) -> some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: text)
                .focused($focusedEditor, equals: identifier)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .accessibilityLabel(identifier == "prompt.input" ? "原始提示词" : "优化结果")
                .accessibilityIdentifier(identifier)
            if text.wrappedValue.isEmpty {
                Text(placeholder).font(.body).foregroundStyle(.tertiary)
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary, lineWidth: 1))
        .frame(minHeight: 220)
    }
}
