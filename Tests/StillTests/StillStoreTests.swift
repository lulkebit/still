import Foundation
import XCTest
@testable import Still

final class StillStoreTests: XCTestCase {
    @MainActor
    func testMarkdownRoundTripsThroughReadableUnicodeAndSpacedFolders() throws {
        let root = try temporaryWorkspace()
        defer { removeWorkspace(root) }
        let store = StillStore(rootURL: root, seedIfEmpty: false)
        let markdown = "# Über Café ☕\n\nÄpfel & Öl — 東京\n"

        let note = try store.createNote(section: .notes, folders: ["Projekte mit Leerzeichen", "Hörbücher & Bücher"],
                                        title: "Märchen aus Köln", markdown: markdown)
        let relativePath = PathSafety.safeRelativeMarkdownPath(section: note.section, folders: note.folders, title: note.title)
        let savedURL = root.appending(path: relativePath)
        XCTAssertEqual(try Data(contentsOf: savedURL), Data(markdown.utf8))

        let reloaded = StillStore(rootURL: root, seedIfEmpty: false)
        XCTAssertNil(reloaded.loadError)
        XCTAssertEqual(reloaded.notes(in: .notes, folderPath: note.folders).first?.markdown, markdown)
        XCTAssertEqual(reloaded.notes.first?.title, "Märchen aus Köln")
    }

    @MainActor
    func testCanonicalTitleCollisionGetsANewFileWithoutOverwritingTheFirst() throws {
        let root = try temporaryWorkspace()
        defer { removeWorkspace(root) }
        let store = StillStore(rootURL: root, seedIfEmpty: false)

        let first = try store.createNote(section: .notes, title: "Café / Notes?", markdown: "original")
        let second = try store.createNote(section: .notes, title: "Cafe Notes", markdown: "second")

        XCTAssertNotEqual(first.title, second.title)
        XCTAssertNotEqual(PathSafety.safeRelativeMarkdownPath(section: first.section, folders: first.folders, title: first.title),
                          PathSafety.safeRelativeMarkdownPath(section: second.section, folders: second.folders, title: second.title))
        XCTAssertEqual(try String(contentsOf: root.appending(path: PathSafety.safeRelativeMarkdownPath(section: first.section, folders: first.folders, title: first.title)), encoding: .utf8), "original")
        XCTAssertEqual(try String(contentsOf: root.appending(path: PathSafety.safeRelativeMarkdownPath(section: second.section, folders: second.folders, title: second.title)), encoding: .utf8), "second")
    }

    @MainActor
    func testTrashingReusingTitleAndRestoringPreservesBothNotesAfterReload() throws {
        let root = try temporaryWorkspace()
        defer { removeWorkspace(root) }
        let store = StillStore(rootURL: root, seedIfEmpty: false)
        let original = try store.createNote(section: .notes, title: "Reiseplan", markdown: "Ursprünglicher Inhalt")

        try store.trashNote(id: original.id)
        let replacement = try store.createNote(section: .notes, title: "Reiseplan", markdown: "Neuer Inhalt")
        XCTAssertEqual(replacement.title, original.title)
        try store.restoreTrashItem(id: original.id)

        let reloaded = StillStore(rootURL: root, seedIfEmpty: false)
        XCTAssertNil(reloaded.loadError)
        XCTAssertTrue(reloaded.trash.isEmpty)
        XCTAssertEqual(Set(reloaded.notes.map(\.markdown)), Set(["Ursprünglicher Inhalt", "Neuer Inhalt"]))
        XCTAssertEqual(reloaded.notes.first(where: { $0.id == replacement.id })?.markdown, "Neuer Inhalt")
        XCTAssertEqual(reloaded.notes.first(where: { $0.id == original.id })?.markdown, "Ursprünglicher Inhalt")
    }

