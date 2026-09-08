import SharedSupport
import AppKit
import ShortcutCore
import SwiftUI
import UniformTypeIdentifiers

struct ShortcutSettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            settingsHeader
            Divider()
            List {
                ForEach(model.rules) { rule in
                    DisclosureGroup(isExpanded: expansion(for: rule.id)) {
                        RuleEditorView(
                            rule: Binding(
                                get: { model.rule(withID: rule.id) ?? rule },
                                set: { model.update($0) }
                            ),
                            findings: model.findings(for: rule.id),
                            setRecording: model.setShortcutRecording,
                            remove: { model.removeRule(id: rule.id) }
                        )
                        .id(rule.id)
                    } label: {
                        HStack(spacing: 10) {
                            Circle()
                                .fill(rule.isEnabled ? Color.green : Color.secondary.opacity(0.35))
                                .frame(width: 7, height: 7)
                            Text(rule.name).lineLimit(1)
                            Spacer()
                            if !model.findings(for: rule.id).isEmpty {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                            }
                            Text(rule.source.displayString)
                                .font(.callout.monospaced()).foregroundStyle(.secondary)
                            Image(systemName: "line.3.horizontal")
                                .foregroundStyle(.tertiary).help("拖动调整顺序")
                        }
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                        .onTapGesture { expansion(for: rule.id).wrappedValue.toggle() }
                    }
                }
                .onMove(perform: model.moveRules)
            }
            .listStyle(.inset)
            HStack {
                Button { _ = model.addRule() } label: {
                    Label("添加快捷键", systemImage: "plus")
                }
                Spacer()
                Text("拖动调整顺序").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24).padding(.vertical, 12)
        }
    }

    private func expansion(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { model.selectedRuleID == id },
            set: { expanded in
                model.setShortcutRecording(false)
                model.selectedRuleID = expanded ? id : nil
            }
        )
    }

    private var settingsHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: model.permissionGranted ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .foregroundStyle(model.permissionGranted ? .green : .orange)
                Text(model.permissionGranted ? "辅助功能权限已开启" : "快捷键暂未生效：需要辅助功能权限")
                    .font(.callout)
                if !model.permissionGranted {
                    Button("打开系统设置") { AccessibilityPermission.openSettings() }
                }
                Spacer()
            }
            HStack(spacing: 10) {
                Stepper(
                    value: Binding(
                        get: { model.shortcutGuideHoldDuration },
                        set: model.setShortcutGuideHoldDuration
                    ),
                    in: ShortcutGuideConfiguration.minimumHoldDuration...ShortcutGuideConfiguration.maximumHoldDuration,
                    step: ShortcutGuideConfiguration.holdDurationStep
                ) {
                    Text("长按双 ⌘ 显示提示：\(model.shortcutGuideHoldDuration, specifier: "%.1f") 秒")
                        .font(.callout.monospacedDigit())
                }
                .help("调整双 Command 唤出快捷键表所需的长按时间")
                Spacer()
                if model.isScanningConflicts { ProgressView().controlSize(.small) }
                Button("扫描冲突") { model.rescanConflicts() }
                    .disabled(model.isScanningConflicts)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

}

