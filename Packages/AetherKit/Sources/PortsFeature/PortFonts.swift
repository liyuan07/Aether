import SwiftUI

private struct FontScaleKey: EnvironmentKey {
    static let defaultValue: Double = 1.0
}

public extension EnvironmentValues {
    var fontScale: Double {
        get { self[FontScaleKey.self] }
        set { self[FontScaleKey.self] = newValue }
    }
}

// MARK: - Modifiers

/// Applies a scaled version of a semantic text style. Use `.scaledFont(.caption)`
/// instead of `.font(.caption)` on any Text or SF Symbol that should respond to
/// the Settings font-size slider. Base sizes mirror macOS system text styles, so
/// at 1.0x the result matches the unscaled `.font(.caption)` rendering.
public struct ScaledFontModifier: ViewModifier {
    @Environment(\.fontScale) private var scale
    let style: Font.TextStyle
    let design: Font.Design?
    let weight: Font.Weight?
    let monospacedDigit: Bool

    public init(_ style: Font.TextStyle, design: Font.Design? = nil, weight: Font.Weight? = nil, monospacedDigit: Bool = false) {
        self.style = style
        self.design = design
        self.weight = weight
        self.monospacedDigit = monospacedDigit
    }

    public func body(content: Content) -> some View {
        let size = Self.baseSize(for: style) * scale
        var font: Font = design != nil ? .system(size: size, design: design!) : .system(size: size)
        // Some system styles carry a default weight that .system(size:) does not:
        // .headline is semibold. Preserve it when the caller didn't override the
        // weight, so .scaledFont(.headline) matches .font(.headline) at 1.0x.
        if let effectiveWeight = weight ?? Self.defaultWeight(for: style) {
            font = font.weight(effectiveWeight)
        }
        if monospacedDigit { font = font.monospacedDigit() }
        return content.font(font)
    }

    static func defaultWeight(for style: Font.TextStyle) -> Font.Weight? {
        style == .headline ? .semibold : nil
    }

    static func baseSize(for style: Font.TextStyle) -> Double {
        switch style {
        case .largeTitle: return 26
        case .title: return 22
        case .title2: return 17
        case .title3: return 15
        case .headline: return 13
        case .body: return 13
        case .callout: return 12
        case .subheadline: return 11
        case .footnote: return 10
        case .caption: return 10
        case .caption2: return 10
        @unknown default: return 13
        }
    }
}

/// Applies a scaled version of an explicit point size, for the handful of places
/// that use `.font(.system(size:))` rather than a semantic style (lane bars,
/// chart axis labels, badges).
public struct ScaledSizeFontModifier: ViewModifier {
    @Environment(\.fontScale) private var scale
    let size: CGFloat
    let weight: Font.Weight?
    let design: Font.Design?

    public init(size: CGFloat, weight: Font.Weight? = nil, design: Font.Design? = nil) {
        self.size = size
        self.weight = weight
        self.design = design
    }

    public func body(content: Content) -> some View {
        let scaled = size * scale
        var font: Font = design != nil ? .system(size: scaled, design: design!) : .system(size: scaled)
        if let weight { font = font.weight(weight) }
        return content.font(font)
    }
}

public extension View {
    /// Scaled replacement for `.font(_ style:)`. Responds to the font-size slider.
    func scaledFont(_ style: Font.TextStyle, design: Font.Design? = nil, weight: Font.Weight? = nil, monospacedDigit: Bool = false) -> some View {
        modifier(ScaledFontModifier(style, design: design, weight: weight, monospacedDigit: monospacedDigit))
    }

    /// Scaled replacement for `.font(.system(size:))`. Responds to the font-size slider.
    func scaledFont(size: CGFloat, weight: Font.Weight? = nil, design: Font.Design? = nil) -> some View {
        modifier(ScaledSizeFontModifier(size: size, weight: weight, design: design))
    }
}
