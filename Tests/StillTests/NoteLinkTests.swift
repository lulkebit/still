import Foundation
import XCTest
@testable import Still

final class NoteLinkTests: XCTestCase {
    func testParserReadsAliasesAndUnicodeRangesAndSkipsCodeCommentsEscapesAndImages() {
        let markdown = #"""
        [[Märchen im Café|Über 東京]] and [[Plain]]
        `[[inline]]`
            [[indented]]
           	[[also indented]]
        ~~~md
        [[fenced]]
        ~~~
        <!-- [[comment]] -->
        \[[escaped]] and \\[[active]]
        ![an image [[imageAlt]]](image.png)
        """#

        let links = NoteLinks.links(in: markdown)
        XCTAssertEqual(links.map(\.target), ["Märchen im Café", "Plain", "active"])
        XCTAssertEqual(links.first?.label, "Über 東京")
        XCTAssertEqual(links.map { (markdown as NSString).substring(with: $0.range) },
                       ["[[Märchen im Café|Über 東京]]", "[[Plain]]", "[[active]]"])
        let unicodeLink = try! XCTUnwrap(links.first)
        XCTAssertEqual((markdown as NSString).substring(with: unicodeLink.targetRange), "Märchen im Café")
    }

    func testParserHandlesMultilineHtmlCommentsAndEscapedCodeDelimiter() {
        let markdown = #"""
        <!-- comment starts
        [[hidden]]
        -->
        \`literal` then [[shown]]
        """#

        XCTAssertEqual(NoteLinks.links(in: markdown).map(\.target), ["shown"])
    }

    func testParserSkipsMalformedEmptyTargetsWithoutBreakingFollowingLinks() {
        let markdown = "[[]] [[ ]] [[|alias]] [[Page|line one\nline two]] before [[Café]]"
        XCTAssertEqual(NoteLinks.links(in: markdown).map(\.target), ["Café"])
    }

    func testCanonicalTargetsEncodeDelimitersAndResolveUnicodeExactlyOnce() {
        let note = Note(title: "Be|ta [draft]]/100% ☕", section: .wiki,
                        folders: ["Folder | [draft] %"], markdown: "body")
        let source = Note(title: "Start")
        let target = NoteLinks.target(for: note)

        XCTAssertEqual(target, "wiki/Folder %7C %5Bdraft%5D %25/Be%7Cta %5Bdraft%5D%5D%2F100%25 ☕")
        XCTAssertEqual(NoteLinks.decodeComponent("%252F"), "%2F")
        let link = try! XCTUnwrap(NoteLinks.links(in: "[[\(target)|Visible label]]").first)
        XCTAssertEqual(link.label, "Visible label")
        XCTAssertEqual(NoteLinks.resolve(target: link.target, from: source, notes: [note])?.id, note.id)
        XCTAssertEqual(NoteLinks.resolve(target: "WIKI/FOLDER %7c %5bdraft%5d %25/be%7cta %5bdraft%5d%5d%2f100%25 ☕",
                                         from: source, notes: [note])?.id, note.id)
        XCTAssertNil(NoteLinks.resolve(target: "notes/../Escape", from: source, notes: [note]))
        XCTAssertNil(NoteLinks.resolve(target: "notes/Good/%0A", from: source, notes: [note]))
        XCTAssertNil(NoteLinks.destination(for: "wiki/%20Folder/Title", from: source))
        XCTAssertNil(NoteLinks.decodeComponent("bad%escape"))
    }

    func testQualifiedResolutionFoldsSectionFolderAndTitleCaseAndDiacritics() {
        let source = Note(title: "Start")
        let target = Note(title: "Café", section: .wiki, folders: ["Plants"])
        XCTAssertEqual(NoteLinks.resolve(target: "WIKI/PLANTS/cafe", from: source, notes: [target])?.id, target.id)
    }

    func testShortResolutionPrefersSameFolderThenSectionOnlyWhenUnique() {
        let source = Note(title: "Source", section: .notes, folders: ["Work"])
        let local = Note(title: "Topic", section: .notes, folders: ["Work"])
        let wiki = Note(title: "Topic", section: .wiki)
        XCTAssertEqual(NoteLinks.resolve(target: "topic", from: source, notes: [source, local, wiki])?.id, local.id)

        let sameSection = Note(title: "Plan", section: .notes, folders: ["Other"])
        let otherSection = Note(title: "Plan", section: .wiki)
        XCTAssertEqual(NoteLinks.resolve(target: "Plan", from: source, notes: [source, sameSection, otherSection])?.id, sameSection.id)

        let duplicateOne = Note(title: "Plan", section: .notes, folders: ["A"])
        let duplicateTwo = Note(title: "Plan", section: .notes, folders: ["B"])
        XCTAssertNil(NoteLinks.resolve(target: "Plan", from: source, notes: [duplicateOne, duplicateTwo, otherSection]))
    }

    @MainActor
    func testStoreResolvesQualifiedCrossSectionLinksAndDeduplicatesBacklinks() throws {
        let root = try temporaryWorkspace()
        defer { removeWorkspace(root) }
        let store = StillStore(rootURL: root, seedIfEmpty: false)
        let target = try store.createNote(section: .wiki, folders: ["Guides"], title: "Café", markdown: "Self: [[Café]]")
        let targetPath = NoteLinks.target(for: target)
        let source = try store.createNote(section: .notes, title: "Start",
                                          markdown: "[[\(targetPath)|Guide]] and [[Café]] and [[\(targetPath)]]")

        XCTAssertEqual(store.resolveWikiLink(targetPath, from: source)?.id, target.id)
        XCTAssertEqual(store.resolveWikiLink("Café", from: source)?.id, target.id)
        XCTAssertEqual(store.backlinks(to: target).map(\.id), [source.id])
    }

    @MainActor
    func testRenameAndFolderMoveRewriteIncomingTargetsAndSurviveReload() throws {
        let root = try temporaryWorkspace()
        defer { removeWorkspace(root) }
        let store = StillStore(rootURL: root, seedIfEmpty: false)
        let target = try store.createNote(section: .wiki, folders: ["Guides"], title: "Old Guide", markdown: "guide")
        let source = try store.createNote(section: .notes, title: "Start",
                                          markdown: "Read [[\(NoteLinks.target(for: target))|the guide]]")

        try store.renameNote(id: target.id, title: "New Guide")
        var changedSource = try XCTUnwrap(store.notes.first(where: { $0.id == source.id }))
        XCTAssertEqual(changedSource.markdown, "Read [[wiki/Guides/New Guide|the guide]]")
        let folder = try XCTUnwrap(store.folders.first(where: { $0.section == .wiki && $0.path == ["Guides"] }))
        try store.renameFolder(folder, name: "Handbooks")
        changedSource = try XCTUnwrap(store.notes.first(where: { $0.id == source.id }))
        XCTAssertEqual(changedSource.markdown, "Read [[wiki/Handbooks/New Guide|the guide]]")

        let reloaded = StillStore(rootURL: root, seedIfEmpty: false)
        let persistedTarget = try XCTUnwrap(reloaded.notes.first(where: { $0.id == target.id }))
        let persistedSource = try XCTUnwrap(reloaded.notes.first(where: { $0.id == source.id }))
        XCTAssertEqual(reloaded.resolveWikiLink(NoteLinks.links(in: persistedSource.markdown)[0].target, from: persistedSource)?.id,
                       persistedTarget.id)
    }

    @MainActor
    func testMovingLinkSourcePreservesThePreviouslyResolvedTargetAfterReload() throws {
        let root = try temporaryWorkspace()
        defer { removeWorkspace(root) }
        let store = StillStore(rootURL: root, seedIfEmpty: false)
        let source = try store.createNote(section: .notes, folders: ["Work"], title: "Start", markdown: "See [[Topic|the topic]]")
        let intended = try store.createNote(section: .notes, folders: ["Work"], title: "Topic", markdown: "work topic")
        _ = try store.createNote(section: .notes, folders: ["Archive"], title: "Topic", markdown: "archive topic")
        XCTAssertEqual(store.resolveWikiLink("Topic", from: source)?.id, intended.id)

        try store.moveNote(id: source.id, section: .notes, folders: ["Archive"])
        let movedSource = try XCTUnwrap(store.notes.first(where: { $0.id == source.id }))
        XCTAssertEqual(movedSource.markdown, "See [[notes/Work/Topic|the topic]]")
        let reloaded = StillStore(rootURL: root, seedIfEmpty: false)
        let persistedSource = try XCTUnwrap(reloaded.notes.first(where: { $0.id == source.id }))
        XCTAssertEqual(reloaded.resolveWikiLink(NoteLinks.links(in: persistedSource.markdown)[0].target, from: persistedSource)?.id,
                       intended.id)
    }

    @MainActor
    func testMissingLinkedNotesUseQualifiedOrSourceLocationAndRejectUnsafeOrAmbiguousTargets() throws {
        let root = try temporaryWorkspace()
        defer { removeWorkspace(root) }
        let store = StillStore(rootURL: root, seedIfEmpty: false)
        let source = try store.createNote(section: .wiki, folders: ["Guides"], title: "Start")
        let qualified = try store.createLinkedNote(target: "notes/Reference/New Page", from: source)
        XCTAssertEqual(qualified.section, .notes)
        XCTAssertEqual(qualified.folders, ["Reference"])
        XCTAssertEqual(qualified.title, "New Page")

        let local = try store.createLinkedNote(target: "Unwritten", from: source)
        XCTAssertEqual(local.section, .wiki)
        XCTAssertEqual(local.folders, ["Guides"])
        XCTAssertEqual(try store.createLinkedNote(target: "Unwritten", from: source).id, local.id)

        XCTAssertThrowsError(try store.createLinkedNote(target: "wiki/../Escape", from: source))
        _ = try store.createNote(section: .notes, folders: ["Elsewhere"], title: "Duplicate")
        _ = try store.createNote(section: .notes, folders: ["Archive"], title: "Duplicate")
        XCTAssertThrowsError(try store.createLinkedNote(target: "Duplicate", from: source))
        XCTAssertEqual(store.notes.filter { $0.title == "Duplicate" }.count, 2)
    }

    @MainActor
    func testRelocationFailureRestoresRewrittenSourceAndRemovesNewTargetFile() throws {
        let root = try temporaryWorkspace()
        defer { removeWorkspace(root) }
        let store = StillStore(rootURL: root, seedIfEmpty: false)
        let target = try store.createNote(section: .wiki, title: "Old", markdown: "target body")
        let source = try store.createNote(section: .notes, title: "Start",
                                          markdown: "[[\(NoteLinks.target(for: target))|alias]]")
        let oldSourcePath = root.appending(path: PathSafety.safeRelativeMarkdownPath(section: source.section, folders: source.folders, title: source.title))
        let oldTargetPath = root.appending(path: PathSafety.safeRelativeMarkdownPath(section: target.section, folders: target.folders, title: target.title))
        let manifestPath = root.appendingPathComponent("manifest.json")
        let manifestBytes = try Data(contentsOf: manifestPath)

        try FileManager.default.removeItem(at: manifestPath)
        try FileManager.default.createDirectory(at: manifestPath, withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.renameNote(id: target.id, title: "New"))
        try FileManager.default.removeItem(at: manifestPath)
        try manifestBytes.write(to: manifestPath)

        XCTAssertEqual(try String(contentsOf: oldSourcePath, encoding: .utf8), source.markdown)
        XCTAssertEqual(try String(contentsOf: oldTargetPath, encoding: .utf8), target.markdown)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "wiki/new.md").path))
        let reloaded = StillStore(rootURL: root, seedIfEmpty: false)
        XCTAssertNil(reloaded.loadError)
        XCTAssertEqual(reloaded.notes.first(where: { $0.id == source.id })?.markdown, source.markdown)
    }

    @MainActor
    func testBacklinksRefreshForBodyCatalogAmbiguityAndRelocationChanges() throws {
        let root = try temporaryWorkspace()
        defer { removeWorkspace(root) }
        let store = StillStore(rootURL: root, seedIfEmpty: false)
        let target = try store.createNote(section: .wiki, folders: ["A"], title: "Topic")
        let source = try store.createNote(section: .notes, title: "Start", markdown: "[[Topic]]")
        XCTAssertEqual(store.backlinks(to: target).map(\.id), [source.id])
        store.updateMarkdown(id: target.id, markdown: "Typing into the target keeps incoming links")
        XCTAssertEqual(store.backlinks(to: target).map(\.id), [source.id])
        let duplicate = try store.createNote(section: .wiki, folders: ["B"], title: "Topic")
        XCTAssertTrue(store.backlinks(to: target).isEmpty)
        try store.trashNote(id: duplicate.id)
        XCTAssertEqual(store.backlinks(to: target).map(\.id), [source.id])
        store.updateMarkdown(id: source.id, markdown: "No link now")
        XCTAssertTrue(store.backlinks(to: target).isEmpty)
        store.updateMarkdown(id: source.id, markdown: "[[wiki/A/Topic|restored link]]")
        XCTAssertEqual(store.backlinks(to: target).map(\.id), [source.id])
        try store.renameNote(id: target.id, title: "Renamed")
        let renamed = try XCTUnwrap(store.notes.first(where: { $0.id == target.id }))
        XCTAssertEqual(store.backlinks(to: renamed).map(\.id), [source.id])
        try store.moveNote(id: source.id, section: .wiki, folders: ["Moved"])
        XCTAssertEqual(store.backlinks(to: renamed).map(\.id), [source.id])
        try store.trashNote(id: source.id)
        XCTAssertTrue(store.backlinks(to: renamed).isEmpty)
        try store.restoreTrashItem(id: source.id)
        XCTAssertEqual(store.backlinks(to: renamed).map(\.id), [source.id])
    }

    private func temporaryWorkspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("StillNoteLinkTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func removeWorkspace(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
