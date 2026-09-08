import Foundation
import CoreGraphics

public struct ShortcutModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let control = ShortcutModifiers(rawValue: 1 << 0)
    public static let option = ShortcutModifiers(rawValue: 1 << 1)
    public static let shift = ShortcutModifiers(rawValue: 1 << 2)
    public static let command = ShortcutModifiers(rawValue: 1 << 3)

    public static let supportedMask: ShortcutModifiers = [.control, .option, .shift, .command]

    public var displayString: String {
        var result = ""
        if contains(.control) { result += "⌃" }
        if contains(.option) { result += "⌥" }
        if contains(.shift) { result += "⇧" }
        if contains(.command) { result += "⌘" }
        return result
    }
}

public struct PhysicalModifierKeys: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let leftControl = PhysicalModifierKeys(rawValue: 1 << 0)
    public static let rightControl = PhysicalModifierKeys(rawValue: 1 << 1)
    public static let leftOption = PhysicalModifierKeys(rawValue: 1 << 2)
    public static let rightOption = PhysicalModifierKeys(rawValue: 1 << 3)
    public static let leftShift = PhysicalModifierKeys(rawValue: 1 << 4)
    public static let rightShift = PhysicalModifierKeys(rawValue: 1 << 5)
    public static let leftCommand = PhysicalModifierKeys(rawValue: 1 << 6)
    public static let rightCommand = PhysicalModifierKeys(rawValue: 1 << 7)
    public static let capsLock = PhysicalModifierKeys(rawValue: 1 << 8)

    public var logicalModifiers: ShortcutModifiers {
        var result: ShortcutModifiers = []
        if !intersection([.leftControl, .rightControl]).isEmpty { result.insert(.control) }
        if !intersection([.leftOption, .rightOption]).isEmpty { result.insert(.option) }
        if !intersection([.leftShift, .rightShift]).isEmpty { result.insert(.shift) }
        if !intersection([.leftCommand, .rightCommand]).isEmpty { result.insert(.command) }
        return result
    }

    public var displayComponents: [String] {
        var result: [String] = []
        if contains(.capsLock) { result.append("中英") }
        if contains(.leftControl) { result.append("左⌃") }
        if contains(.rightControl) { result.append("右⌃") }
        if contains(.leftOption) { result.append("左⌥") }
        if contains(.rightOption) { result.append("右⌥") }
        if contains(.leftShift) { result.append("左⇧") }
        if contains(.rightShift) { result.append("右⇧") }
        if contains(.leftCommand) { result.append("左⌘") }
        if contains(.rightCommand) { result.append("右⌘") }
        return result
    }
}

public struct KeyCombination: Codable, Hashable, Sendable {
    public var keyCode: UInt16
    public var modifiers: ShortcutModifiers
    public var physicalModifiers: PhysicalModifierKeys

    public init(
        keyCode: UInt16,
        modifiers: ShortcutModifiers,
        physicalModifiers: PhysicalModifierKeys = []
    ) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(.supportedMask)
        self.physicalModifiers = physicalModifiers
    }

    public var displayString: String {
        guard !physicalModifiers.isEmpty else {
            return modifiers.displayString + KeyCodeDisplay.name(for: keyCode)
        }
        var representedModifiers = physicalModifiers.logicalModifiers
        if physicalModifiers.contains(.capsLock) {
            representedModifiers.insert(.command)
        }
        let remainingModifiers = modifiers.subtracting(representedModifiers)
        var components = physicalModifiers.displayComponents
        if !remainingModifiers.isEmpty { components.append(remainingModifiers.displayString) }
        components.append(KeyCodeDisplay.name(for: keyCode))
        return components.joined(separator: "+")
    }

    public var isValidTrigger: Bool {
        !modifiers.isEmpty || !physicalModifiers.isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case keyCode
        case modifiers
        case physicalModifiers
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try container.decode(UInt16.self, forKey: .keyCode)
        modifiers = try container.decode(ShortcutModifiers.self, forKey: .modifiers)
            .intersection(.supportedMask)
        physicalModifiers = try container.decodeIfPresent(
            PhysicalModifierKeys.self,
            forKey: .physicalModifiers
        ) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keyCode, forKey: .keyCode)
        try container.encode(modifiers, forKey: .modifiers)
        if !physicalModifiers.isEmpty {
            try container.encode(physicalModifiers, forKey: .physicalModifiers)
        }
    }
}

public enum ApplicationOpenMode: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case activateExisting
    case newWindow

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .activateExisting: "激活现有"
        case .newWindow: "新建窗口"
        }
    }
}

public struct ApplicationTarget: Codable, Hashable, Sendable {
    public var displayName: String
    public var bundleIdentifier: String?
    public var applicationPath: String

