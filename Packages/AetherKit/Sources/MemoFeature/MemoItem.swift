import Foundation

/// A local todo item with an optional deadline.
public struct MemoItem: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var deadline: Date?
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        deadline: Date? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.deadline = deadline
        self.createdAt = createdAt
    }
}
