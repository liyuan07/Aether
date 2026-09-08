import ShortcutCore
import SwiftUI

struct QuickConfigView: View {
    @ObservedObject var model: AppModel
    let openSettings: (SettingsSection) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "keyboard")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("KeyPilot")
                        .font(.headline)
                    Text(permissionSummary)
                        .font(.caption)
                        .foregroundStyle(hasAllPermissions ? Color.secondary : Color.orange)
                }
                Spacer()
                Button {
                    openSettings(.general)
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("完整设置")
            }
            .padding(14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !hasAllPermissions {
                        permissionNotice
                    }

                    sectionTitle("常用开关")
                    VStack(spacing: 0) {
                        DashboardToggleRow(
                            title: "显示实体按钮",
                            detail: "显示桌面上的快捷操作面板",
                            isOn: appBinding(\.showModifierButtons)
                        )
                        Divider().padding(.leading, 42)
                        DashboardToggleRow(
                            title: "屏蔽 ABC 自动切换",
                            detail: "只允许物理中英键切换到 ABC",
                            isOn: appBinding(\.blockAutomaticABC)
                        )
                        Divider().padding(.leading, 42)
                        DashboardToggleRow(
                            title: "登录时启动",
                            detail: "登录 macOS 后自动运行 KeyPilot",
                            isOn: appBinding(\.launchAtLogin)
                        )
                    }
                    .dashboardGroup()

                    sectionTitle("快捷入口")
                    VStack(spacing: 0) {
                        DashboardNavigationRow(
                            title: "应用唤醒设置",
                            detail: "默认应用与同首字母排序",
                            icon: "app.badge",
                            action: { openSettings(.applications) }
                        )
                        Divider().padding(.leading, 42)
                        DashboardNavigationRow(
                            title: "快捷键管理",
                            detail: "新增、删除或修改快捷键",
                            icon: "keyboard",
                            action: { openSettings(.shortcuts) }
                        )
                        Divider().padding(.leading, 42)
                        DashboardNavigationRow(
                            title: "完整设置",
                            detail: "通用设置与配置导入导出",
                            icon: "gearshape",
                            action: { openSettings(.general) }
                        )
                    }
                    .dashboardGroup()
                }
                .padding(12)
            }
        }
        .frame(width: 390, height: 430)
    }

    private var hasAllPermissions: Bool {
        model.permissionGranted && model.inputMonitoringGranted
    }

    private var permissionSummary: String {
        if !model.permissionGranted { return "需要辅助功能权限" }
        if !model.inputMonitoringGranted { return "需要输入监控权限" }
        return "运行正常"
    }

    @ViewBuilder
    private var permissionNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.shield")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("部分功能需要系统权限")
                    .font(.callout.weight(.medium))
                Text(permissionNoticeDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("去开启") {
                if !model.permissionGranted {
                    AccessibilityPermission.openSettings()
                } else {
                    PhysicalModifierMonitor.openPrivacySettings()
                }
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
    }

    private var permissionNoticeDetail: String {
        if !model.permissionGranted { return "辅助功能权限未开启" }
        return "输入监控权限未开启"
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 2)
    }

    private func appBinding(_ keyPath: WritableKeyPath<AppGeneralPreferences, Bool>) -> Binding<Bool> {
        Binding(
            get: { model.appPreferences.app[keyPath: keyPath] },
            set: { value in
                model.updateAppPreferences { $0.app[keyPath: keyPath] = value }
            }
        )
    }
}

private struct DashboardToggleRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

private struct DashboardNavigationRow: View {
    let title: String
    let detail: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

private extension View {
    func dashboardGroup() -> some View {
        self
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.45))
            )
    }
}