    @MainActor
    func testNestedFolderRenameAndMoveKeepMarkdownReadable() throws {
        let root = try temporaryWorkspace()
        defer { removeWorkspace(root) }
        let store = StillStore(rootURL: root, seedIfEmpty: false)
        let parent = try store.createFolder(section: .notes, parentPath: [], name: "Projekte")
        let child = try store.createFolder(section: .notes, parentPath: parent.path, name: "Entwurf")
        let destination = try store.createFolder(section: .notes, parentPath: [], name: "Archiv")
        let note = try store.createNote(section: .notes, folders: child.path, title: "Plan", markdown: "Unterlagen: déjà vu")

        try store.renameFolder(child, name: "Finale Fassung")
        XCTAssertEqual(store.notes.first(where: { $0.id == note.id })?.folders, ["Projekte", "Finale Fassung"])
        let renamed = try XCTUnwrap(store.folders.first(where: { $0.name == "Finale Fassung" }))
        try store.moveFolder(renamed, into: destination.path)

        let reloaded = StillStore(rootURL: root, seedIfEmpty: false)
        XCTAssertNil(reloaded.loadError)
        let moved = try XCTUnwrap(reloaded.notes.first(where: { $0.id == note.id }))
        XCTAssertEqual(moved.folders, ["Archiv", "Finale Fassung"])
        XCTAssertEqual(moved.markdown, "Unterlagen: déjà vu")
        XCTAssertTrue(reloaded.folderExists(section: .notes, path: moved.folders))
    }

