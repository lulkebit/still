import XCTest
@testable import Still

final class AIContextPolicyTests: XCTestCase {
    func testOptimizeContextScopesSelectOnlyVisibleRelevantNotes() throws {
        let anchorID = UUID()
        let current = Note(id: anchorID, title: "Current", section: .notes,
                           folders: ["Project"], markdown: "CURRENT_CONTEXT_SENTINEL")
        let sibling = Note(title: "Sibling", section: .notes, folders: ["Project"], markdown: "SIBLING_CONTEXT_SENTINEL")
        let otherFolder = Note(title: "Other", section: .notes, folders: ["Archive"], markdown: "OTHER_CONTEXT_SENTINEL")
        let hiddenWiki = Note(title: "Wiki", section: .wiki, folders: ["Project"], markdown: "HIDDEN_CONTEXT_SENTINEL")
        let visible = [current, sibling, otherFolder]
        let folders = [
            Folder(section: .notes, path: ["Project"]),
            Folder(section: .notes, path: ["Archive"]),
            Folder(section: .wiki, path: ["Project"])
        ]

        let currentContext = AIContextPolicy.makeContext(
            for: .init(choice: .currentNote), anchorNoteID: anchorID,
            visibleNotes: visible, visibleFolders: folders)
        XCTAssertTrue(currentContext.contains("CURRENT_CONTEXT_SENTINEL"))
        XCTAssertFalse(currentContext.contains("SIBLING_CONTEXT_SENTINEL"))

        let folderContext = AIContextPolicy.makeContext(
            for: .init(choice: .currentFolder), anchorNoteID: anchorID,
            visibleNotes: visible, visibleFolders: folders)
        XCTAssertTrue(folderContext.contains("CURRENT_CONTEXT_SENTINEL"))
        XCTAssertTrue(folderContext.contains("SIBLING_CONTEXT_SENTINEL"))
        XCTAssertFalse(folderContext.contains("OTHER_CONTEXT_SENTINEL"))
        XCTAssertFalse(folderContext.contains("HIDDEN_CONTEXT_SENTINEL"))

        let selectedContext = AIContextPolicy.makeContext(
            for: .init(choice: .selectedSources, selectedSourceIDs: [sibling.id, hiddenWiki.id]),
            anchorNoteID: anchorID, visibleNotes: visible, visibleFolders: folders)
        XCTAssertTrue(selectedContext.contains("SIBLING_CONTEXT_SENTINEL"))
        XCTAssertFalse(selectedContext.contains("CURRENT_CONTEXT_SENTINEL"))
        XCTAssertFalse(selectedContext.contains("HIDDEN_CONTEXT_SENTINEL"))
        XCTAssertEqual(AIContextPolicy.makeContext(
            for: .init(choice: .none), anchorNoteID: anchorID,
            visibleNotes: visible, visibleFolders: folders), "")
    }

    func testContextIsBoundedAndChatScopeEnforcesActualAllowedIDs() throws {
        let anchor = Note(title: "Anchor", section: .notes, folders: ["Work"],
                          markdown: String(repeating: "A", count: 2_000))
        let sibling = Note(title: "Sibling", section: .notes, folders: ["Work"], markdown: "B")
        let other = Note(title: "Other", section: .notes, folders: ["Elsewhere"], markdown: "C")
        let notes = [anchor, sibling, other]
        let context = AIContextPolicy.makeContext(
            for: .init(choice: .currentFolder), anchorNoteID: anchor.id,
            visibleNotes: notes, visibleFolders: [], limit: 80)
        XCTAssertLessThanOrEqual(context.count, 80)

        XCTAssertEqual(ChatContextPolicy.allowedLocalNoteIDs(
            for: .init(localScope: .currentNote, anchorNoteID: anchor.id, includeConfluence: false),
            visibleNotes: notes), [anchor.id])
        XCTAssertEqual(ChatContextPolicy.allowedLocalNoteIDs(
            for: .init(localScope: .currentFolder, anchorNoteID: anchor.id, includeConfluence: false),
            visibleNotes: notes), [anchor.id, sibling.id])
        XCTAssertEqual(ChatContextPolicy.allowedLocalNoteIDs(
            for: .init(localScope: .allLocal, anchorNoteID: nil, includeConfluence: false),
            visibleNotes: notes), Set(notes.map(\.id)))
        XCTAssertTrue(ChatContextPolicy.allowedLocalNoteIDs(
            for: .none, visibleNotes: notes).isEmpty)
        XCTAssertFalse(ChatContextPolicy.localCatalog(visibleNotes: notes, allowedIDs: [other.id]).contains(anchor.title))
        let boundedCatalog = ChatContextPolicy.localCatalog(visibleNotes: notes,
                                                              allowedIDs: [anchor.id, sibling.id],
                                                              limit: 61)
        XCTAssertTrue(boundedCatalog.contains(anchor.id.uuidString))
        XCTAssertFalse(boundedCatalog.contains(sibling.id.uuidString), "Catalog entries remain whole at the character limit")
    }
}
