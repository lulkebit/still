import AppKit
import Foundation
import XCTest
@testable import Still

final class SearchNavigationTests: XCTestCase {
    @MainActor
    func testTitleMatchesRankAheadOfContentAndBodySnippetAppearsAlongsideTitleMatch() throws {
        let root = try temporaryWorkspace()
        defer { removeWorkspace(root) }
        let store = StillStore(rootURL: root, seedIfEmpty: false)
        let contentMatch = try store.createNote(section: .notes, title: "Meeting archive",
                                                markdown: "## Summary\nThe meeting plan is ready for review.")
        let titleMatch = try store.createNote(section: .notes, title: "Meeting plan",
                                              markdown: "The plan is ready.")

        let hits = SearchIndex.results(query: "meeting plan", store: store)
        XCTAssertEqual(hits.first?.id, "note:\(titleMatch.id.uuidString)")
        let contentHit = try XCTUnwrap(hits.first(where: { $0.id == "note:\(contentMatch.id.uuidString)" }))
        XCTAssertTrue(contentHit.contentMatch)
        XCTAssertTrue(contentHit.snippet?.localizedCaseInsensitiveContains("meeting plan") == true)
    }

    @MainActor
    func testSearchMatchesTermsAcrossTitleAndContentAndShowsUnicodeSnippet() throws {
        let root = try temporaryWorkspace()
        defer { removeWorkspace(root) }
        let store = StillStore(rootURL: root, seedIfEmpty: false)
        let note = try store.createNote(section: .notes, title: "Meeting notes",
                                        markdown: "Agenda\n\nThe plan was approved in 東京.")

        let hits = SearchIndex.results(query: "meeting 東京", store: store)
        let hit = try XCTUnwrap(hits.first(where: { $0.id == "note:\(note.id.uuidString)" }))
        XCTAssertFalse(hit.contentMatch, "Find should open only when the full query appears contiguously in the note body.")
        XCTAssertTrue(hit.snippet?.contains("東京") == true)
        XCTAssertEqual(hit.findQuery, "東京")

        let clipped = SearchIndex.snippet(in: String(repeating: "猫🐈 ", count: 45) + "Café 東京", query: "cafe")
        XCTAssertTrue(clipped?.contains("Café") == true)
        XCTAssertLessThan(clipped?.count ?? .max, 150)
    }

    @MainActor
    func testFavoritesAndBoundedRecentsPersistAndWikiVisibilityDoesNotEraseThem() throws {
        let root = try temporaryWorkspace()
        defer { removeWorkspace(root) }
        let store = StillStore(rootURL: root, seedIfEmpty: false)
        let notes = try (0..<14).map { index in
            try store.createNote(section: .notes, title: "Note \(index)", markdown: "Body \(index)")
        }
        for note in notes { store.recordOpenedNote(note.id) }
        store.toggleFavoriteNote(notes[0].id)

        let wikiNote = try store.createNote(section: .wiki, title: "Wiki favorite", markdown: "Wiki body")
        store.toggleFavoriteNote(wikiNote.id)
        store.recordOpenedNote(wikiNote.id)
        XCTAssertEqual(store.recentNoteIDs.count, 12)
        XCTAssertEqual(store.recentNoteIDs.first, wikiNote.id)

        try store.updateFeatureSettings(wikiEnabled: false, confluenceSettings: .empty)
        XCTAssertFalse(store.favoriteNotes.contains(where: { $0.id == wikiNote.id }))
        XCTAssertFalse(store.recentNotes.contains(where: { $0.id == wikiNote.id }))
        XCTAssertTrue(store.favoriteNoteIDs.contains(wikiNote.id))
        XCTAssertTrue(store.recentNoteIDs.contains(wikiNote.id))

        let reloaded = StillStore(rootURL: root, seedIfEmpty: false)
        XCTAssertEqual(reloaded.favoriteNoteIDs, store.favoriteNoteIDs)
        XCTAssertEqual(reloaded.recentNoteIDs, store.recentNoteIDs)
        try reloaded.updateFeatureSettings(wikiEnabled: true, confluenceSettings: .empty)
        XCTAssertTrue(reloaded.favoriteNotes.contains(where: { $0.id == wikiNote.id }))
        XCTAssertTrue(reloaded.recentNotes.contains(where: { $0.id == wikiNote.id }))

        try reloaded.trashNote(id: notes[0].id)
        XCTAssertFalse(reloaded.favoriteNoteIDs.contains(notes[0].id))
        XCTAssertFalse(reloaded.recentNoteIDs.contains(notes[0].id))
    }

