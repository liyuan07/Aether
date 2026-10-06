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
import SwiftUI

struct ClipboardSettingsView: View {
    @AppStorage(PreferenceKeys.shortcutEnabled, store: AppEnvironment.clipboardDefaults)
    private var shortcutEnabled = true
    @AppStorage(PreferenceKeys.monitoringEnabled, store: AppEnvironment.clipboardDefaults)
    private var monitoringEnabled = true
    @AppStorage(PreferenceKeys.historyLimit, store: AppEnvironment.clipboardDefaults)
    private var historyLimit = 5_000
    @AppStorage(PreferenceKeys.expirationDays, store: AppEnvironment.clipboardDefaults)
    private var expirationDays = 30
    @AppStorage(PreferenceKeys.searchDebounceEnabled, store: AppEnvironment.clipboardDefaults)
    private var searchDebounceEnabled = true
    @AppStorage(PreferenceKeys.searchDebounceMilliseconds, store: AppEnvironment.clipboardDefaults)
    private var searchDebounceMilliseconds =
        ClipboardSearchDebounce.defaultMilliseconds
    @State private var accessibilityTrusted = false

    @ObservedObject private var module = ClipboardModule.shared

    var body: some View {
        SettingsContent("剪贴板") {
            Form {
                Section("记录") {
                    Toggle("记录剪贴板历史", isOn: $monitoringEnabled)
                    Stepper(value: $historyLimit, in: 50...20_000, step: 50) {
                        LabeledContent("记录上限", value: "\(historyLimit) 条")
                    }
                    Stepper(value: $expirationDays, in: 0...365) {
                        LabeledContent("保留时间", value: expirationDays == 0 ? "永久保留" : "\(expirationDays) 天")
                    }
                    LabeledContent("存储位置") {
                        Button("显示数据文件夹") {
                            NSWorkspace.shared.activateFileViewerSelecting([ClipboardStorage.archiveDirectory])
                        }
                    }
                }

                BackgroundSettingsView()

                Section("快捷键") {
                    Toggle(isOn: $shortcutEnabled) {
                        LabeledContent("打开剪贴板", value: "⇧⌘J")
                    }
                    if let error = module.hotKeyError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    Toggle("输入停顿后搜索", isOn: $searchDebounceEnabled)
                    Stepper(
                        value: $searchDebounceMilliseconds,
                        in: ClipboardSearchDebounce.supportedMilliseconds,
                        step: ClipboardSearchDebounce.stepMilliseconds
                    ) {
                        LabeledContent("等待时间", value: "\(searchDebounceMilliseconds) 毫秒")
                    }
                    .disabled(!searchDebounceEnabled)
                } header: { Text("搜索") }
                footer: { Text("关闭后，每次输入都会立即更新搜索结果。") }

                Section("自动粘贴") {
                    LabeledContent("辅助功能", value: accessibilityTrusted ? "已授权" : "未授权")
                    if !accessibilityTrusted {
                        HStack {
                            Text("粘贴到其他应用需要辅助功能权限。")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("权限设置") { AppRouter.shared.send(.settings(.permissions)) }
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .onAppear {
            searchDebounceMilliseconds = ClipboardSearchDebounce.clamped(
                searchDebounceMilliseconds
            )
            refreshStatus()
        }
        .onChange(of: shortcutEnabled) { _, _ in
            ClipboardModule.shared.refreshHotKey()
        }
        .onChange(of: monitoringEnabled) { _, _ in
            notifyPreferenceChange()
        }
        .onChange(of: historyLimit) { _, _ in
            notifyPreferenceChange()
        }
        .onChange(of: expirationDays) { _, _ in
            notifyPreferenceChange()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .clipboardAccessibilityDidChange
            )
        ) { _ in
            refreshStatus()
        }
    }

    private func refreshStatus() {
        accessibilityTrusted = AccessibilityController.isTrusted
    }

    private func notifyPreferenceChange() {
        NotificationCenter.default.post(
            name: .clipboardPreferencesDidChange,
            object: nil
        )
    }


}

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    func show() { AppRouter.shared.send(.settings(.clipboard)) }
}
