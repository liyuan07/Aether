import SwiftUI
import SharedSupport
import WhatPortCore

struct PortsSummaryView: View {
    @ObservedObject var model: PortsModel
    var body: some View {
        Button { AppRouter.shared.send(.settings(.ports)) } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("端口", systemImage: "cable.connector")
                        .font(.headline)
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                }
                if model.lastUpdated == nil {
                    Text("正在读取端口…").foregroundStyle(.secondary)
                } else {
                    Text("\(model.manager.activePortCount) / \(model.manager.portCount) 个端口活动中")
                    Text("已报告输入：\(PortPresentation.power(model.manager.ports, direction: .incoming))\n已报告输出：\(PortPresentation.power(model.manager.ports, direction: .outgoing))")
                        .font(.caption).foregroundStyle(.secondary)
                    let names = model.manager.ports.filter(\.isActive).compactMap(\.deviceName)
                    if !names.isEmpty {
                        Text(names.joined(separator: "、")).font(.caption).lineLimit(2).foregroundStyle(.secondary)
                    }
                    if let caveat = capabilityNote(model.manager) {
                        Text(caveat).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 12))
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
        SettingsContent("端口") {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("协商速率表示链路能力；实际传输速度取决于设备与负载。")
                    Text("仅在查看时采集 · 历史仅保留在内存 · 无法读取的项目显示不可用")
                    Text(model.collecting ? "实时采集中" : "采集已暂停").accessibilityIdentifier("ports.sampling-status")
                    if model.lastUpdated != nil && !model.phyAvailable { Text("此 Mac 当前未提供通道状态读数。") }
                    if model.sleeping { Text("系统休眠，采集已暂停。") }
                    if let note = capabilityNote(model.manager) { Text(note) }
                }
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.bottom, 12)
                Divider()
                if model.lastUpdated == nil {
                    ProgressView("正在读取端口…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.manager.ports.isEmpty {
                    ContentUnavailableView("端口信息不可用", systemImage: "cable.connector", description: Text(capabilityNote(model.manager) ?? "系统未提供端口数据。"))
                } else {
                    HStack(spacing: 0) {
                        List(selection: $selection) {
                            ForEach(model.manager.ports) { port in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(PortPresentation.name(port)).font(.headline)
                                    if port.isActive, let name = port.deviceName { Text(name).lineLimit(2) }
                                    Text(PortPresentation.summary(port, phase: model.manager.lifecyclePhases[port.id]))
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text(port.power.map { WattsFormat.string($0.watts) } ?? "功率不可用")
                                        .font(.caption).monospacedDigit()
                                }.padding(.vertical, 5).tag(port.id)
                            }
                        }.listStyle(.sidebar).frame(width: 210)
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