    @MainActor
    func testLegacyManifestDefaultsNavigationListsAndPrunesStaleIDs() throws {
        let root = try temporaryWorkspace()
        defer { removeWorkspace(root) }
        let store = StillStore(rootURL: root, seedIfEmpty: false)
        let note = try store.createNote(section: .notes, title: "Current", markdown: "Body")
        store.toggleFavoriteNote(note.id)
        store.recordOpenedNote(note.id)

        let manifestURL = root.appendingPathComponent("manifest.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        let staleID = UUID()
        object.removeValue(forKey: "favoriteNoteIDs")
        object.removeValue(forKey: "recentNoteIDs")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let legacyManifest = try JSONDecoder().decode(StoreManifest.self, from: legacyData)
        XCTAssertEqual(legacyManifest.favoriteNoteIDs, [])
        XCTAssertEqual(legacyManifest.recentNoteIDs, [])

        object["favoriteNoteIDs"] = [note.id.uuidString, staleID.uuidString]
        object["recentNoteIDs"] = [staleID.uuidString, note.id.uuidString]
        try JSONSerialization.data(withJSONObject: object).write(to: manifestURL)
        let reloaded = StillStore(rootURL: root, seedIfEmpty: false)
        XCTAssertEqual(reloaded.favoriteNoteIDs, [note.id])
        XCTAssertEqual(reloaded.recentNoteIDs, [note.id])
    }

    @MainActor
    func testAppKitFieldEditorRoutesArrowReturnAndEscapeCommands() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let field = NSTextField(frame: NSRect(x: 12, y: 20, width: 260, height: 24))
        let router = SearchFieldCommandCoordinator()
        var movements: [Int] = []
        var submitted = false
        var cancelled = false
        router.onMove = { movements.append($0) }
        router.onSubmit = { submitted = true }
        router.onCancel = { cancelled = true }
        field.delegate = router
        window.contentView?.addSubview(field)
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(field))
        field.selectText(nil)

