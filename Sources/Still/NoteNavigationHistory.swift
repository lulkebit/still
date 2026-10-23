import Foundation
import Observation

@MainActor
@Observable
final class NoteNavigationHistory {
    private(set) var backStack: [UUID] = []
    private var validNoteIDs: Set<UUID> = []

    var canGoBack: Bool { backStack.contains(where: validNoteIDs.contains) }

    func updateNotes(_ notes: [Note]) {
        validNoteIDs = Set(notes.map(\.id))
    }

    func record(from currentID: UUID?, to nextID: UUID?) {
        guard let currentID, let nextID, currentID != nextID else { return }
        backStack.append(currentID)
    }

    func popPrevious() -> UUID? {
        while let id = backStack.popLast() {
            if validNoteIDs.contains(id) { return id }
        }
        return nil
    }
}
