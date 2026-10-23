import XCTest
@testable import Still

final class FolderDisclosureStateTests: XCTestCase {
    func testVirtualRootsStartExpandedAndCanBeCollapsedIndependently() {
        var state = FolderDisclosureState()
        let notesRoot = FolderDisclosureState.rootID(for: .notes)
        let wikiRoot = FolderDisclosureState.rootID(for: .wiki)

        XCTAssertTrue(state.isExpanded(notesRoot))
        XCTAssertTrue(state.isExpanded(wikiRoot))

        state.toggle(notesRoot)

        XCTAssertFalse(state.isExpanded(notesRoot))
        XCTAssertTrue(state.isExpanded(wikiRoot))
    }

    func testOpeningNoteExpandsItsAncestorsAndManualCollapsePersists() {
        var state = FolderDisclosureState()
        let parent = Folder(section: .notes, path: ["Arbeit"])
        let child = Folder(section: .notes, path: ["Arbeit", "Planung"])

        state.expandAncestors(section: .notes, path: child.path)
        XCTAssertTrue(state.isExpanded(FolderDisclosureState.rootID(for: .notes)))
        XCTAssertTrue(state.isExpanded(parent.id))
        XCTAssertTrue(state.isExpanded(child.id))

        state.toggle(parent.id)

        XCTAssertFalse(state.isExpanded(parent.id))
        XCTAssertTrue(state.isExpanded(child.id))
    }

    func testExplicitNavigationCanReopenOnlyTheRequiredSectionPath() {
        var state = FolderDisclosureState()
        let notesFolder = Folder(section: .notes, path: ["Privat"])
        let wikiFolder = Folder(section: .wiki, path: ["Prozesse"])
        state.expandAncestors(section: .notes, path: notesFolder.path)
        state.toggle(notesFolder.id)
        state.expandAncestors(section: .wiki, path: wikiFolder.path)

        XCTAssertFalse(state.isExpanded(notesFolder.id))
        XCTAssertTrue(state.isExpanded(wikiFolder.id))
        XCTAssertTrue(state.isExpanded(FolderDisclosureState.rootID(for: .wiki)))
    }
}
