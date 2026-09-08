import XCTest
@testable import SharedSupport
final class MigrationTests: XCTestCase {
    func testFailedValidationLeavesOriginalAndNoDestination() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("Old")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: source.appendingPathComponent("history"))
        let destination = root.appendingPathComponent("New")
        XCTAssertThrowsError(try DataMigration(destination: destination).run(sources: [.init(name: "Clipboard", directory: source, preferences: [:])], validate: { _ in throw CocoaError(.fileReadCorruptFile) }, applyPreferences: { _, _ in }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("history"), encoding: .utf8), "fixture")
    }
    func testInterruptedPreferencesResumeAndCompletedImportDoesNotOverwrite() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let migration = DataMigration(destination: root.appendingPathComponent("New"))
        let sources = [try DataMigration.Source(name: "Clipboard", directory: nil, preferences: ["limit": 42])]
        XCTAssertThrowsError(try migration.run(sources: sources, validate: { _ in }, applyPreferences: { _, _ in throw CocoaError(.fileWriteUnknown) }))
        XCTAssertEqual(migration.receipt()?.phase, "copied")
        var value: Int?
        try migration.run(sources: [], validate: { _ in }, applyPreferences: { _, values in value = values["limit"] as? Int })
        XCTAssertEqual(value, 42)
        XCTAssertEqual(migration.receipt()?.phase, "complete")
        try migration.run(sources: [], validate: { _ in XCTFail("must not copy again") }, applyPreferences: { _, _ in XCTFail("must not overwrite") })
    }
}
