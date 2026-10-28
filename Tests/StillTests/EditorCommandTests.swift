import Foundation
import XCTest
@testable import Still

final class EditorCommandTests: XCTestCase {
    @MainActor
    func testCommandDispatchesImmediatelyWhenEditorIsReady() {
        let bus = EditorCommandBus()
        let documentID = UUID()
        var delivered: [EditorCommand] = []
        bus.setCommandHandler { command in
            delivered.append(command)
            return true
        }

        bus.send(.insertMarkdown("\n| A | B |\n", documentID: documentID))

        XCTAssertEqual(delivered.count, 1)
        XCTAssertTrue(delivered[0].isTargeted(at: documentID))
        XCTAssertNil(bus.pending)
    }

    @MainActor
    func testCommandWaitsForEditorReadinessThenDispatchesOnce() {
        let bus = EditorCommandBus()
        let documentID = UUID()
        var editorReady = false
        var deliveryCount = 0
        bus.setCommandHandler { _ in
            guard editorReady else { return false }
            deliveryCount += 1
            return true
        }

        bus.send(.insertImage(url: "attachments/test.png", alt: "Test", documentID: documentID))
        XCTAssertNotNil(bus.pending)
        XCTAssertEqual(deliveryCount, 0)

        editorReady = true
        bus.dispatchPending()
        bus.dispatchPending()

        XCTAssertNil(bus.pending)
        XCTAssertEqual(deliveryCount, 1)
    }

    @MainActor
    func testStaleDocumentCommandIsConsumedAndCannotRunInAnotherDocument() {
        let bus = EditorCommandBus()
        let activeDocumentID = UUID()
        let staleDocumentID = UUID()
        var deliveredDocumentIDs: [UUID] = []
        bus.setCommandHandler { command in
            guard command.isTargeted(at: activeDocumentID) else { return true }
            deliveredDocumentIDs.append(command.documentID)
            return true
        }

        bus.send(.insertMarkdown("stale", documentID: staleDocumentID))

        XCTAssertFalse(EditorCommand(kind: .insertMarkdown("stale", documentID: staleDocumentID))
            .isTargeted(at: activeDocumentID))
        XCTAssertTrue(deliveredDocumentIDs.isEmpty)
        XCTAssertNil(bus.pending)

        bus.dispatchPending()
        XCTAssertTrue(deliveredDocumentIDs.isEmpty)
    }

    @MainActor
    func testFindCommandTargetsTheActiveDocumentAndEditorSession() {
        let bus = EditorCommandBus()
        let sessionID = UUID()
        let documentID = UUID()
        var delivered: EditorCommand?
        XCTAssertFalse(bus.hasActiveEditor)
        bus.activateSession(ownerID: sessionID, undo: {}, redo: {}, command: { command in
            delivered = command
            return true
        })

        bus.send(.showFind(query: "quiet search", documentID: documentID))

        XCTAssertTrue(bus.hasActiveEditor)
        XCTAssertEqual(delivered?.documentID, documentID)
        if case .showFind(let query, let targetID)? = delivered?.kind {
            XCTAssertEqual(query, "quiet search")
            XCTAssertEqual(targetID, documentID)
        } else {
            XCTFail("Expected the Find command")
        }
        XCTAssertTrue(bus.clearSession(ownerID: sessionID))
        XCTAssertFalse(bus.hasActiveEditor)
    }

    @MainActor
    func testStaleSessionCleanupCannotClearCurrentHandlersOrPendingCommand() throws {
        let bus = EditorCommandBus()
        let oldSessionID = UUID()
        let currentSessionID = UUID()
        let documentID = UUID()
        var oldUndoCount = 0
        var currentUndoCount = 0
        var currentRedoCount = 0
        var oldCommandCount = 0
        var currentCommandCount = 0
        var replacementCommandCount = 0

        bus.activateSession(ownerID: oldSessionID,
                            undo: { oldUndoCount += 1 },
                            redo: {},
                            command: { _ in oldCommandCount += 1; return false })
        bus.send(.insertMarkdown("pending", documentID: documentID))
        let pendingID = try XCTUnwrap(bus.pending?.id)
        XCTAssertEqual(oldCommandCount, 1)

        bus.activateSession(ownerID: currentSessionID,
                            undo: { currentUndoCount += 1 },
                            redo: { currentRedoCount += 1 },
                            command: { _ in currentCommandCount += 1; return false })
        XCTAssertEqual(bus.pending?.id, pendingID)

        // Repeated activation by the same Coordinator must not replace its handlers.
        bus.activateSession(ownerID: currentSessionID,
                            undo: {},
                            redo: {},
                            command: { _ in replacementCommandCount += 1; return true })

        XCTAssertTrue(bus.setEditorFocused(true, ownerID: currentSessionID))
        XCTAssertFalse(bus.setEditorFocused(false, ownerID: oldSessionID))
        XCTAssertTrue(bus.editorFocused)
        XCTAssertTrue(bus.undoIfEditorFocused())
        XCTAssertEqual(currentUndoCount, 1)
        XCTAssertEqual(oldUndoCount, 0)

        bus.dispatchPending()
        XCTAssertEqual(currentCommandCount, 1)
        XCTAssertEqual(replacementCommandCount, 0)
        XCTAssertEqual(bus.pending?.id, pendingID)

        // A late detach from the previous Coordinator cannot clear the current session.
        bus.clearSession(ownerID: oldSessionID)
        XCTAssertEqual(bus.pending?.id, pendingID)
        XCTAssertTrue(bus.editorFocused)
        bus.dispatchPending()
        XCTAssertEqual(currentCommandCount, 2)
        XCTAssertEqual(oldCommandCount, 1)
        XCTAssertEqual(replacementCommandCount, 0)
        XCTAssertTrue(bus.redoIfEditorFocused())
        XCTAssertEqual(currentRedoCount, 1)

        bus.clearSession(ownerID: currentSessionID)
        XCTAssertNil(bus.pending)
        XCTAssertFalse(bus.editorFocused)
        XCTAssertFalse(bus.undoIfEditorFocused())
        bus.send(.insertMarkdown("after clear", documentID: documentID))
        XCTAssertNotNil(bus.pending)
    }
}