    public init(displayName: String, bundleIdentifier: String?, applicationPath: String) {
        self.displayName = displayName
        self.bundleIdentifier = bundleIdentifier
        self.applicationPath = applicationPath
    }
}

public enum WindowLayout: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case topLeft, topRight, bottomLeft, bottomRight

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .leftHalf: "左半屏"
        case .rightHalf: "右半屏"
        case .topHalf: "上半屏"
        case .bottomHalf: "下半屏"
        case .topLeft: "左上四分之一屏"
        case .topRight: "右上四分之一屏"
        case .bottomLeft: "左下四分之一屏"
        case .bottomRight: "右下四分之一屏"
        }
    }

    public static func combining(_ layouts: some Sequence<WindowLayout>) -> WindowLayout? {
        let values = Set(layouts)
        if values.contains(.leftHalf), values.contains(.topHalf) { return .topLeft }
        if values.contains(.rightHalf), values.contains(.topHalf) { return .topRight }
        if values.contains(.leftHalf), values.contains(.bottomHalf) { return .bottomLeft }
        if values.contains(.rightHalf), values.contains(.bottomHalf) { return .bottomRight }
        return values.count == 1 ? values.first : nil
    }

    public func frame(in visibleFrame: CGRect) -> CGRect {
        let leftWidth = floor(visibleFrame.width / 2)
        let rightWidth = visibleFrame.width - leftWidth
        let bottomHeight = floor(visibleFrame.height / 2)
        let topHeight = visibleFrame.height - bottomHeight
        switch self {
        case .leftHalf:
            return CGRect(x: visibleFrame.minX, y: visibleFrame.minY, width: leftWidth, height: visibleFrame.height)
        case .rightHalf:
            return CGRect(x: visibleFrame.minX + leftWidth, y: visibleFrame.minY, width: rightWidth, height: visibleFrame.height)
        case .topHalf:
            return CGRect(x: visibleFrame.minX, y: visibleFrame.minY + bottomHeight, width: visibleFrame.width, height: topHeight)
        case .bottomHalf:
            return CGRect(x: visibleFrame.minX, y: visibleFrame.minY, width: visibleFrame.width, height: bottomHeight)
        case .topLeft:
            return CGRect(x: visibleFrame.minX, y: visibleFrame.minY + bottomHeight, width: leftWidth, height: topHeight)
        case .topRight:
            return CGRect(x: visibleFrame.minX + leftWidth, y: visibleFrame.minY + bottomHeight, width: rightWidth, height: topHeight)
        case .bottomLeft:
            return CGRect(x: visibleFrame.minX, y: visibleFrame.minY, width: leftWidth, height: bottomHeight)
        case .bottomRight:
            return CGRect(x: visibleFrame.minX + leftWidth, y: visibleFrame.minY, width: rightWidth, height: bottomHeight)
        }
    }
}

public enum ShortcutAction: Codable, Hashable, Sendable {
    case application(target: ApplicationTarget, mode: ApplicationOpenMode)
    case finderFolder(path: String)
    case terminal(fallbackPath: String, useFrontmostFinder: Bool)
    case showDesktop
    case windowLayout(WindowLayout)
    case remap(to: KeyCombination)

    public enum Kind: String, CaseIterable, Identifiable, Sendable {
        case application
        case finderFolder
        case terminal
        case showDesktop
        case windowLayout
        case remap

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .application: "打开应用"
            case .finderFolder: "打开 Finder 文件夹"
            case .terminal: "在路径打开终端"
            case .showDesktop: "显示桌面"
            case .windowLayout: "窗口布局"
            case .remap: "快捷键映射"
            }
        }
    }

    public var kind: Kind {
        switch self {
        case .application: .application
        case .finderFolder: .finderFolder
        case .terminal: .terminal
        case .showDesktop: .showDesktop
        case .windowLayout: .windowLayout
        case .remap: .remap
        }
    }

    public var summary: String {
        switch self {
        case let .application(target, mode):
            return "\(target.displayName) · \(mode.displayName)"
        case let .finderFolder(path):
            return "Finder · \(URL(fileURLWithPath: path).lastPathComponent)"
        case let .terminal(fallbackPath, useFrontmostFinder):
            let folder = URL(fileURLWithPath: fallbackPath).lastPathComponent
            return useFrontmostFinder ? "终端 · Finder 当前路径 / \(folder)" : "终端 · \(folder)"
        case .showDesktop:
            return "macOS · 返回桌面"
        case let .windowLayout(layout):
            return "窗口 · \(layout.displayName)"
        case let .remap(target):
            return "映射为 \(target.displayString) · 可叠加 Shift 选择"
        }
    }
}

public struct ShortcutRule: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var source: KeyCombination
    public var action: ShortcutAction
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        source: KeyCombination,
        action: ShortcutAction,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.source = source
        self.action = action
        self.isEnabled = isEnabled
    }
}
