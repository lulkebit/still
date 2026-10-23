import Foundation
import XCTest
@testable import Still

final class EditorLinkPolicyTests: XCTestCase {
    func testWikiLinkRequestsValidateSourceExactTokenAndUTF16Offsets() throws {
        let documentID = UUID()
        let staleID = UUID()
        let markdown = "Emoji 👩‍🚀 then [[Café|東京]]"
        let parsed = try XCTUnwrap(NoteLinks.links(in: markdown).first)
        let source = markdown as NSString
        let original = source.substring(with: parsed.range)
        let body: [String: Any] = [
            "type": "openWikiLink", "id": documentID.uuidString,
            "target": parsed.target, "from": parsed.range.location,
            "to": NSMaxRange(parsed.range), "original": original
        ]

        let request = try XCTUnwrap(EditorLinkRequestPolicy.wikiLinkRequest(
            body: body, currentDocumentID: documentID, markdown: markdown))
        XCTAssertEqual(request.range, parsed.range)
        XCTAssertEqual(request.target, "Café")
        XCTAssertNil(EditorLinkRequestPolicy.wikiLinkRequest(body: body, currentDocumentID: staleID, markdown: markdown))

        var changedRange = body
        changedRange["to"] = NSMaxRange(parsed.range) - 1
        XCTAssertNil(EditorLinkRequestPolicy.wikiLinkRequest(body: changedRange, currentDocumentID: documentID, markdown: markdown))
        var changedText = body
        changedText["original"] = "[[Café]]"
        XCTAssertNil(EditorLinkRequestPolicy.wikiLinkRequest(body: changedText, currentDocumentID: documentID, markdown: markdown))
        var changedTarget = body
        changedTarget["target"] = "Other"
        XCTAssertNil(EditorLinkRequestPolicy.wikiLinkRequest(body: changedTarget, currentDocumentID: documentID, markdown: markdown))
        XCTAssertNil(EditorLinkRequestPolicy.wikiLinkRequest(body: body, currentDocumentID: documentID,
                                                              markdown: markdown.replacingOccurrences(of: "Café", with: "Tea")))
    }

    func testExternalURLPolicyAllowsWebAndMailAndRejectsUnsafeSchemesOrAuthorities() {
        let documentID = UUID()
        func url(_ value: String, id: UUID = documentID) -> URL? {
            EditorLinkRequestPolicy.externalURL(body: ["type": "openExternalLink", "id": id.uuidString, "url": value],
                                                currentDocumentID: documentID)
        }

        XCTAssertEqual(url("https://example.com/a")?.scheme, "https")
        XCTAssertEqual(url("mailto:hello@example.com")?.scheme, "mailto")
        XCTAssertNil(url("javascript:alert(1)"))
        XCTAssertNil(url("file:///etc/passwd"))
        XCTAssertNil(url("https:///missing-host"))
        XCTAssertNil(url("https://user:secret@example.com"))
        XCTAssertNil(url("mailto:"))
        XCTAssertNil(url("https://example.com", id: UUID()))
        XCTAssertNil(url("https://example.com\n.evil"))
    }
}

final class NoteNavigationHistoryTests: XCTestCase {
    @MainActor
    func testHistoryIgnoresInitialAndSameNoteNavigationAndPopsInReverseOrder() {
        let history = NoteNavigationHistory()
        let first = Note(title: "First")
        let second = Note(title: "Second")
        let third = Note(title: "Third")
        history.updateNotes([first, second, third])

        history.record(from: nil, to: first.id)
        history.record(from: first.id, to: first.id)
        XCTAssertFalse(history.canGoBack)
        history.record(from: first.id, to: second.id)
        history.record(from: second.id, to: third.id)
        XCTAssertEqual(history.backStack, [first.id, second.id])
        XCTAssertEqual(history.popPrevious(), second.id)
        XCTAssertEqual(history.popPrevious(), first.id)
        XCTAssertNil(history.popPrevious())
        XCTAssertFalse(history.canGoBack)
    }

    @MainActor
    func testHistorySkipsDeletedNotesAndReflectsValidityChanges() {
        let history = NoteNavigationHistory()
        let deleted = Note(title: "Deleted")
        let prior = Note(title: "Prior")
        let current = Note(title: "Current")
        history.updateNotes([prior, current])
        history.record(from: deleted.id, to: current.id)
        history.record(from: prior.id, to: current.id)

        XCTAssertTrue(history.canGoBack)
        XCTAssertEqual(history.popPrevious(), prior.id)
        XCTAssertNil(history.popPrevious())
        history.record(from: deleted.id, to: current.id)
        history.updateNotes([current])
        XCTAssertFalse(history.canGoBack)
        XCTAssertNil(history.popPrevious())
    }
}
