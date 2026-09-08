import Foundation

public struct ShortcutGuideTriggerState: Sendable {
    public enum Transition: Equatable, Sendable {
        case none
        case schedule
        case show
        case cancel
        case release
    }

    private let requiredModifiers: PhysicalModifierKeys
    private var isChordHeld = false
    private var isCancelled = false
    private var isVisible = false

    public init(requiredModifiers: PhysicalModifierKeys) {
        self.requiredModifiers = requiredModifiers
    }

    public mutating func update(activeModifiers: PhysicalModifierKeys) -> Transition {
        let chordIsHeld = activeModifiers.intersection(requiredModifiers) == requiredModifiers

        if chordIsHeld, !isChordHeld {
            isChordHeld = true
            isCancelled = false
            isVisible = false
            return .schedule
        }
        if !chordIsHeld, isChordHeld {
            let wasVisible = isVisible
            isChordHeld = false
            isCancelled = false
            isVisible = false
            return wasVisible ? .release : .cancel
        }
        return .none
    }

    public mutating func keyPressed() -> Transition {
        guard isChordHeld else { return .none }
        isCancelled = true
        isVisible = false
        return .cancel
    }

    public mutating func holdThresholdReached() -> Transition {
        guard isChordHeld, !isCancelled, !isVisible else { return .none }
        isVisible = true
        return .show
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
