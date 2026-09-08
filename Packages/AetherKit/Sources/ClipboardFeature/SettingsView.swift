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

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "doc.on.clipboard.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("剪贴板")
                        .font(.title2.weight(.semibold))
                    Text("本地、快速、独立的剪切板历史")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            GroupBox("常规") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("记录剪切板历史", isOn: $monitoringEnabled)
                }
                .padding(8)
            }

            GroupBox("快捷键") {
                HStack {
                    Toggle("启用全局快捷键", isOn: $shortcutEnabled)
                    Spacer()
                    Text("⇧⌘J")
                        .font(.system(.body, design: .rounded).weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.secondary.opacity(0.12))
                        )
                }
                .padding(8)
            }

            GroupBox("历史") {
                VStack(alignment: .leading, spacing: 12) {
                    Stepper(
                        "最多保留 \(historyLimit) 条",
                        value: $historyLimit,
                        in: 50...20_000,
                        step: 50
                    )
                    Stepper(
                        expirationDays == 0
                            ? "永不过期"
                            : "保留 \(expirationDays) 天",
                        value: $expirationDays,
                        in: 0...365
                    )
                    HStack {
                        Text("历史记录仅保存在本机")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("显示数据文件夹") {
                            NSWorkspace.shared.activateFileViewerSelecting([
                                ClipboardStorage.archiveDirectory
                            ])
                        }
                    }
                }
                .padding(8)
            }

            GroupBox("搜索") {
                HStack(spacing: 12) {
                    Toggle(
                        "启用搜索防抖",
                        isOn: $searchDebounceEnabled
                    )
                    Spacer()
                    Stepper(
                        "停止输入 \(searchDebounceMilliseconds) 毫秒后搜索",
                        value: $searchDebounceMilliseconds,
                        in: ClipboardSearchDebounce.supportedMilliseconds,
                        step: ClipboardSearchDebounce.stepMilliseconds
                    )
                    .disabled(!searchDebounceEnabled)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("粘贴权限") {
                HStack {
                    Image(systemName: accessibilityTrusted
                        ? "checkmark.circle.fill"
                        : "exclamationmark.triangle.fill")
                        .foregroundStyle(accessibilityTrusted ? .green : .orange)
                    Text(accessibilityTrusted
                        ? "辅助功能权限已启用"
                        : "单击条目自动粘贴需要辅助功能权限")
                    Spacer()
                    if accessibilityTrusted {
                        Button("刷新") {
                            refreshStatus()
                        }
                    } else {
                        Button("授权") {
                            AccessibilityController.requestAccess()
                            AccessibilityController.openSystemSettings()
                        }
                    }
                }
                .padding(8)
            }

            HStack {
                Text("Aether 剪贴板 · GPL-3.0-or-later")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("完成") {
                    NSApp.keyWindow?.close()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private var appVersion: String {
        Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "Development"
    }
}

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    func show() { AppRouter.shared.send(.settings(.clipboard)) }
}
