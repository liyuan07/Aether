import SwiftUI
import SharedSupport
import WhatPortCore

struct PortsSummaryView: View {
    @ObservedObject var model: PortsModel
    var body: some View {
        Button { AppRouter.shared.send(.settings(.ports)) } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("端口", systemImage: "cable.connector").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if model.lastUpdated != nil {
                        Text("\(model.manager.activePortCount) / \(model.manager.portCount) 活动")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
                if model.lastUpdated == nil {
                    Text("正在读取端口…").foregroundStyle(.secondary)
                } else {
                    Text("输入 \(PortPresentation.power(model.manager.ports, direction: .incoming)) · 输出 \(PortPresentation.power(model.manager.ports, direction: .outgoing))")
                        .font(.caption).foregroundStyle(.secondary)
                    let names = model.manager.ports.filter(\.isActive).compactMap(\.deviceName)
                    if !names.isEmpty {
                        Text(names.joined(separator: "、")).font(.caption).lineLimit(1).foregroundStyle(.secondary)
                    }
                    if let caveat = capabilityNote(model.manager) {
                        Text(caveat).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Color.primary.opacity(0.1).frame(height: 0.5) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("ports.summary")
    }
}

func capabilityNote(_ manager: PortManager) -> String? {
    switch manager.confirmedPortDataTier {
    case .unknown: return nil
    case .full: return nil
    case .thunderboltOnly: return "此 Mac 仅提供部分端口信息；PD 合约、通道及控制器计数可能不可用。"
    case .none:
        return manager.thunderboltControllerPresentButSilent
            ? "检测到 Thunderbolt 控制器，但系统尚未提供端口列表。"
            : "系统未提供可识别的端口信息。"
    }
}

struct PortsWorkspaceView: View {
    @ObservedObject var model: PortsModel
    @State private var selection: Int?
    var body: some View {
        SettingsContent("端口与设备", subtitle: "查看连接状态、供电与链路信息。") {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Circle().fill(model.collecting ? Color.green : Color.secondary).frame(width: 6, height: 6)
                        Text(model.collecting ? "实时采集中" : "采集已暂停").accessibilityIdentifier("ports.sampling-status")
                        Spacer()
                        Text("\(model.manager.ports.count) 个端口")
                    }
                    DisclosureGroup("数据说明") {
                        Text("协商速率表示链路能力，实际速度取决于设备与负载。仅在查看时采集，历史仅保留在内存，无法读取的项目显示不可用。")
                            .fixedSize(horizontal: false, vertical: true).padding(.vertical, 8)
                    }
                    if model.lastUpdated != nil && !model.phyAvailable { Text("此 Mac 当前未提供通道状态读数。") }
                    if model.sleeping { Text("系统休眠，采集已暂停。") }
                    if let note = capabilityNote(model.manager) { Text(note) }
                }
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .padding(.horizontal, SettingsLayout.pageInset).padding(.vertical, 12)
                Divider()
                if model.lastUpdated == nil {
                    ProgressView("正在读取端口…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.manager.ports.isEmpty {
                    ContentUnavailableView("端口信息不可用", systemImage: "cable.connector", description: Text(capabilityNote(model.manager) ?? "系统未提供端口数据。"))
                } else {
                    HStack(spacing: 0) {
                        List(selection: $selection) {
                            ForEach(model.manager.ports) { port in
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(PortPresentation.name(port)).font(.system(size: 14, weight: .medium))
                                        Spacer(minLength: 4)
                                        Circle().fill(port.isActive ? Color.green : Color.secondary.opacity(0.3)).frame(width: 6, height: 6)
                                    }
                                    Text(port.deviceName ?? PortPresentation.summary(port, phase: model.manager.lifecyclePhases[port.id]))
                                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                                        .help(PortPresentation.summary(port, phase: model.manager.lifecyclePhases[port.id]))
                                    if let power = port.power {
                                        Text(WattsFormat.string(power.watts)).font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                                    }
                                }.padding(.vertical, 8).tag(port.id)
                            }
                        }.listStyle(.inset).scrollContentBackground(.hidden).frame(width: 156)
                        Divider()
                        if let port = model.manager.ports.first(where: { $0.id == selection }) {
                            PortDetailView(port: port, powerHistory: model.history.points[port.id] ?? [], powerMeteringAvailable: model.manager.powerMeteringAvailable, isCharging: model.manager.isCharging, fullyCharged: model.manager.fullyCharged, chargingStatus: model.manager.chargingStatus, reducedDetail: model.manager.portDataTier == .thunderboltOnly || !model.phyAvailable)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            ContentUnavailableView("选择端口", systemImage: "cable.connector")
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
            }
            .onChange(of: model.lastUpdated) { _, _ in
                if selection == nil { selection = model.manager.ports.first?.id }
            }
        }
        .accessibilityIdentifier("ports.details")
    }
}