        let fieldEditor = try XCTUnwrap(field.currentEditor())
        XCTAssertTrue(window.firstResponder === fieldEditor)
        sendKey(126, characters: "\u{F700}", window: window)
        sendKey(125, characters: "\u{F701}", window: window)
        sendKey(36, characters: "\r", window: window)
        sendKey(53, characters: "\u{1b}", window: window)
        XCTAssertEqual(movements, [-1, 1])
        XCTAssertTrue(submitted)
        XCTAssertTrue(cancelled)
    }

    @MainActor
    func testQuickOpenFocusCapturesOwnerKeepsFirstCharacterAndRestoresOnEscape() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }

        let previousField = NSTextField(frame: NSRect(x: 12, y: 20, width: 260, height: 24))
        previousField.stringValue = "previous note text"
        window.contentView?.addSubview(previousField)
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(previousField))
        previousField.selectText(nil)
        let previousEditor = try XCTUnwrap(previousField.currentEditor())
        XCTAssertTrue(previousEditor.isFieldEditor)
        XCTAssertTrue(window.firstResponder === previousEditor)

        let quickField = QuickOpenNativeTextField(frame: NSRect(x: 12, y: 58, width: 320, height: 24))
        let commandRouter = SearchFieldCommandCoordinator()
        commandRouter.recordInitialBindingText("")
        var cancelled = false
        quickField.onCancel = {
            cancelled = true
            quickField.cancelAndRestorePreviousResponder()
        }
        commandRouter.onCancel = quickField.onCancel
        quickField.delegate = commandRouter
        window.contentView?.addSubview(quickField)

        let quickEditor = try XCTUnwrap(quickField.currentEditor())
        XCTAssertTrue(quickEditor.isFieldEditor)
        XCTAssertTrue(window.firstResponder === quickEditor,
                      "Attaching Quick Open should transfer the real window field editor to its search field")
        sendKey(37, characters: "L", window: window)
        XCTAssertEqual(quickField.stringValue, "L", "The first typed character belongs to Quick Open")
        commandRouter.synchronizeBinding("", in: quickField)
        XCTAssertEqual(quickEditor.string, "L", "A stale SwiftUI value cannot overwrite the first character")
        commandRouter.synchronizeBinding("L", in: quickField)
        sendKey(14, characters: "e", window: window)
        commandRouter.synchronizeBinding("L", in: quickField)
        XCTAssertEqual(quickEditor.string, "Le", "A delayed binding update cannot discard newer text")
        commandRouter.synchronizeBinding("", in: quickField)
        XCTAssertEqual(quickEditor.string, "", "A changed binding still clears the active editor")
        XCTAssertEqual(quickField.stringValue, "")
        XCTAssertEqual(previousField.stringValue, "previous note text", "Quick Open typing leaves the previous field unchanged")

        sendKey(53, characters: "\u{1b}", window: window)
        XCTAssertTrue(cancelled)
        let restoredEditor = try XCTUnwrap(previousField.currentEditor())
        XCTAssertTrue(restoredEditor.isFieldEditor)
        XCTAssertTrue(window.firstResponder === restoredEditor,
                      "Escape should restore the previous field's editor, not window0")

        let sidebarField = SidebarSearchNativeTextField(frame: NSRect(x: 12, y: 20, width: 260, height: 24))
        let sidebarRouter = SearchFieldCommandCoordinator()
        sidebarRouter.recordInitialBindingText("")
        sidebarField.delegate = sidebarRouter
        sidebarField.setSearchFocus(true)
        window.contentView?.addSubview(sidebarField)
        let sidebarEditor = try XCTUnwrap(sidebarField.currentEditor())
        XCTAssertTrue(window.firstResponder === sidebarEditor,
                      "The sidebar search field should take focus synchronously when requested")
        sendKey(37, characters: "L", window: window)
        sidebarRouter.synchronizeBinding("", in: sidebarField)
        XCTAssertEqual(sidebarEditor.string, "L", "The first sidebar search character is retained")
        sidebarRouter.synchronizeBinding("L", in: sidebarField)
        sendKey(14, characters: "e", window: window)
        sidebarRouter.synchronizeBinding("L", in: sidebarField)
        XCTAssertEqual(sidebarEditor.string, "Le", "Stale binding values do not truncate sidebar input")
        sidebarRouter.synchronizeBinding("", in: sidebarField)
        XCTAssertEqual(sidebarEditor.string, "", "A programmatic sidebar clear updates its live editor")
        sidebarField.setSearchFocus(false)
        XCTAssertFalse(window.firstResponder === sidebarEditor)
    }

    @MainActor
    func testGlobalSearchNotificationTransfersFocusBeforeImmediateTyping() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let otherWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 100),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        otherWindow.isReleasedWhenClosed = false
        defer { window.close(); otherWindow.close() }
        let previousField = NSTextField(frame: NSRect(x: 12, y: 20, width: 260, height: 24))
        previousField.stringValue = "note body"
        let searchField = SidebarSearchNativeTextField(frame: NSRect(x: 12, y: 58, width: 260, height: 24))
        let otherSearchField = SidebarSearchNativeTextField(frame: searchField.frame)
        window.contentView?.addSubview(previousField)
        window.contentView?.addSubview(searchField)
        otherWindow.contentView?.addSubview(otherSearchField)
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(previousField))
        previousField.selectText(nil)
        // XCTest does not activate its windows, so direct the same native
        // notification to this window without depending on desktop activation.
        NotificationCenter.default.post(name: .stillFocusSearch, object: window)
        let searchEditor = try XCTUnwrap(searchField.currentEditor())
        XCTAssertTrue(window.firstResponder === searchEditor,
                      "The shortcut notification itself must move focus before returning")
        sendKey(37, characters: "L", modifiers: .shift, window: window)
        for character in "eserunde" { sendKey(0, characters: String(character), window: window) }
        XCTAssertEqual(searchField.stringValue, "Leserunde")
        XCTAssertEqual(previousField.stringValue, "note body")
        XCTAssertNil(otherSearchField.currentEditor(), "An inactive window must not respond to the global notification")

        XCTAssertTrue(window.makeFirstResponder(previousField))
        NotificationCenter.default.post(name: .stillFocusSearch, object: otherWindow)
        XCTAssertTrue(window.firstResponder === previousField.currentEditor(),
                      "A notification targeting another window cannot steal focus")
        searchField.removeFromSuperview()
        NotificationCenter.default.post(name: .stillFocusSearch, object: window)
        XCTAssertTrue(window.firstResponder === previousField.currentEditor(),
                      "A detached search field must no longer observe focus commands")
    }

    @MainActor
    func testGlobalSearchShortcutMovesNativeFocusBeforeReturningAndPreservesOtherShortcuts() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.setFrameAutosaveName(GlobalSearchShortcut.mainWindowFrameAutosaveName)
        let noteField = NSTextField(frame: NSRect(x: 12, y: 20, width: 260, height: 24))
        noteField.stringValue = "note body"
        let searchField = SidebarSearchNativeTextField(frame: NSRect(x: 12, y: 58, width: 260, height: 24))
        window.contentView?.addSubview(noteField)
        window.contentView?.addSubview(searchField)
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(noteField))
        noteField.selectText(nil)
        let shortcut = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command, .option],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3))
        XCTAssertTrue(GlobalSearchShortcut.handle(shortcut), "The shortcut is consumed synchronously")
        XCTAssertTrue(searchField.isEditing(in: window), "The native field editor must own focus before dispatch returns")
        sendKey(37, characters: "L", modifiers: .shift, window: window)
        XCTAssertEqual(searchField.stringValue, "L")
        XCTAssertEqual(noteField.stringValue, "note body")

        for modifiers: NSEvent.ModifierFlags in [[.command], [.command, .option, .shift], [.command, .option, .control]] {
            let unrelated = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3))
            XCTAssertFalse(GlobalSearchShortcut.handle(unrelated))
        }
        let sheet = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 80),
                            styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        window.beginSheet(sheet)
        XCTAssertFalse(GlobalSearchShortcut.handle(shortcut), "An attached sheet retains keyboard ownership")
        window.endSheet(sheet)
        sheet.close()
        window.setFrameAutosaveName("")
        XCTAssertFalse(GlobalSearchShortcut.handle(shortcut), "Other application windows retain their shortcuts")
    }

    @MainActor
    private func sendKey(_ keyCode: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = [], window: NSWindow) {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil,
                                           characters: characters, charactersIgnoringModifiers: characters,
                                           isARepeat: false, keyCode: keyCode) else {
            XCTFail("Could not create a synthetic key event.")
            return
        }
        window.sendEvent(event)
    }

    private func temporaryWorkspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("still-search-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func removeWorkspace(_ root: URL) {
        try? FileManager.default.removeItem(at: root)
    }
}
