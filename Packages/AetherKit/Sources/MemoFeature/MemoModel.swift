import Foundation
import SharedSupport

@MainActor
final class MemoModel: ObservableObject {
    // A draft belongs to the workspace, not to a transient popover view.
    @Published var draftTitle = ""
    @Published var draftHasDeadline = false
    @Published var draftDeadline = Date()
    @Published private(set) var items: [MemoItem] = []
    @Published private(set) var storageMessage: String?

    @Published private(set) var sortedItems: [MemoItem] = []

    private let storage: MemoStorage

    init(storage: MemoStorage? = nil) {
        self.storage = storage ?? MemoStorage(directory: AppEnvironment.directory("Memo"))
        reload()
    }

    func add(title: String, deadline: Date?) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return persist { try storage.add(MemoItem(title: trimmed, deadline: deadline)) }
    }

    @discardableResult
    func addDraft() -> Bool {
        guard add(title: draftTitle, deadline: draftHasDeadline ? draftDeadline : nil) else { return false }
        draftTitle = ""
        draftHasDeadline = false
        return true
    }

    /// A checked item is complete, so it is removed instead of retaining finished personal notes.
    func complete(_ item: MemoItem) {
        _ = persist { try storage.complete(id: item.id) }
    }

    func reload() {
        do {
            let snapshot = try storage.presentation(reloading: true)
            items = snapshot.items
            sortedItems = snapshot.sorted
            storageMessage = nil
        } catch {
            storageMessage = error.localizedDescription
        }
    }

    @discardableResult
    private func persist(_ mutation: () throws -> Void) -> Bool {
        do {
            try mutation()
            let snapshot = try storage.presentation()
            items = snapshot.items
            sortedItems = snapshot.sorted
            storageMessage = nil
            return true
        } catch {
            storageMessage = error.localizedDescription
            return false
        }
    }
}
