import Foundation

/// A local, focused work item. One tomato represents a 25-minute focus block.
public struct MemoItem: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var pomodoroCount: Int
    public var deadline: Date?
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        pomodoroCount: Int = 1,
        deadline: Date? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.pomodoroCount = max(1, pomodoroCount)
        self.deadline = deadline
        self.createdAt = createdAt
    }
}
