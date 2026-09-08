public enum ModifierTapKind: Sendable {
    case rightOption
    case bothShifts
}

public struct ModifierTapStep: Equatable, Sendable {
    public let keyCode: UInt16
    public let isKeyDown: Bool
    public let modifiers: ShortcutModifiers
    public let physicalModifiers: PhysicalModifierKeys

    public init(
        keyCode: UInt16,
        isKeyDown: Bool,
        modifiers: ShortcutModifiers,
        physicalModifiers: PhysicalModifierKeys = []
    ) {
        self.keyCode = keyCode
        self.isKeyDown = isKeyDown
        self.modifiers = modifiers
        self.physicalModifiers = physicalModifiers
    }
}

public enum ModifierTapSequence {
    public static let tapDuration: Double = 0.02

    public static func steps(for kind: ModifierTapKind) -> [ModifierTapStep] {
        switch kind {
        case .rightOption:
            return [
                ModifierTapStep(
                    keyCode: 61,
                    isKeyDown: true,
                    modifiers: .option,
                    physicalModifiers: .rightOption
                ),
                ModifierTapStep(keyCode: 61, isKeyDown: false, modifiers: [])
            ]

        case .bothShifts:
            return [
                ModifierTapStep(
                    keyCode: 56,
                    isKeyDown: true,
                    modifiers: .shift,
                    physicalModifiers: .leftShift
                ),
                ModifierTapStep(
                    keyCode: 60,
                    isKeyDown: true,
                    modifiers: .shift,
                    physicalModifiers: [.leftShift, .rightShift]
                ),
                ModifierTapStep(
                    keyCode: 60,
                    isKeyDown: false,
                    modifiers: .shift,
                    physicalModifiers: .leftShift
                ),
                ModifierTapStep(keyCode: 56, isKeyDown: false, modifiers: [])
            ]
        }
    }
}
