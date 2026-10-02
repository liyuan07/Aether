// Adapted from WhatPort PortDetailView (MIT), Darryl Morley.
import SwiftUI
import Charts
import WhatPortCore

struct PortDetailView: View {
    @Environment(\.fontScale) private var fontScale
    let port: PortState
    let powerHistory: [PortPowerPoint]
    let powerMeteringAvailable: Bool
    var isCharging: Bool = false
    var fullyCharged: Bool = false
    var chargingStatus: ChargingStatus? = nil
    var reducedDetail: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                portHeader
                cardContent
                statisticsSection
            }
            .padding(16)
        }
    }

    private var chartTint: Color { .blue }


    private var portHeader: some View {
        HStack(alignment: .center) {
            Text(portName)
                .scaledFont(.title3, weight: .semibold)
            Spacer()
            protocolChip
        }
    }

    private var portName: String {
        switch port.portType {
        case .magSafe: return "MagSafe"
        case .usbC: return "端口 \(port.id)"
        }
    }

    private var protocolChip: some View {
        let (label, color) = protocolChipInfo
        return Text(label)
            .scaledFont(.caption, weight: .semibold)
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }

    private var protocolChipInfo: (String, Color) {
        switch port.primaryProtocol {
        case .thunderbolt: return ("Thunderbolt", .blue)
        case .displayPort:  return ("DisplayPort", .orange)
        case .usbOnly:      return ("USB", .green)
        case .charging:     return ("充电中", .yellow)
        case .idle:         return ("空闲", .gray)
        }
    }


    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .scaledFont(.caption, weight: .semibold)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private func sectionCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) { content() }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }


    @ViewBuilder
    private var cardContent: some View {
        switch port.primaryProtocol {
        case .charging:
            sectionCard { powerSection }
            if !powerHistory.isEmpty {
                sectionCard { powerChart }
            }
            if port.portType != .magSafe {
                connectionsCard
                if !reducedDetail {
                    sectionCard { laneInfoSection }
                }
                if let cap = port.thunderboltCapability {
                    sectionCard { thunderboltSection(capability: cap, link: port.thunderboltLink) }
                }
                if let cable = port.cable {
                    sectionCard { cableSection(cable) }
                }
            }

        case .usbOnly:
            if let device = port.usbDevice {
                deviceCardGroup(device)
            }
            connectionsCard
            if !reducedDetail {
                sectionCard { laneInfoSection }
            }
            if let cap = port.thunderboltCapability {
                sectionCard { thunderboltSection(capability: cap, link: port.thunderboltLink) }
            }
            if let cable = port.cable {
                sectionCard { cableSection(cable) }
            }
            sectionCard { powerSection }
            if !powerHistory.isEmpty {
                sectionCard { powerChart }
            }

        case .thunderbolt:
            if let device = port.usbDevice {
                deviceCardGroup(device)
            } else if port.displayWidth > 0 && port.displayHeight > 0 {
                sectionCard { displayResolutionRow }
            }
            if dpTransport != nil || !port.dpTunnelLinkRate.isEmpty {
                sectionCard { displaySection(dpTransport) }
            }
            connectionsCard
            if let cap = port.thunderboltCapability {
                sectionCard { thunderboltSection(capability: cap, link: port.thunderboltLink) }
            }
            if !reducedDetail {
                sectionCard { laneInfoSection }
            }
            if let cable = port.cable {
                sectionCard { cableSection(cable) }
            }
            sectionCard { powerSection }
            if !powerHistory.isEmpty {
                sectionCard { powerChart }
            }

        case .displayPort:
            if let device = port.usbDevice {
                deviceCardGroup(device)
            } else if port.displayWidth > 0 && port.displayHeight > 0 {
                sectionCard { displayResolutionRow }
            }
            if dpTransport != nil || !port.dpTunnelLinkRate.isEmpty {
                sectionCard { displaySection(dpTransport) }
            }
            connectionsCard
            if !reducedDetail {
                sectionCard { laneInfoSection }
            }
            if let cap = port.thunderboltCapability {
                sectionCard { thunderboltSection(capability: cap, link: port.thunderboltLink) }
            }
            if let cable = port.cable {
                sectionCard { cableSection(cable) }
            }
            sectionCard { powerSection }
            if !powerHistory.isEmpty {
                sectionCard { powerChart }
            }

        case .idle:
            connectionsCard
            if !reducedDetail {
                sectionCard { laneInfoSection }
            }
            if let cap = port.thunderboltCapability {
                sectionCard { thunderboltSection(capability: cap, link: port.thunderboltLink) }
            }
            sectionCard { powerSection }
            if !powerHistory.isEmpty {
                sectionCard { powerChart }
            }
        }
    }

    private func deviceCardGroup(_ device: USBDeviceInfo) -> some View {
        sectionCard {
            deviceSection(device)
            displayResolutionRow
        }
    }


    private func deviceSection(_ device: USBDeviceInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionHeader("设备")

            HStack {
                Text(device.productName)
                    .scaledFont(.body, weight: .medium)
                Spacer()
                if !device.vendorName.isEmpty {
                    Text(device.vendorName)
                        .scaledFont(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 12) {
                if let speed = device.speed {
                    LabeledValue(label: "协商速率", value: speed.label)
                }
                if !device.usbVersion.isEmpty {
                    LabeledValue(label: "版本", value: device.usbVersion)
                }
                if let deviceClass = device.deviceClass {
                    LabeledValue(label: "类型", value: PortPresentation.deviceClass(deviceClass))
                }
                if device.currentDraw > 0 {
                    LabeledValue(label: "设备报告电流", value: "\(device.currentDraw) mA")
                }
            }

            if Self.isUSB2SpeedOnLiveThunderboltLink(speed: device.speed, hasLiveThunderboltLink: port.hasLiveThunderboltLink) {
                Text("这是设备自身的 USB 速率；端口的 Thunderbolt 链路速率见下方。")
                    .scaledFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let serial = device.serialNumber {
                HStack {
                    Text("序列号")
                        .scaledFont(.footnote)
                        .foregroundStyle(.tertiary)
                    Text(serial)
                        .scaledFont(size: 12, design: .monospaced)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if port.additionalDeviceCount > 0 {
                Text(Self.additionalDeviceLabel(count: port.additionalDeviceCount))
                    .scaledFont(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    static func additionalDeviceLabel(count: Int) -> String {
        "另有 \(count) 个设备"
    }

    static func isUSB2SpeedOnLiveThunderboltLink(speed: USBSpeed?, hasLiveThunderboltLink: Bool) -> Bool {
        guard hasLiveThunderboltLink, let speed else { return false }
        switch speed {
        case .lowSpeed, .fullSpeed, .highSpeed: return true
        case .superSpeed, .superSpeedPlus, .superSpeed2x2: return false
        }
    }


    @ViewBuilder
    private var displayResolutionRow: some View {
        if port.displayWidth > 0 && port.displayHeight > 0 {
            LabeledValue(
                label: "原生分辨率",
                value: "\(port.displayWidth) x \(port.displayHeight)"
            )
        }
    }

    private var dpTransport: LiveTransport? {
        port.liveTransports.first { $0.kind == .displayPort }
    }

    @ViewBuilder
    private func displaySection(_ dp: LiveTransport?) -> some View {
        let linkRate = Self.displayLinkRateText(liveDataRate: dp?.dataRate ?? "", dpTunnelLinkRate: port.dpTunnelLinkRate)

        VStack(alignment: .leading, spacing: 4) {
            sectionHeader("显示链路")

            HStack(spacing: 12) {
                if !linkRate.isEmpty {
                    LabeledValue(label: "链路速率", value: linkRate)
                }
                if let dp, dp.maxLaneCount > 0 {
                    LabeledValue(label: "通道", value: "\(dp.laneCount) / \(dp.maxLaneCount)")
                }
                LabeledValue(
                    label: "连接方式",
                    value: (dp?.tunneled ?? true) ? "Thunderbolt 隧道" : "原生 DP 替代模式"
                )
            }

            if let dp, dp.sinkCount > 1 || !dp.dfpType.isEmpty || !dp.branchDevice.isEmpty {
                HStack(spacing: 12) {
                    if dp.sinkCount > 1 {
                        LabeledValue(label: "显示器数量", value: "\(dp.sinkCount)")
                    }
                    if !dp.dfpType.isEmpty {
                        LabeledValue(label: "转换输出", value: dp.dfpType)
                    }
                    if !dp.branchDevice.isEmpty {
                        LabeledValue(label: "中间设备", value: dp.branchDevice)
                    }
                }
            }
        }
    }

    static func displayLinkRateText(liveDataRate: String, dpTunnelLinkRate: String) -> String {
        if !liveDataRate.isEmpty { return liveDataRate }
        if !dpTunnelLinkRate.isEmpty { return LaneBar.formatDPLinkRate(dpTunnelLinkRate) }
        return ""
    }


    @ViewBuilder
    private var connectionsCard: some View {
        if let t = port.transports, t.hasData {
            sectionCard { connectionsSection(t) }
        }
    }


    private func connectionsSection(_ t: PortTransports) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("已建立连接")

            if !t.provisioned.isEmpty {
                transportChips(t.provisioned, color: .green)
            }

            if !t.tunnelProvisioned.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("通过 Thunderbolt 隧道")
                        .scaledFont(.footnote)
                        .foregroundStyle(.tertiary)
                    transportChips(t.tunnelProvisioned, color: .blue)
                }
            }

            if !t.unauthorized.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "lock.fill")
                        .scaledFont(size: 11, weight: .medium)
                        .foregroundStyle(.orange)
                    Text("\(t.unauthorized.map(Self.transportLabel).joined(separator: "、")) 被 macOS 限制，请检查系统设置中的隐私与安全性及配件连接许可。")
                        .scaledFont(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private func transportChips(_ names: [String], color: Color) -> some View {
        HStack(spacing: 6) {
            ForEach(names, id: \.self) { name in
                Text(Self.transportLabel(name))
                    .scaledFont(.caption, weight: .medium)
                    .foregroundStyle(color)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(color.opacity(0.12), in: Capsule())
            }
        }
    }

    static func transportLabel(_ raw: String) -> String {
        switch raw.uppercased() {
        case "CC": return "供电"
        case "USB2": return "USB 2.0"
        case "USB3": return "USB 3"
        case "DP", "DISPLAYPORT": return "DisplayPort"
        case "CIO", "TBT", "THUNDERBOLT": return "Thunderbolt"
        case "PCIE": return "PCIe"
        default: return raw
        }
    }


    private var laneInfoSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionHeader("通道状态")
            LaneBar(
                label: "通道 0",
                state: port.lane0,
                tbLink: port.thunderboltLink,
                liveTransports: port.liveTransports,
                dpLinkRate: port.dpLinkRate
            )
            LaneBar(
                label: "通道 1",
                state: port.lane1,
                tbLink: port.thunderboltLink,
                liveTransports: port.liveTransports,
                dpLinkRate: port.dpLinkRate
            )
            USB2Bar(active: port.usb2Active)

        }
    }

    private var statisticsSection: some View {
        sectionCard {
            if let stats = port.portStats {
                statsLine(stats)
                    .padding(.top, 2)
            }

            if let health = port.health {
                healthRow(health)
                    .padding(.top, 2)
                if health.liquidDetected {
                    Text(health.mitigationsActive
                        ? "系统检测到液体并限制了此端口，请断开连接并晾干。"
                        : "系统报告此端口检测到液体，请断开连接并晾干。")
                        .scaledFont(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if let pd = port.pdReliability {
                LabeledValue(label: "PD 硬复位", value: String(pd.effectiveHardResetCount))
                LabeledValue(label: "短路检测", value: String(pd.shortDetectCount))
                LabeledValue(label: "数据角色切换失败", value: String(pd.dataRoleSwapFailCount))
                LabeledValue(label: "供电角色切换失败", value: String(pd.powerRoleSwapFailCount))
                LabeledValue(label: "I²C 错误", value: String(pd.i2cErrorCount))
            }
            if port.portStats == nil && port.health == nil && port.pdReliability == nil {
                Text("端口统计不可用").foregroundStyle(.secondary)
            }
        }
    }

    private func statsLine(_ stats: PortStatistics) -> some View {
        let errorCount = stats.overcurrentCount + stats.linkErrorCount
            + stats.enumerationFailureCount + stats.addressFailureCount

        return VStack(alignment: .leading, spacing: 4) {
            Text("累计：")
                .scaledFont(.footnote)
                .foregroundStyle(.tertiary)
            Text("\(stats.connectCount) 次连接")
                .scaledFont(.footnote)
                .foregroundStyle(.secondary)
            if stats.remoteWakeCount > 0 {
                Text("\(stats.remoteWakeCount) 次设备唤醒")
                    .scaledFont(.footnote)
                    .foregroundStyle(.secondary)
            }
            Text(errorSummary(stats, total: errorCount))
                .scaledFont(.footnote)
                .foregroundColor(errorCount > 0 ? .orange : .gray)
        }
    }

    private func errorSummary(_ stats: PortStatistics, total: Int) -> String {
        if total == 0 { return "未报告错误" }
        var parts: [String] = []
        if stats.linkErrorCount > 0 {
            parts.append("链路 \(stats.linkErrorCount) 次")
        }
        if stats.overcurrentCount > 0 {
            parts.append("过流 \(stats.overcurrentCount) 次")
        }
        if stats.enumerationFailureCount > 0 {
            parts.append("枚举 \(stats.enumerationFailureCount) 次")
        }
        if stats.addressFailureCount > 0 {
            parts.append("地址分配 \(stats.addressFailureCount) 次")
        }
        return parts.joined(separator: ", ")
    }

    private func healthRow(_ health: PortHealth) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledValue(label: "过流计数", value: String(health.overcurrentCount))
            if !health.ldcmStatus.isEmpty {
                LabeledValue(label: "控制器状态", value: health.ldcmStatus == "No Error" ? "未报告错误" : health.ldcmStatus)
            }
            Text("系统累计计数不代表硬件故障诊断。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }


    private var showsChargingStatus: Bool {
        port.primaryProtocol == .charging || port.power?.direction == .incoming
    }

    private var powerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionHeader("供电")

            if let status = chargingStatus, showsChargingStatus {
                chargingStatusRow(status)
            }

            if let charger = port.charger {
                chargerRow(charger)
            }

            if let power = port.power {
                HStack {
                    Text(WattsFormat.string(power.watts))
                        .scaledFont(.title2, design: .rounded, weight: .semibold)
                    Text("(\(power.current > 0 ? formatAmps(power.current) : "电流不可用") · \(power.voltage > 0 ? formatVolts(power.voltage) : "电压不可用"))")
                        .scaledFont(.subheadline)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    if power.configuredVoltage > 0 || power.configuredCurrent > 0 {
                        LabeledValue(
                            label: "PD 合约",
                            value: "\(power.configuredVoltage > 0 ? formatVolts(power.configuredVoltage) : "电压不可用") / \(power.configuredCurrent > 0 ? formatAmps(power.configuredCurrent) : "电流不可用")",
                            annotation: power.contractIsEstimated ? "估计值" : nil,
                            annotationHelp: "此 Mac 未报告端口独立合约；该估计基于归属于此端口的实时读数。"
                        )
                    }
                    if power.vconnCurrent > 0 {
                        LabeledValue(
                            label: "VConn",
                            value: "\(power.vconnCurrent) mA"
                        )
                    }
                }
                if power.vconnCurrent > 0 {
                    Text("有源线缆")
                        .scaledFont(.footnote, weight: .medium)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                }
            } else if chargingStatus != nil, showsChargingStatus {
                EmptyView()
            } else if !powerMeteringAvailable {
                Text("此 Mac 未提供端口功率读数")
                    .scaledFont(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("当前端口功率不可用")
                    .scaledFont(.subheadline)
                    .foregroundStyle(.secondary)
            }

        }
    }

    private func chargingStatusRow(_ status: ChargingStatus) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("状态")
                .scaledFont(.footnote)
                .foregroundStyle(.secondary)
            Text(chargingStatusText(status))
                .scaledFont(.subheadline, weight: .medium)
                .foregroundStyle(chargingStatusColor(status))
        }
    }

    private func chargingStatusText(_ status: ChargingStatus) -> String {
        switch status {
        case .charging:        return "充电中"
        case .fullyCharged:    return "已充满"
        case .onHoldForHealth: return "为保护电池健康暂停充电"
        case .notCharging:     return "已连接电源，未充电"
        }
    }

    private func chargingStatusColor(_ status: ChargingStatus) -> Color {
        switch status {
        case .charging, .fullyCharged: return .green
        case .onHoldForHealth:         return .yellow
        case .notCharging:             return .gray
        }
    }

    private func chargerRow(_ charger: ChargerInfo) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(charger.name)
                    .scaledFont(.body, weight: .medium)
                Spacer()
                if !charger.manufacturer.isEmpty {
                    Text(charger.manufacturer)
                        .scaledFont(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            if let menu = chargerMenuSummary(charger) {
                Text(menu)
                    .scaledFont(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func chargerMenuSummary(_ charger: ChargerInfo) -> String? {
        let menuWatts = Int((charger.pdos.map(\.watts).max() ?? 0).rounded())
        let watts = charger.maxWatts > 0 ? charger.maxWatts : menuWatts
        let volts = charger.pdos
            .map { $0.voltageMV }
            .sorted()
            .reduce(into: [Int]()) { unique, v in if !unique.contains(v) { unique.append(v) } }
            .map { formatVolts($0) }

        if volts.isEmpty {
            return watts > 0 ? "最高支持 \(watts) W" : nil
        }
        let prefix = watts > 0 ? "最高支持 \(watts) W" : "支持"
        return "\(prefix) (\(volts.joined(separator: " \u{00B7} ")))"
    }

    private func formatVolts(_ millivolts: Int) -> String {
        "\(WattsFormat.oneDecimalTrimmed(Double(millivolts) / 1000.0)) V"
    }

    private func formatAmps(_ milliamps: Int) -> String {
        if milliamps < 1000 {
            return "\(milliamps) mA"
        }
        return "\(WattsFormat.oneDecimalTrimmed(Double(milliamps) / 1000.0)) A"
    }


    private var powerChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("功率 · 最近 60 秒")
            Chart(powerHistory) { sample in
                LineMark(x: .value("时间", sample.timestamp), y: .value("功率", sample.watts), series: .value("时段", sample.segment))
                    .foregroundStyle(chartTint)
                    .interpolationMethod(.linear)
                PointMark(x: .value("时间", sample.timestamp), y: .value("功率", sample.watts))
                    .foregroundStyle(chartTint).symbolSize(8)
            }
            .chartXScale(domain: Date.now.addingTimeInterval(-60)...Date.now)
            .chartYScale(domain: 0...max(1, (powerHistory.map(\.watts).max() ?? 0) * 1.1))
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) { _ in AxisValueLabel(format: .dateTime.minute().second()) } }
            .frame(height: 110)
            Text("仅记录查看期间的读数；空缺表示暂停或数据不可用。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }


    private func thunderboltSection(
        capability: ThunderboltCapability,
        link: ThunderboltLinkState?
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionHeader("Thunderbolt")

            if let link, port.hasLiveThunderboltLink, let name = tbDeviceLabel(link) {
                LabeledValue(label: "已连接设备", value: name)
            }

            if let link, port.hasLiveThunderboltLink {
                let lanes = formatLanes(tx: link.txLanes, rx: link.rxLanes)
                LabeledValue(
                    label: "当前链路",
                    value: "\(link.generation.label), \(lanes), \(link.totalGbps) Gbps"
                )
            } else {
                LabeledValue(label: "当前链路", value: "无活动链路")
            }

            let maxLanes = capability.maxLanes > 1 ? "双通道" : "单通道"
            LabeledValue(
                label: "端口能力",
                value: "最高 \(capability.maxGeneration.label)，\(maxLanes)（每通道 \(capability.maxGeneration.perLaneGbps) Gbps）"
            )
        }
    }

    private func tbDeviceLabel(_ link: ThunderboltLinkState) -> String? {
        let vendor = link.deviceVendor ?? ""
        let model = link.deviceName ?? ""
        let combined = "\(vendor) \(model)".trimmingCharacters(in: .whitespaces)
        return combined.isEmpty ? nil : combined
    }

    private func formatLanes(tx: Int, rx: Int) -> String {
        if tx == rx {
            return tx > 1 ? "双通道" : "单通道"
        }
        return "\(tx)TX/\(rx)RX"
    }


    private func cableSection(_ cable: CableInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionHeader("线缆")
            HStack(spacing: 12) {
                LabeledValue(label: "类型", value: cable.productType == "Passive Cable" ? "无源线缆" : (cable.productType == "Active Cable" ? "有源线缆" : cable.productType))
                if cable.pdRevision > 0 {
                    LabeledValue(label: "PD 版本", value: "\(cable.pdRevision).0")
                }
            }
        }
    }

}


struct LaneBar: View {
    @Environment(\.fontScale) private var fontScale
    let label: String
    let state: LaneState
    let tbLink: ThunderboltLinkState?
    var liveTransports: [LiveTransport] = []
    var dpLinkRate: String = ""

    private var liveTransport: LiveTransport? {
        liveTransports.first { $0.kind == state.transport }
    }

    private var isLanePowered: Bool {
        state.powerLevel == .on
    }

    private var isRestricted: Bool {
        liveTransport?.restricted ?? false
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(powerIndicatorColor)
                .frame(width: 6, height: 6)

            Text(label)
                .scaledFont(size: 12, design: .monospaced)
                .foregroundStyle(.secondary)
                .frame(width: 54 * fontScale, alignment: .trailing)

            RoundedRectangle(cornerRadius: 5)
                .fill(barFill)
                .frame(height: 22 * fontScale)
                .overlay {
                    HStack(spacing: 4) {
                        if isRestricted {
                            Image(systemName: "lock.fill")
                                .scaledFont(size: 10, weight: .medium)
                                .foregroundStyle(barTextColor)
                        }
                        Text(barLabel)
                            .scaledFont(size: 12, weight: .medium)
                            .foregroundStyle(barTextColor)
                        if let lt = liveTransport, lt.tunneled {
                            Text("隧道")
                                .scaledFont(size: 12, weight: .medium)
                                .foregroundStyle(barTextColor.opacity(0.5))
                        }
                    }
                }
                .help(isRestricted
                    ? "数据连接被 macOS 限制。请检查系统设置中的隐私与安全性及配件连接许可。"
                    : "")
        }
    }

    private var powerIndicatorColor: Color {
        guard state.transport != .idle else { return .clear }
        return isLanePowered ? .green : .gray.opacity(0.3)
    }

    private var barFill: Color {
        if isRestricted { return .orange.opacity(isLanePowered ? 0.12 : 0.06) }
        let opacity = isLanePowered ? 0.12 : 0.06
        switch state.transport {
        case .thunderbolt: return .blue.opacity(opacity)
        case .displayPort: return .orange.opacity(opacity)
        case .usb: return .green.opacity(opacity)
        case .idle: return Color.primary.opacity(0.04)
        }
    }

    private var barTextColor: Color {
        if isRestricted { return .orange }
        switch state.transport {
        case .thunderbolt: return .blue
        case .displayPort: return .orange
        case .usb: return .green
        case .idle: return .clear
        }
    }

    private var barLabel: String {
        switch state.transport {
        case .thunderbolt:
            if let lt = liveTransport, !lt.dataRate.isEmpty {
                return "CIO \u{00B7} \(lt.dataRate)"
            }
            if let tb = tbLink {
                return "CIO \u{00B7} \(tb.perLaneGbps) Gbps"
            }
            return "CIO"
        case .displayPort:
            if let lt = liveTransport, !lt.dataRate.isEmpty {
                return "DP \u{00B7} \(lt.dataRate)"
            }
            let rate = Self.formatDPLinkRate(dpLinkRate)
            if !rate.isEmpty {
                return "DP \u{00B7} \(rate)"
            }
            return "DisplayPort"
        case .usb:
            if isRestricted {
                return "USB3 · 已受限"
            }
            if let lt = liveTransport, !lt.dataRate.isEmpty {
                if !lt.generation.isEmpty {
                    return "USB3 \u{00B7} \(lt.dataRate) \u{00B7} \(lt.generation)"
                }
                return "USB3 \u{00B7} \(lt.dataRate)"
            }
            return "USB3"
        case .idle:
            return ""
        }
    }

    static func formatDPLinkRate(_ raw: String) -> String {
        guard !raw.isEmpty else { return "" }
        guard let slashIdx = raw.firstIndex(of: "/") else { return raw }
        let prefix = String(raw[raw.startIndex..<slashIdx])
            .replacingOccurrences(of: "Gbps", with: "")
        if let value = Double(prefix) {
            if value == value.rounded() {
                return "\(Int(value)) Gbps"
            }
            return String(format: "%.1f Gbps", locale: .current, value)
        }
        return raw
    }
}

struct USB2Bar: View {
    @Environment(\.fontScale) private var fontScale
    let active: Bool

    var body: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: 6, height: 6)
            Text("USB2")
                .scaledFont(size: 12, design: .monospaced)
                .foregroundStyle(.secondary)
                .frame(width: 54 * fontScale, alignment: .trailing)

            RoundedRectangle(cornerRadius: 5)
                .fill(active ? Color.green.opacity(0.12) : Color.primary.opacity(0.04))
                .frame(height: 22 * fontScale)
                .overlay {
                    if active {
                        Text("480 Mbps")
                            .scaledFont(size: 12, weight: .medium)
                            .foregroundStyle(.green)
                    }
                }
        }
    }
}


struct LabeledValue: View {
    let label: String
    let value: String
    var annotation: String? = nil
    var annotationHelp: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(label)
                    .scaledFont(.footnote)
                    .foregroundStyle(.secondary)
                if let annotation {
                    Text(annotation)
                        .scaledFont(.footnote)
                        .foregroundStyle(.tertiary)
                        .help(annotationHelp)
                }
            }
            Text(value)
                .scaledFont(.subheadline, weight: .medium)
                .foregroundStyle(.primary)
        }
    }
}
