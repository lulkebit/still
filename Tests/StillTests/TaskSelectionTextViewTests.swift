import AppKit
import XCTest
@testable import Still

@MainActor
final class TaskSelectionTextViewTests: XCTestCase {
    func testBusyPresentationCollapsesSelectionAndCleansTemporaryStylingAndIndicator() throws {
        let view = TaskSelectionTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        view.allowsUndo = true
        let content = "before selected text after"
        view.string = content
        let range = (content as NSString).range(of: "selected text")
        view.setSelectedRange(range)

        view.setAIBusy(true, selectionRange: range, sourceText: content, reduceMotion: true)

        XCTAssertTrue(view.isAIBusy)
        XCTAssertTrue(view.hasBusyIndicator)
        XCTAssertEqual(view.selectedRange(), NSRange(location: NSMaxRange(range), length: 0))
        let layoutManager = try XCTUnwrap(view.layoutManager)
        var effectiveRange = NSRange(location: 0, length: 0)
        XCTAssertNotNil(layoutManager.temporaryAttribute(.foregroundColor, atCharacterIndex: range.location, effectiveRange: &effectiveRange))
        XCTAssertNil(layoutManager.temporaryAttribute(.backgroundColor, atCharacterIndex: range.location, effectiveRange: &effectiveRange))

        view.setAIBusy(false, selectionRange: nil, sourceText: nil, reduceMotion: true)

        XCTAssertFalse(view.isAIBusy)
        XCTAssertFalse(view.hasBusyIndicator)
        XCTAssertNil(layoutManager.temporaryAttribute(.foregroundColor, atCharacterIndex: range.location, effectiveRange: &effectiveRange))
    }

    func testBusyStylingIsRemovedAcrossTheWholeTextAfterEditsBeforeOrInsideTheRange() throws {
        let edits = [
            (NSRange(location: 0, length: 0), "prefix "),
            (NSRange(location: 14, length: 3), "changed")
        ]

        for (editRange, replacement) in edits {
            let view = TaskSelectionTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
            let content = "before selected text after"
            view.string = content
            let selection = (content as NSString).range(of: "selected text")
            view.setAIBusy(true, selectionRange: selection, sourceText: content, reduceMotion: true)
            view.insertText(replacement, replacementRange: editRange)

            XCTAssertFalse(view.isAIBusy)
            let layoutManager = try XCTUnwrap(view.layoutManager)
            for index in 0..<(view.string as NSString).length {
                var effectiveRange = NSRange(location: 0, length: 0)
                XCTAssertNil(layoutManager.temporaryAttribute(.foregroundColor, atCharacterIndex: index, effectiveRange: &effectiveRange))
            }
            XCTAssertFalse(view.hasBusyIndicator)
        }
    }

    func testReplacementRevalidatesSnapshotAndPlacesCaretAfterReplacement() throws {
        let view = TaskSelectionTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        view.allowsUndo = true
        let content = "before 👩‍🚀 selected after"
        view.string = content
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView?.addSubview(view)
        window.makeFirstResponder(view)
        let undoManager = try XCTUnwrap(view.undoManager)
        let range = (content as NSString).range(of: "selected")
        let snapshot = TaskTextSelectionSnapshot(text: "selected", range: range)
        let replacement = "shorter 🙂"

        XCTAssertTrue(view.replace(replacement, for: snapshot))
        XCTAssertEqual(view.string, "before 👩‍🚀 shorter 🙂 after")
        XCTAssertEqual(view.selectedRange(), NSRange(location: range.location + (replacement as NSString).length, length: 0))
        XCTAssertTrue(undoManager.canUndo)
        undoManager.undo()
        XCTAssertEqual(view.string, content)
    }

    func testReplacementDoesNotApplyAfterTheSelectedSourceChanges() {
        let view = TaskSelectionTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        let content = "before selected after"
        let range = (content as NSString).range(of: "selected")
        view.string = "before edited after"
        let snapshot = TaskTextSelectionSnapshot(text: "selected", range: range)

        XCTAssertFalse(view.replace("replacement", for: snapshot))
        XCTAssertEqual(view.string, "before edited after")
    }
}
