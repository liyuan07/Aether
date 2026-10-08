import Foundation

public enum ControlCenterDestination: String, CaseIterable, Identifiable {
    case overview, clipboard, shortcuts, memo, prompt
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .overview: "首页"
        case .clipboard: "剪贴板"
        case .shortcuts: "快捷操作"
        case .memo: "备忘录"
        case .prompt: "提示词优化"
        }
    }
    public var symbol: String {
        switch self {
        case .overview: "house"
        case .clipboard: "doc.on.clipboard"
        case .shortcuts: "command"
        case .memo: "checklist"
        case .prompt: "sparkles"
        }
    }
    /// Read old tab orders without dropping user order or retaining duplicates/unknown values.
    public static func entryOrder(saved: [String]) -> [Self] {
        var result: [Self] = []
        for raw in saved {
            if let entry = Self(rawValue: raw), entry != .overview, !result.contains(entry) {
                result.append(entry)
            }
        }
        return result + allCases.filter { $0 != .overview && !result.contains($0) }
    }
    public static func opening(explicit: Self?) -> Self { explicit ?? .overview }

    /// Move *before* a destination in either direction, including forward moves.
    public static func moving(_ source: Self, before target: Self, in order: [Self]) -> [Self] {
        guard source != target, order.contains(source), order.contains(target) else { return order }
        var result = order.filter { $0 != source }
        result.insert(source, at: result.firstIndex(of: target)!)
        return result
    }
}

public enum SettingsWindowGeometry {
    public static func fitting(_ frame: CGRect, in visible: CGRect) -> CGRect {
        let size = CGSize(width: min(frame.width, visible.width), height: min(frame.height, visible.height))
        return CGRect(x: min(max(frame.minX, visible.minX), visible.maxX - size.width),
                      y: min(max(frame.minY, visible.minY), visible.maxY - size.height),
                      width: size.width, height: size.height)
    }
}
