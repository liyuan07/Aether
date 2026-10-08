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
        SettingsContent("剪贴板", subtitle: "决定记录什么、保留多久，以及如何快速取用。") {
            SettingsForm {
                SettingsGroup("记录") {
                    SettingsToggleRow("记录剪贴板历史", description: "自动保存复制的文字、图片与文件。", isOn: $monitoringEnabled)
                    SettingsStepperRow("记录上限", display: "\(historyLimit) 条", value: $historyLimit, in: 50...20_000, step: 50)
                    SettingsStepperRow("保留时间", display: expirationDays == 0 ? "永久保留" : "\(expirationDays) 天", value: $expirationDays, in: 0...365)
                }


                SettingsGroup {
                    SettingsToggleRow("输入停顿后搜索", description: "关闭后，每次输入都立即更新结果。", isOn: $searchDebounceEnabled)
                    SettingsStepperRow("等待时间", display: "\(searchDebounceMilliseconds) 毫秒",
                                       value: $searchDebounceMilliseconds,
                                       in: ClipboardSearchDebounce.supportedMilliseconds,
                                       step: ClipboardSearchDebounce.stepMilliseconds)
                    .disabled(!searchDebounceEnabled)
                } header: { Text("搜索响应") }

                SettingsGroup("快捷访问") {
                    SettingsRow("打开剪贴板") {
                        Text("⇧⌘J").monospaced().foregroundStyle(.secondary)
                        Toggle("启用剪贴板快捷键", isOn: $shortcutEnabled).labelsHidden().toggleStyle(.switch)
                    }
                    if let error = module.hotKeyError {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                    SettingsRow("自动粘贴", description: accessibilityTrusted ? "可将选中的内容粘贴到前台应用。" : "粘贴到其他应用需要辅助功能权限。") {
                        if accessibilityTrusted {
                            Label("已授权", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                        } else {
                            Button("前往授权") { AppRouter.shared.send(.settings(.permissions)) }
                        }
                    }
                }
                BackgroundSettingsView()

            }

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
