import SharedSupport
import SwiftUI

struct PromptSettingsView: View {
    @ObservedObject var model: PromptModel

    var body: some View {
        SettingsContent("提示词优化") {
            VStack(spacing: 0) {
            SettingsForm {
                SettingsGroup {
                    SettingsRow("Base URL") {
                    TextField("Base URL", text: $model.draftConfiguration.baseURL, prompt: Text("https://api.example.com/v1"))
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("prompt.settings.baseURL")
                        .labelsHidden().frame(maxWidth: 380)
                    }
                    SettingsRow("模型名称") {
                    TextField("模型名称", text: $model.draftConfiguration.model, prompt: Text("服务商提供的模型 ID"))
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("prompt.settings.model")
                        .labelsHidden().frame(maxWidth: 380)
                    }
                    SettingsRow("API Key") {
                    SecureField("API Key", text: $model.draftAPIKey, prompt: Text("本地服务可留空"))
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("prompt.settings.apiKey")
                        .labelsHidden().frame(maxWidth: 380)
                    }
                } header: {
                    Text("模型服务")
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("修改后需点击“保存设置”。API Key 仅保存在本机私有文件。")
                        DisclosureGroup("了解接口配置") {
                            Text("使用兼容 OpenAI Chat Completions 的接口。Base URL 可填写服务根地址、/v1 地址或完整 /chat/completions 地址；本地无鉴权服务可不填 Key。")
                                .padding(.top, 6)
                        }
                    }
                }
                SettingsGroup {
                    Toggle("保存历史提示词", isOn: $model.draftConfiguration.saveHistory)
                        .accessibilityIdentifier("prompt.settings.saveHistory")
                    HStack {
                        Text("最多保留")
                        TextField("历史记录条数", value: $model.draftConfiguration.historyLimit, format: .number.grouping(.never))
                            .labelsHidden()
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
                    VStack(alignment: .leading, spacing: 8) {
                        Text("降低保留数量并保存后，会删除最早的超额记录；关闭保存不会删除已有记录。")
                        DisclosureGroup("了解历史记录") {
                            Text("成功优化后保存原文、结果、时间和模型，可在菜单栏历史页回看、删除或清空。")
                                .padding(.top, 6)
                        }
                    }
                }
                SettingsGroup {
                    DisclosureGroup("编辑优化指令（系统提示词）") {
                        VStack(alignment: .leading, spacing: 10) {
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
                        }.padding(.top, 10)
                    }
                } header: {
                    Text("优化方式")
                } footer: {
                    Text("默认指令保留目标和约束，整理口述内容。编辑或恢复默认后仍需保存。")
                }
                Button { AppRouter.shared.send(.prompt) } label: {
                    Label("打开提示词优化", systemImage: "sparkles")
                }.accessibilityIdentifier("prompt.settings.openWorkspace")
                DisclosureGroup("了解数据发送范围") {
                    Text("点击优化时，原始提示词和优化指令将发送给你配置的服务。Aether 不会自动读取剪贴板，也不会上传历史列表；请确认服务地址及其数据使用政策。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
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
        }.padding(.horizontal, 20).padding(.vertical, 12)
    }
}
