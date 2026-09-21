import Foundation
import SharedSupport

@MainActor
final class MemoModel: ObservableObject {
    @Published private(set) var items: [MemoItem] = []
    @Published private(set) var storageMessage: String?

    private let storage: MemoStorage

    init(storage: MemoStorage? = nil) {
        self.storage = storage ?? MemoStorage(directory: AppEnvironment.directory("Memo"))
        reload()
    }

    var sortedItems: [MemoItem] {
        items.sorted {
            switch ($0.deadline, $1.deadline) {
            case let (left?, right?):
                left == right ? $0.createdAt < $1.createdAt : left < right
            case (.some, .none): true
            case (.none, .some): false
            case (.none, .none): $0.createdAt < $1.createdAt
            }
        }
    }

    func add(title: String, pomodoroCount: Int, deadline: Date?) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return persist(items + [MemoItem(title: trimmed, pomodoroCount: pomodoroCount, deadline: deadline)])
    }

    /// A checked item is complete, so it is removed instead of retaining finished personal notes.
    func complete(_ item: MemoItem) {
        _ = persist(items.filter { $0.id != item.id })
    }

    func updatePomodoroCount(for item: MemoItem, to count: Int) {
        var next = items
        guard let index = next.firstIndex(where: { $0.id == item.id }) else { return }
        next[index].pomodoroCount = max(1, count)
        _ = persist(next)
    }

    func reload() {
        do {
            items = try storage.load()
            storageMessage = nil
        } catch {
            storageMessage = error.localizedDescription
        }
    }

    @discardableResult
    private func persist(_ next: [MemoItem]) -> Bool {
        do {
            try storage.save(next)
            items = next
            storageMessage = nil
            return true
        } catch {
            storageMessage = error.localizedDescription
            return false
        }
    }
}
