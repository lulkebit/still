import Foundation
import XCTest
@testable import Still

final class WikiSettingsTests: XCTestCase {
    @MainActor
    func testDisablingWikiHidesEverySurfaceAndRejectsStaleStoreActionsWithoutDeletingData() throws {
        let root = try temporaryWorkspace()
        defer { removeWorkspace(root) }
        let store = StillStore(rootURL: root, seedIfEmpty: false)
        let target = try store.createNote(section: .notes, title: "Plain", markdown: "Target")
        let source = try store.createNote(section: .notes, title: "Start", markdown: "- [ ] Notes task\n\n[[Plain]]")
        let wikiFolder = try store.createFolder(section: .wiki, parentPath: [], name: "Reference")
        let wikiNote = try store.createNote(section: .wiki, folders: wikiFolder.path, title: "Guide", markdown: "- [ ] Wiki task")
        let wikiTrash = try store.createNote(section: .wiki, title: "Deleted guide", markdown: "Keep in trash")
        try store.trashNote(id: wikiTrash.id)
        store.setLastOpenedNote(wikiNote.id)
        store.updateMarkdown(id: wikiNote.id, markdown: "Latest wiki text")

        XCTAssertEqual(store.resolveWikiLink("wiki/Reference/Guide", from: source)?.id, wikiNote.id)
        XCTAssertEqual(store.backlinks(to: target).map(\.id), [source.id])
        let revision = store.linkCatalogRevision
        let confluence = ConfluenceSettings(enabled: true, baseURL: "https://example.atlassian.net/wiki")
        try store.updateFeatureSettings(wikiEnabled: false, confluenceSettings: confluence)

        XCTAssertFalse(store.wikiEnabled)
        XCTAssertFalse(store.canAccess(.wiki))
        XCTAssertTrue(store.canAccess(.notes))
        XCTAssertEqual(store.linkCatalogRevision, revision + 1)
        XCTAssertEqual(store.visibleNotes.map(\.id), [target.id, source.id])
        XCTAssertTrue(store.visibleFolders.isEmpty)
        XCTAssertTrue(store.visibleTrash.isEmpty)
        XCTAssertEqual(store.notes.first(where: { $0.id == wikiNote.id })?.markdown, "Latest wiki text")
        XCTAssertEqual(store.lastOpenedNoteID, source.id)
        XCTAssertEqual(store.confluenceSettings, confluence)
        XCTAssertEqual(store.embeddedTasks.map(\.title), ["Notes task"])
        XCTAssertEqual(store.resolveWikiLink("Plain", from: source)?.id, target.id)
        XCTAssertNil(store.resolveWikiLink("wiki/Reference/Guide", from: source))
        XCTAssertEqual(store.backlinks(to: target).map(\.id), [source.id])

        store.updateMarkdown(id: wikiNote.id, markdown: "Stale edit")
        XCTAssertEqual(store.notes.first(where: { $0.id == wikiNote.id })?.markdown, "Latest wiki text")
        XCTAssertThrowsError(try store.createNote(section: .wiki, title: "No access"))
        XCTAssertThrowsError(try store.createFolder(section: .wiki, parentPath: [], name: "No access"))
        XCTAssertThrowsError(try store.renameNote(id: wikiNote.id, title: "No access"))
        XCTAssertThrowsError(try store.moveNote(id: source.id, section: .wiki, folders: []))
        XCTAssertThrowsError(try store.createLinkedNote(target: "wiki/Reference/New", from: source))
        XCTAssertThrowsError(try store.restoreTrashItem(id: wikiTrash.id))
        XCTAssertThrowsError(try store.trashNote(id: wikiNote.id))
        XCTAssertThrowsError(try store.renameFolder(wikiFolder, name: "No access"))
        XCTAssertFalse(store.folderExists(section: .wiki, path: wikiFolder.path))

        let reloaded = StillStore(rootURL: root, seedIfEmpty: false)
        XCTAssertNil(reloaded.loadError)
        XCTAssertFalse(reloaded.wikiEnabled)
        XCTAssertEqual(reloaded.settings, .empty)
        XCTAssertEqual(reloaded.notes.first(where: { $0.id == wikiNote.id })?.markdown, "Latest wiki text")
        XCTAssertTrue(reloaded.trash.contains(where: { $0.id == wikiTrash.id }))
        XCTAssertEqual(reloaded.confluenceSettings, confluence)

        try reloaded.updateFeatureSettings(wikiEnabled: true, confluenceSettings: confluence)
        XCTAssertTrue(reloaded.canAccess(.wiki))
        XCTAssertEqual(reloaded.visibleNotes.first(where: { $0.id == wikiNote.id })?.markdown, "Latest wiki text")
    }

    func testOldManifestDefaultsNewFeatureSettingsAndRetainsAISettings() throws {
        let manifest = #"{"formatVersion":1,"notes":[],"folders":[],"tasks":[],"trash":[],"settings":{"baseURL":"https://provider.example/v1","model":"small","enabled":true},"lastOpenedNoteID":null}"#
        let decoded = try JSONDecoder().decode(StoreManifest.self, from: Data(manifest.utf8))

        XCTAssertTrue(decoded.wikiEnabled)
        XCTAssertEqual(decoded.confluenceSettings, .empty)
        XCTAssertEqual(decoded.settings, AISettings(baseURL: "https://provider.example/v1", model: "small", enabled: true))
    }

    @MainActor
    func testFeatureSettingsRollBackWhenManifestCannotBeSaved() throws {
        let root = try temporaryWorkspace()
        defer { removeWorkspace(root) }
        let store = StillStore(rootURL: root, seedIfEmpty: true)
        let manifestURL = root.appendingPathComponent("manifest.json")
        try FileManager.default.removeItem(at: manifestURL)
        try FileManager.default.createDirectory(at: manifestURL, withIntermediateDirectories: true)

        XCTAssertThrowsError(try store.updateFeatureSettings(
            wikiEnabled: false,
            confluenceSettings: ConfluenceSettings(enabled: true, baseURL: "https://example.atlassian.net/wiki")
        ))
        XCTAssertTrue(store.wikiEnabled)
        XCTAssertEqual(store.confluenceSettings, .empty)
        XCTAssertEqual(store.linkCatalogRevision, 0)
    }

    private func temporaryWorkspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("StillWikiSettings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func removeWorkspace(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
