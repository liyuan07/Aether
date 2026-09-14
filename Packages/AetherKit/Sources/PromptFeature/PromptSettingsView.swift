import SharedSupport
import SwiftUI

struct PromptSettingsView: View {
    @ObservedObject var model: PromptModel

    var body: some View {
        SettingsContent("Prompt 优化") {
            VStack(spacing: 0) {
            Form {
                Section {
                    Text("输入零散想法或口述内容，一键整理为可直接使用的提示词。")
                        .foregroundStyle(.secondary)
                    Button { AppRouter.shared.send(.prompt) } label: {
                        Label("打开 Prompt 优化", systemImage: "sparkles")
                    }.accessibilityIdentifier("prompt.settings.openWorkspace")
                }
                Section {
                    TextField("Base URL", text: $model.draftConfiguration.baseURL, prompt: Text("https://api.example.com/v1"))
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("prompt.settings.baseURL")
                    TextField("模型名称", text: $model.draftConfiguration.model, prompt: Text("服务商提供的模型 ID"))
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("prompt.settings.model")
                    SecureField("API Key", text: $model.draftAPIKey, prompt: Text("本地服务可留空"))
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("prompt.settings.apiKey")
                } header: {
                    Text("模型服务")
                } footer: {
                    Text("使用兼容 OpenAI Chat Completions 的接口。Base URL 可填写服务根地址、/v1 地址或完整 /chat/completions 地址。API Key 保存在 macOS 钥匙串；只有点击“保存设置”后才会更新。")
                }
                Section {
                    Toggle("保存历史提示词", isOn: $model.draftConfiguration.saveHistory)
                        .accessibilityIdentifier("prompt.settings.saveHistory")
                    HStack {
                        Text("最多保留")
                        TextField("历史记录条数", value: $model.draftConfiguration.historyLimit, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder).frame(width: 72)
                            .accessibilityIdentifier("prompt.settings.historyLimit")
                        Text("条（1–1000）").foregroundStyle(.secondary)
                        Spacer()
                        Stepper("调整历史记录条数", value: $model.draftConfiguration.historyLimit, in: 1...1000)
                            .labelsHidden()
                    }
                    .disabled(!model.draftConfiguration.saveHistory)
                } header: {
                    Text("历史提示词")
                } footer: {
                    Text("每次成功优化后，在本机保存原文、结果、时间和模型。关闭后停止新增，已有记录仍保留；可在工具窗口删除单条或清空。降低保留数量并保存后，会删除最早的超额记录。")
                }
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("优化指令（系统提示词）").font(.callout.weight(.medium))
                        TextEditor(text: $model.draftConfiguration.systemPrompt)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 240, idealHeight: 300)
                            .padding(6)
                            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary, lineWidth: 1))
                            .accessibilityLabel("优化指令")
                            .accessibilityIdentifier("prompt.settings.systemPrompt")
                        Button("恢复默认优化指令") { model.restoreDefaultInstruction() }
                            .accessibilityIdentifier("prompt.settings.restoreDefault")
                    }
                } header: {
                    Text("优化方式")
                } footer: {
                    Text("默认指令会保留真实目标和约束、整理口述内容、补全适用的任务结构；不直接执行你的任务，也不编造缺失信息。恢复默认后仍需保存。")
                }
                Section {
                    Text("点击优化时，原始提示词和优化指令将发送给你配置的服务。Aether 不会自动读取剪贴板，也不会上传历史列表；请确认服务地址及其数据使用政策。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
            Divider()
            settingsFooter
            }
        }
    }

    private var settingsFooter: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = model.configurationLoadError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                Button("重新读取设置") { model.reloadConfiguration() }
                    .accessibilityIdentifier("prompt.settings.reload")
            }
            HStack(alignment: .top, spacing: 12) {
                Button("保存设置") { model.saveSettings() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("prompt.settings.save")
                if let message = model.settingsMessage {
                    Label(message, systemImage: model.settingsSaveFailed ? "exclamationmark.triangle" : "checkmark.circle")
                        .font(.callout)
                        .foregroundStyle(model.settingsSaveFailed ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("prompt.settings.status")
                }
                Spacer(minLength: 0)
            }
        }.padding(.horizontal, 24).padding(.vertical, 16)
    }
}
