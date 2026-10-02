import Testing
@testable import WhatPortCore

@Test func isNewerDetectsHigherPatch() {
    #expect(AppInfo.isNewer(remote: "1.3.2", current: "1.3.1"))
    #expect(AppInfo.isNewer(remote: "1.4.0", current: "1.3.9"))
    #expect(AppInfo.isNewer(remote: "2.0.0", current: "1.9.9"))
}

@Test func isNewerRejectsSameOrOlder() {
    #expect(!AppInfo.isNewer(remote: "1.3.1", current: "1.3.1"))
    #expect(!AppInfo.isNewer(remote: "1.3.0", current: "1.3.1"))
    #expect(!AppInfo.isNewer(remote: "1.2.9", current: "1.3.0"))
}

// Numeric comparison, not lexical: "1.10.0" must beat "1.9.0" even though "1" < "9".
@Test func isNewerComparesSegmentsNumerically() {
    #expect(AppInfo.isNewer(remote: "1.10.0", current: "1.9.0"))
    #expect(!AppInfo.isNewer(remote: "1.9.0", current: "1.10.0"))
}

// Missing trailing segments compare as zero, so "1.3" and "1.3.0" are equal.
@Test func isNewerTreatsMissingSegmentsAsZero() {
    #expect(!AppInfo.isNewer(remote: "1.3", current: "1.3.0"))
    #expect(AppInfo.isNewer(remote: "1.3.1", current: "1.3"))
}

// Non-numeric segments degrade to zero rather than crashing.
@Test func isNewerHandlesNonNumericSegments() {
    #expect(!AppInfo.isNewer(remote: "dev", current: "1.3.1"))
    #expect(AppInfo.isNewer(remote: "1.3.1", current: "dev"))
}
