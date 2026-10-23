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
}
