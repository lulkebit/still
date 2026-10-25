import AppKit
import SwiftUI
import XCTest
@testable import Still

@MainActor
final class ChatComposerTextViewTests: XCTestCase {
    func testReturnSubmitsAndShiftReturnKeepsNativeMultilineEditing() throws {
        let window = makeWindow()
        let view = SubmitAwareTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 120))
        view.allowsUndo = true
        view.string = "Frage"
        window.contentView?.addSubview(view)
        XCTAssertTrue(window.makeFirstResponder(view))
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))

        var submitCount = 0
        view.onSubmit = { submitCount += 1 }
        view.keyDown(with: keyEvent(keyCode: 36, characters: "\r", window: window))

        XCTAssertEqual(submitCount, 1)
        XCTAssertEqual(view.string, "Frage")

        view.keyDown(with: keyEvent(keyCode: 36, characters: "\r", modifiers: .shift, window: window))

        XCTAssertEqual(submitCount, 1)
        XCTAssertEqual(view.string, "Frage\n")
    }

    func testReturnDuringMarkedTextIsLeftToTheInputMethod() throws {
        let window = makeWindow()
        let view = SubmitAwareTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 120))
        view.allowsUndo = true
        window.contentView?.addSubview(view)
        XCTAssertTrue(window.makeFirstResponder(view))
        view.setMarkedText("漢", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(view.hasMarkedText())

        var submitCount = 0
        view.onSubmit = { submitCount += 1 }
        view.keyDown(with: keyEvent(keyCode: 36, characters: "\r", window: window))

        XCTAssertEqual(submitCount, 0)
    }

    func testMarkedCompositionUpdatesBindingAcrossRepresentableRefreshAndCommits() throws {
        let window = makeWindow()
        var draft = ""
        let conversationID = UUID()
        let binding = Binding<String>(get: { draft }, set: { draft = $0 })
        let composer = ChatComposerTextView(text: binding, contextID: conversationID, isEditable: true, onSubmit: {})
        let coordinator = ChatComposerTextView.Coordinator(composer)
        let view = SubmitAwareTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 120))
        view.allowsUndo = true
        view.draftContextID = conversationID
        window.contentView?.addSubview(view)
        XCTAssertTrue(window.makeFirstResponder(view))
        coordinator.textView = view
        coordinator.lastAppliedBinding = draft
        coordinator.pendingContextID = conversationID
        coordinator.pendingDraft = draft

        view.setMarkedText("漢", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view))

        XCTAssertEqual(draft, view.string)
        coordinator.updateDraft(for: view, draft: draft, contextID: conversationID)
        XCTAssertFalse(coordinator.pendingExternalReset)
        XCTAssertEqual(view.string, draft)

        view.unmarkText()
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view))
        XCTAssertEqual(draft, "漢")
        XCTAssertEqual(view.draftContextID, conversationID)
    }

    func testNativeUndoRemainsAvailableInTheComposer() throws {
        let window = makeWindow()
        let view = SubmitAwareTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 120))
        view.allowsUndo = true
        view.string = "Basis"
        window.contentView?.addSubview(view)
        XCTAssertTrue(window.makeFirstResponder(view))
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        view.insertText("!", replacementRange: NSRange(location: 5, length: 0))

        XCTAssertEqual(view.string, "Basis!")
        try XCTUnwrap(view.undoManager).undo()
        XCTAssertEqual(view.string, "Basis")
    }

    func testUndoHistoryIsClearedWhenConversationOrDraftChangesExternally() throws {
        let window = makeWindow()
        let view = SubmitAwareTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 120))
        view.allowsUndo = true
        window.contentView?.addSubview(view)
        XCTAssertTrue(window.makeFirstResponder(view))
        let firstConversation = UUID()
        let secondConversation = UUID()
        view.synchronizeDraft("Erster Entwurf", contextID: firstConversation)
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        view.insertText(" 🙂", replacementRange: NSRange(location: (view.string as NSString).length, length: 0))
        XCTAssertTrue(try XCTUnwrap(view.undoManager).canUndo)

        view.synchronizeDraft("Zweiter Entwurf", contextID: secondConversation)
        XCTAssertEqual(view.string, "Zweiter Entwurf")
        XCTAssertFalse(try XCTUnwrap(view.undoManager).canUndo)
        try XCTUnwrap(view.undoManager).undo()
        XCTAssertEqual(view.string, "Zweiter Entwurf")

        view.insertText("!", replacementRange: NSRange(location: (view.string as NSString).length, length: 0))
        view.synchronizeDraft("", contextID: secondConversation)
        XCTAssertEqual(view.string, "")
        XCTAssertFalse(try XCTUnwrap(view.undoManager).canUndo)
    }

    private func makeWindow() -> NSWindow {
        NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 160),
                 styleMask: .borderless, backing: .buffered, defer: false)
    }

    private func keyEvent(keyCode: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = [], window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown,
                         location: .zero,
                         modifierFlags: modifiers,
                         timestamp: 0,
                         windowNumber: window.windowNumber,
                         context: nil,
                         characters: characters,
                         charactersIgnoringModifiers: characters,
                         isARepeat: false,
                         keyCode: keyCode)!
    }
}
