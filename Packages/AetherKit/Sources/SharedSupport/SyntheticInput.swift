import CoreGraphics

/// One marker across features prevents paste events from triggering user remaps.
public enum SyntheticInput {
    private static let marker: Int64 = 0x41_45_54_48_45_52_31
    public static func tag(_ event: CGEvent) { event.setIntegerValueField(.eventSourceUserData, value: marker) }
    public static func isOurs(_ event: CGEvent) -> Bool { event.getIntegerValueField(.eventSourceUserData) == marker }
}
