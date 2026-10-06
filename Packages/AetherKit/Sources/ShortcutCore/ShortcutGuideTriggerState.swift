import Foundation
import CAetherCore

public struct ShortcutGuideTriggerState: Sendable {
    public enum Transition: Equatable, Sendable {
        case none
        case schedule
        case show
        case cancel
        case release
    }

    private var core: AetherGuide

    public init(requiredModifiers: PhysicalModifierKeys) {
        core = AetherGuide(required: requiredModifiers.rawValue, held: 0, cancelled: 0, visible: 0, transition: 0)
    }

    public mutating func update(activeModifiers: PhysicalModifierKeys) -> Transition {
        advance(active: activeModifiers.rawValue, event: 0)
    }
    public mutating func keyPressed() -> Transition { advance(active: 0, event: 1) }
    public mutating func holdThresholdReached() -> Transition { advance(active: 0, event: 2) }

    private mutating func advance(active: UInt16, event: UInt8) -> Transition {
        core = aether_guide_update(core, active, event)
        switch core.transition {
        case 1: return .schedule
        case 2: return .show
        case 3: return .cancel
        case 4: return .release
        default: return .none
        }
    }

}

public enum ShortcutGuideConfiguration {
    public static let defaultHoldDuration: TimeInterval = 3
    public static let minimumHoldDuration: TimeInterval = 0.5
    public static let maximumHoldDuration: TimeInterval = 10
    public static let holdDurationStep: TimeInterval = 0.5

    public static func normalizedHoldDuration(_ duration: TimeInterval) -> TimeInterval {
        guard duration.isFinite else { return defaultHoldDuration }
        let clamped = min(max(duration, minimumHoldDuration), maximumHoldDuration)
        return (clamped / holdDurationStep).rounded() * holdDurationStep
    }
}

public enum ShortcutGuideLayout {
    public static func columnCount(itemCount: Int, availableWidth: CGFloat) -> Int {
        let desiredCount: Int
        if itemCount > 36 {
            desiredCount = 4
        } else if itemCount > 20 {
            desiredCount = 3
        } else {
            desiredCount = 2
        }

        let minimumCardWidth: CGFloat = 250
        let spacing: CGFloat = 8
        let widthLimitedCount = max(
            2,
            min(4, Int((availableWidth + spacing) / (minimumCardWidth + spacing)))
        )
        return min(desiredCount, widthLimitedCount)
    }
}

public struct ShortcutGuideLayerSelection: Sendable {
    public private(set) var index = 0
    public private(set) var count = 0

    public init() {}

    @discardableResult
    public mutating func reset(count: Int) -> Int {
        self.count = max(0, count)
        index = 0
        return index
    }

    @discardableResult
    public mutating func select(_ requestedIndex: Int) -> Int {
        guard count > 0 else {
            index = 0
            return index
        }
        index = min(max(requestedIndex, 0), count - 1)
        return index
    }

    @discardableResult
    public mutating func move(by offset: Int) -> Int {
        guard count > 0 else {
            index = 0
            return index
        }
        index = (index + offset % count + count) % count
        return index
    }
}
