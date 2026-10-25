import XCTest
@testable import Still

@MainActor
final class ChatViewPolicyTests: XCTestCase {
    func testChatSourcePolicyRespectsWikiPrivacyGateAndExternalLinkPolicy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("still-chat-source-policy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = StillAppModel(
            rootURL: root,
            keyStore: SnapshotMemoryCredentialStore(),
            confluenceKeys: { _ in SnapshotMemoryCredentialStore() }
        )
        let wikiNote = try model.store.createNote(section: .wiki, title: "Private wiki note")
        let localSource = ChatSource(id: "local:\(wikiNote.id.uuidString)", title: wikiNote.title, noteID: wikiNote.id)
        XCTAssertTrue(ChatLinkPolicy.canOpen(localSource, notes: model.store.visibleNotes, store: model.store))

        try model.store.updateFeatureSettings(wikiEnabled: false, confluenceSettings: .empty)

        XCTAssertFalse(ChatLinkPolicy.canOpen(localSource, notes: model.store.visibleNotes, store: model.store))
        XCTAssertEqual(ChatLinkPolicy.externalURL(URL(string: "https://example.com/path")!)?.scheme, "https")
        XCTAssertEqual(ChatLinkPolicy.externalURL(URL(string: "mailto:hello@example.com")!)?.scheme, "mailto")
        XCTAssertNil(ChatLinkPolicy.externalURL(URL(string: "file:///tmp/private")!))
        XCTAssertNil(ChatLinkPolicy.externalURL(URL(string: "https://user:secret@example.com")!))
    }

}

private final class SnapshotMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    func read() throws -> String? { "" }
    func write(_ value: String) throws {}
}
