import Foundation

/// Menu choices preserve valid existing values instead of snapping preferences on presentation.
enum SettingsDurationOptions {
    static func values(in range: ClosedRange<Double>, step: Double, current: Double) -> [Double] {
        var values = Array(stride(from: range.lowerBound, through: range.upperBound, by: step))
        if !values.contains(range.upperBound) { values.append(range.upperBound) }
        if current.isFinite && range.contains(current) && !values.contains(current) { values.append(current) }
        return values.sorted()
    }
}
