import Foundation
import WhatPortCore

enum PortPresentation {
    static func name(_ port: PortState) -> String {
        port.portType == .magSafe ? "MagSafe" : "端口 \(port.id)"
    }
    static func summary(_ port: PortState, phase: PortLifecyclePhase? = nil) -> String {
        if let phase { return phase == .detecting ? "正在检测…" : "正在协商…" }
        guard port.isActive else { return "空闲" }
        if let link = port.thunderboltLink, port.hasLiveThunderboltLink {
            return "\(link.generation.label) · \(link.totalGbps) Gbps"
        }
        switch port.primaryProtocol {
        case .thunderbolt: return "Thunderbolt · 速率不可用"
        case .displayPort:
            let rate = port.liveTransports.first { $0.kind == .displayPort }?.dataRate
            return rate.flatMap { $0.isEmpty ? nil : "DisplayPort · \($0)" } ?? "DisplayPort"
        case .usbOnly:
            let rate = port.liveTransports.first { $0.kind == .usb }?.dataRate
            if let rate, !rate.isEmpty { return "USB · \(rate)" }
            if let speed = port.usbSpeed { return "USB · \(speed.label)" }
            return "USB · 速率不可用"
        case .charging: return "已连接电源"
        case .idle: return port.ccConnected ? "已连接线缆" : "空闲"
        }
    }
    static func deviceClass(_ value: USBDeviceClass) -> String {
        switch value {
        case .hub: return "集线器"
        case .audio: return "音频"
        case .video: return "视频"
        case .massStorage: return "存储"
        case .smartCard: return "智能卡"
        case .billboard: return "Billboard"
        case .wireless: return "无线"
        case .miscellaneous: return "其他"
        case .vendorSpecific: return "厂商自定义"
        }
    }
    static func power(_ ports: [PortState], direction: PowerDirection) -> String {
        let readings = ports.compactMap(\.power)
        guard !readings.isEmpty else { return "不可用" }
        let matching = readings.filter { $0.direction == direction }
        guard !matching.isEmpty else { return "无已报告读数" }
        return WattsFormat.string(matching.reduce(0) { $0 + $1.watts })
    }
}
