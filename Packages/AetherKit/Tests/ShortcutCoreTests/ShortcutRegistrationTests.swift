import XCTest
@testable import ShortcutCore
final class ShortcutRegistrationTests: XCTestCase {
    private let builtin = KeyCombination(keyCode: 38, modifiers: [.command, .shift])
    func testUserRuleReservesBuiltinButDisabledRuleDoesNot() {
        var rule = ShortcutRule(name: "Fixture", source: builtin, action: .finderFolder(path: "/tmp"))
        XCTAssertTrue(ShortcutRegistrationPolicy.userRulesClaim(builtin, rules: [rule]))
        rule.isEnabled = false
        XCTAssertFalse(ShortcutRegistrationPolicy.userRulesClaim(builtin, rules: [rule]))
    }
    func testPhysicalModifierRuleAlsoReservesCarbonCombination() {
        let rule = ShortcutRule(name: "Fixture", source: KeyCombination(keyCode: 38, modifiers: [], physicalModifiers: [.leftShift, .leftCommand]), action: .finderFolder(path: "/tmp"))
        XCTAssertTrue(ShortcutRegistrationPolicy.userRulesClaim(builtin, rules: [rule]))
        XCTAssertFalse(ShortcutRegistrationPolicy.userRulesClaim(KeyCombination(keyCode: 40, modifiers: [.command, .shift]), rules: [rule]))
    }
}