private struct RuleEditorView: View {
    @Binding var rule: ShortcutRule
    let findings: [ConflictFinding]
    let setRecording: (Bool) -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Button("删除快捷键", role: .destructive, action: remove)
                Spacer()
                Toggle("启用", isOn: $rule.isEnabled)
                    .toggleStyle(.switch)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    LabeledContent("名称") {
                        TextField("快捷键名称", text: $rule.name)
                            .frame(width: 280)
                    }
                    LabeledContent("触发快捷键") {
                        ShortcutRecorderView(shortcut: $rule.source, onRecordingChanged: setRecording)
                            .frame(width: 150, height: 28)
                    }
                    Text("按物理键位保存；同时按住中英键与左右修饰键时会记录物理组合。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(6)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("动作", selection: actionKindBinding) {
                        ForEach(ShortcutAction.Kind.allCases) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .pickerStyle(.menu)

                    Divider()
                    actionConfiguration
                }
                .padding(6)
            }

            if !findings.isEmpty {
                GroupBox("冲突提示") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(findings) { finding in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(finding.confidence == .confirmed ? .red : .orange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(finding.confidence.displayName)
                                        .font(.caption.bold())
                                    Text(finding.message)
                                        .font(.callout)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }
            }

            Text("冲突扫描会检查软件内重复、部分系统快捷键、排他式全局注册，以及当前运行软件公开在菜单中的快捷键；不能枚举第三方软件的全部内部快捷键。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onDisappear { setRecording(false) }
    }

    private var actionKindBinding: Binding<ShortcutAction.Kind> {
        Binding(
            get: { rule.action.kind },
            set: { rule.action = defaultAction(for: $0) }
        )
    }

    @ViewBuilder
    private var actionConfiguration: some View {
        switch rule.action {
        case let .application(target, mode):
            VStack(alignment: .leading, spacing: 12) {
                LabeledContent("应用") {
                    HStack {
                        Text(target.displayName).lineLimit(1)
                        Button("选择…") {
                            if let selected = FileSelection.chooseApplication() {
                                rule.action = .application(target: selected, mode: mode)
                            }
                        }
                    }
                }
                Picker(
                    "打开方式",
                    selection: Binding(
                        get: { mode },
                        set: { rule.action = .application(target: target, mode: $0) }
                    )
                ) {
                    ForEach(ApplicationOpenMode.allCases) { value in
                        Text(value.displayName).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                Text(mode == .newWindow ? "激活应用后发送 Command+N；不支持新窗口的应用会忽略。" : "应用已运行时只激活，未运行时启动。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case let .finderFolder(path):
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("文件夹") {
                    Button("选择…") {
                        if let selectedPath = FileSelection.chooseFolder(startingAt: path) {
                            rule.action = .finderFolder(path: selectedPath)
                        }
                    }
                }
                PathLabel(path: path)
                Text("若 Finder 已有该文件夹窗口则置前，否则交给 Finder 打开。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case let .terminal(fallbackPath, useFrontmostFinder):
            VStack(alignment: .leading, spacing: 12) {
                Toggle(
                    "Finder 在前台时使用其当前路径",
                    isOn: Binding(
                        get: { useFrontmostFinder },
                        set: { rule.action = .terminal(fallbackPath: fallbackPath, useFrontmostFinder: $0) }
                    )
                )
                LabeledContent("默认路径") {
                    Button("选择…") {
                        if let selectedPath = FileSelection.chooseFolder(startingAt: fallbackPath) {
                            rule.action = .terminal(fallbackPath: selectedPath, useFrontmostFinder: useFrontmostFinder)
                        }
                    }
                }
                PathLabel(path: fallbackPath)
                Text("每次执行都会在 Terminal.app 中新建一个位于目标路径的窗口。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .showDesktop:
            VStack(alignment: .leading, spacing: 10) {
                Label("系统显示桌面", systemImage: "desktopcomputer")
                Text("触发 macOS 的“显示桌面”，效果与将鼠标移到已设为“桌面”的触发角相同。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("窗口会随系统动画滑向屏幕边缘；再次触发可恢复窗口。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case let .windowLayout(layout):
            VStack(alignment: .leading, spacing: 10) {
                Picker(
                    "窗口位置",
                    selection: Binding(
                        get: { layout },
                        set: { rule.action = .windowLayout($0) }
                    )
                ) {
                    ForEach(WindowLayout.allCases) { value in Text(value.displayName).tag(value) }
                }.pickerStyle(.menu)
                Text("调整当前前台窗口；需要辅助功能权限，部分不可缩放或全屏窗口不支持。")
                    .font(.caption).foregroundStyle(.secondary)
            }

        case let .remap(target):
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("映射为") {
                    ShortcutRecorderView(
                        shortcut: Binding(
                            get: { target },
                            set: { rule.action = .remap(to: $0) }
                        ),
                        onRecordingChanged: setRecording,
                        capturesPhysicalModifiers: false
                    )
                    .frame(width: 150, height: 28)
                }
                Text("原快捷键会被拦截，并合成发送这里配置的目标快捷键。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func defaultAction(for kind: ShortcutAction.Kind) -> ShortcutAction {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first?.path ?? "~/Desktop"
        switch kind {
        case .application:
            return .application(
                target: ApplicationTarget(
                    displayName: "Google Chrome",
                    bundleIdentifier: "com.google.Chrome",
                    applicationPath: "/Applications/Google Chrome.app"
                ),
                mode: .activateExisting
            )
        case .finderFolder:
            return .finderFolder(path: desktop)
        case .terminal:
            return .terminal(fallbackPath: desktop, useFrontmostFinder: true)
        case .showDesktop:
            return .showDesktop
        case .windowLayout:
            return .windowLayout(.leftHalf)
        case .remap:
            return .remap(to: KeyCombination(keyCode: 3, modifiers: [.command, .shift]))
        }
    }
}

private struct PathLabel: View {
    let path: String

    var body: some View {
        Text(NSString(string: path).abbreviatingWithTildeInPath)
            .font(.system(.callout, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }
}

private enum FileSelection {
    static func chooseApplication() -> ApplicationTarget? {
        let panel = NSOpenPanel()
        panel.title = "选择应用"
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return ApplicationTarget(
            displayName: FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""),
            bundleIdentifier: Bundle(url: url)?.bundleIdentifier,
            applicationPath: url.path
        )
    }

    static func chooseFolder(startingAt path: String) -> String? {
        let panel = NSOpenPanel()
        panel.title = "选择文件夹"
        panel.directoryURL = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath, isDirectory: true)
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK else { return nil }
        return panel.url?.path
    }
}
