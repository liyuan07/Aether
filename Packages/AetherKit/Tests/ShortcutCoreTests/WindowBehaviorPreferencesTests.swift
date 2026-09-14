import Foundation
import Testing
@testable import ShortcutCore

@Test func olderPreferencesKeepTheirValuesAndDefaultWindowBehavior() throws {
    let data = Data(#"{"defaultBundleIdentifiers":{"T":"example.test"},"orderedBundleIdentifiers":{"T":["example.test"]},"holdDuration":0.8}"#.utf8)
    let preferences = try JSONDecoder().decode(ApplicationShortcutPreferences.self, from: data)
    #expect(preferences.restoreMinimizedWindows)
    #expect(preferences.windowBehaviorOverrides.isEmpty)
    #expect(preferences.defaultBundleIdentifiers["T"] == "example.test")
    #expect(preferences.orderedBundleIdentifiers["T"] == ["example.test"])
    #expect(preferences.holdDuration == 0.8)
}

@Test func applicationExceptionsOverrideGlobalBehaviorAndRoundTrip() throws {
    var preferences = ApplicationShortcutPreferences()
    preferences.restoreMinimizedWindows = false
    preferences.windowBehaviorOverrides = ["example.restore": .restoreMinimized,
                                           "example.keep": .keepMinimized, "example.activate": .activateOnly]
    let decoded = try JSONDecoder().decode(ApplicationShortcutPreferences.self, from: JSONEncoder().encode(preferences))
    #expect(decoded == preferences)
    #expect(!decoded.windowBehavior(for: "example.default").restoreMinimized)
    #expect(decoded.windowBehavior(for: "example.restore").restoreMinimized)
    #expect(!decoded.windowBehavior(for: "example.keep").restoreMinimized)
    #expect(!decoded.windowBehavior(for: "example.activate").moveWindows)
    #expect(!decoded.windowBehavior(for: nil).restoreMinimized)
}