    @MainActor
    func testCorruptManifestAndMissingReferencedMarkdownMakeWorkspaceReadOnly() throws {
        let corruptRoot = try temporaryWorkspace()
        defer { removeWorkspace(corruptRoot) }
        let manifestURL = corruptRoot.appendingPathComponent("manifest.json")
        let corruptBytes = Data("{ definitely not json".utf8)
        try corruptBytes.write(to: manifestURL)
        let corrupt = StillStore(rootURL: corruptRoot)
        XCTAssertNotNil(corrupt.loadError)
        XCTAssertTrue(corrupt.notes.isEmpty)
        XCTAssertThrowsError(try corrupt.createTask(title: "Must not write"))
        XCTAssertEqual(try Data(contentsOf: manifestURL), corruptBytes)
        XCTAssertTrue(corrupt.tasks.isEmpty)

        let missingRoot = try temporaryWorkspace()
        defer { removeWorkspace(missingRoot) }
        let referenced = Note(title: "Missing", markdown: "not present")
        let manifest = StoreManifest(formatVersion: 1, notes: [NoteIndexEntry(note: referenced)], folders: [], tasks: [],
                                     trash: [], settings: .empty, lastOpenedNoteID: nil)
        try JSONEncoder().encode(manifest).write(to: missingRoot.appendingPathComponent("manifest.json"))
        let missing = StillStore(rootURL: missingRoot)
        XCTAssertNotNil(missing.loadError)
        XCTAssertTrue(missing.notes.isEmpty)
        XCTAssertThrowsError(try missing.createTask(title: "Must not seed"))
        XCTAssertTrue(missing.tasks.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingRoot.appending(path: "notes/missing.md").path))
    }

    @MainActor
    func testExistingMarkdownWithoutManifestIsNotSeededOverOrMadeWritable() throws {
        let root = try temporaryWorkspace()
        defer { removeWorkspace(root) }
        let notesDirectory = root.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notesDirectory, withIntermediateDirectories: true)
        let existingURL = notesDirectory.appendingPathComponent("private-work.md")
        let existing = Data("Existing workspace content — do not replace".utf8)
        try existing.write(to: existingURL)

        let store = StillStore(rootURL: root)
        XCTAssertNotNil(store.loadError)
        XCTAssertTrue(store.notes.isEmpty)
        XCTAssertThrowsError(try store.createNote(section: .notes, title: "Welcome", markdown: "seed"))
        XCTAssertEqual(try Data(contentsOf: existingURL), existing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("manifest.json").path))
    }

    @MainActor
    func testEmbeddedTaskToggleChangesOnlyExactUnfencedLineAndRejectsStaleLine() throws {
        let root = try temporaryWorkspace()
        defer { removeWorkspace(root) }
        let store = StillStore(rootURL: root, seedIfEmpty: false)
        let markdown = "Before\n- [ ] Buy café beans\n```md\n- [ ] example only\n```\n+ [X] Ship 東京"
        let note = try store.createNote(section: .notes, title: "Tasks", markdown: markdown)

        XCTAssertEqual(store.embeddedTasks.map(\.title), ["Buy café beans", "Ship 東京"])
        let stale = EmbeddedTask(noteID: note.id, noteTitle: note.title, lineIndex: 1, line: "- [ ] A stale task",
                                 title: "A stale task", isDone: false)
        store.toggleEmbeddedTask(stale)
        XCTAssertEqual(store.notes.first?.markdown, markdown)

        let exact = try XCTUnwrap(store.embeddedTasks.first)
        store.toggleEmbeddedTask(exact)
        XCTAssertEqual(store.notes.first?.markdown,
                       "Before\n- [x] Buy café beans\n```md\n- [ ] example only\n```\n+ [X] Ship 東京")
        XCTAssertEqual(store.embeddedTasks.map(\.isDone), [true, true])
    }

    @MainActor
    func testTaskStatusDateAndPriorityPersist() throws {
        let root = try temporaryWorkspace()
        defer { removeWorkspace(root) }
        let store = StillStore(rootURL: root, seedIfEmpty: false)
        var task = try store.createTask(title: "Ship release")
        task.status = .waiting
        task.dueDate = Date(timeIntervalSince1970: 1_800_000_000)
        task.priority = .high
        try store.updateTask(task)

        let reloaded = StillStore(rootURL: root, seedIfEmpty: false)
        XCTAssertEqual(reloaded.tasks.first?.id, task.id)
        XCTAssertEqual(reloaded.tasks.first?.status, .waiting)
        XCTAssertEqual(reloaded.tasks.first?.dueDate, task.dueDate)
        XCTAssertEqual(reloaded.tasks.first?.priority, .high)
    }

    @MainActor
    func testGeneratedWikiPagesRejectEmptyAndTraversalAndValidateAllBeforeWriting() throws {
        let root = try temporaryWorkspace()
        defer { removeWorkspace(root) }
        let store = StillStore(rootURL: root, seedIfEmpty: false)
        let baseline = try store.createNote(section: .notes, title: "Baseline", markdown: "keep")
        XCTAssertThrowsError(try store.createWikiPages([]))

        let good = GeneratedWikiPage(title: "First page", folders: ["Guides"], markdown: "first body")
        let traversal = GeneratedWikiPage(title: "Escape", folders: [".."], markdown: "must be rejected")
        XCTAssertThrowsError(try store.createWikiPages([good, traversal]))
        let emptyTitle = GeneratedWikiPage(title: " \n", folders: [], markdown: "must be rejected")
        XCTAssertThrowsError(try store.createWikiPages([good, emptyTitle]))
        let emptyMarkdown = GeneratedWikiPage(title: "No body", folders: [], markdown: " \n\t")
        XCTAssertThrowsError(try store.createWikiPages([good, emptyMarkdown]))
        XCTAssertEqual(store.notes.map(\.id), [baseline.id])
        XCTAssertTrue(store.folders.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "wiki/Guides/first-page.md").path))
        let reloaded = StillStore(rootURL: root, seedIfEmpty: false)
        XCTAssertEqual(reloaded.notes.map(\.id), [baseline.id])
    }

    @MainActor
    func testDuplicateGeneratedWikiTitleCreatesNewPageAndPreservesExistingContent() throws {
        let root = try temporaryWorkspace()
        defer { removeWorkspace(root) }
        let store = StillStore(rootURL: root, seedIfEmpty: false)
        let existing = try store.createNote(section: .wiki, title: "Topic", markdown: "existing body")

        let created = try store.createWikiPages([
            GeneratedWikiPage(title: "Topic", folders: [], markdown: "new body")
        ])

        XCTAssertEqual(created.count, 1)
        XCTAssertNotEqual(created[0].id, existing.id)
        XCTAssertNotEqual(created[0].title, existing.title)
        let reloaded = StillStore(rootURL: root, seedIfEmpty: false)
        XCTAssertEqual(reloaded.notes.first(where: { $0.id == existing.id })?.markdown, "existing body")
        XCTAssertEqual(reloaded.notes.first(where: { $0.id == created[0].id })?.markdown, "new body")
    }

    @MainActor
    func testAttachmentUsesGeneratedBasenameAndRejectsPathTraversalOnRead() throws {
        let root = try temporaryWorkspace()
        defer { removeWorkspace(root) }
        let store = StillStore(rootURL: root, seedIfEmpty: false)
        let png = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])

        let filename = try store.addImage(data: png, filename: "../../outside.png", mimeType: "image/png")

        XCTAssertEqual(filename, URL(fileURLWithPath: filename).lastPathComponent)
        XCTAssertFalse(filename.contains(".."))
        XCTAssertEqual(store.attachment(named: filename)?.0, png)
        XCTAssertEqual(store.attachment(named: filename)?.1, "image/png")
        XCTAssertNil(store.attachment(named: "../\(filename)"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("outside.png").path))
    }

    private func temporaryWorkspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("StillTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func removeWorkspace(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
