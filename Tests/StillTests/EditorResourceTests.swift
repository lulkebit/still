import Foundation
import XCTest
@testable import Still

final class EditorResourceTests: XCTestCase {
    @MainActor
    func testBundledEditorHTMLHasItsScriptStylesheetAndNoticesAsSiblings() throws {
        let resolvedEditorHTMLURL = MarkdownEditor.editorHTMLURL
        let htmlURL = try XCTUnwrap(resolvedEditorHTMLURL)
        let editorDirectory = htmlURL.deletingLastPathComponent()
        XCTAssertTrue(htmlURL.isFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: htmlURL.path))

        for resource in ["editor.js", "editor.css", "THIRD_PARTY_NOTICES.txt"] {
            let sibling = editorDirectory.appendingPathComponent(resource)
            XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.path), "Missing editor resource: \(resource)")
        }

        let html = try String(contentsOf: htmlURL, encoding: .utf8)
        XCTAssertTrue(html.contains("editor.js"))
        XCTAssertTrue(html.contains("editor.css"))
        XCTAssertFalse(try String(contentsOf: editorDirectory.appendingPathComponent("THIRD_PARTY_NOTICES.txt"), encoding: .utf8).isEmpty)
    }
}
