import Foundation
import XCTest
@testable import Still

final class ChatBackendTests: XCTestCase {
    func testFragmentedStreamingToolCallsKeepIndicesIDsAndArguments() throws {
        var parser = ChatStreamParser()
        _ = try parser.consume(#"{"choices":[{"index":0,"delta":{"content":"Ich prüfe. ","tool_calls":[{"index":1,"id":"second","type":"function","function":{"name":"local_","arguments":"{\"note"}},{"index":0,"id":"first","function":{"name":"local_search","arguments":"{\"query\":"}}]}}]}"#)
        _ = try parser.consume(#"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"Plan\"}"}},{"index":1,"function":{"name":"read","arguments":"ID\":\"00000000-0000-0000-0000-000000000000\"}"}}]},"finish_reason":"tool_calls"}]}"#)
        let result = try parser.result()
        XCTAssertEqual(result.content, "Ich prüfe. ")
        XCTAssertEqual(result.toolCalls.map(\.id), ["first", "second"])
        XCTAssertEqual(try ChatCoordinator.argument(result.toolCalls[0]), "Plan")
        XCTAssertEqual(try ChatCoordinator.argument(result.toolCalls[1]), "00000000-0000-0000-0000-000000000000")
    }

    func testTruncatedStreamAndInvalidToolPayloadsAreRejected() throws {
        var parser = ChatStreamParser()
        _ = try parser.consume(#"{"choices":[{"delta":{"content":"Teil"}}]}"#)
        XCTAssertThrowsError(try parser.result())
        _ = try parser.consume(#"{"choices":[{"delta":{},"finish_reason":"length"}]}"#)
        XCTAssertThrowsError(try parser.result())
        for (name, argument) in [("local_read", #"{"noteID":"../../secrets"}"#), ("confluence_get_page", #"{"pageID":"12/../user"}"#),
                                 ("local_search", #"{"query":"a","extra":"b"}"#), ("shell", #"{"query":"a"}"#)] {
            XCTAssertThrowsError(try ChatCoordinator.argument(ChatToolCall(id: "x", function: .init(name: name, arguments: argument))))
        }
    }

    func testConfluenceBoundariesCQLAndStructuredHTML() throws {
        let instance = try ConfluenceInstance("https://WIKI.example:443/confluence/")
        XCTAssertEqual(instance.keychainAccount, "https://wiki.example/confluence")
        XCTAssertEqual(instance.endpoint("user/current").path, "/confluence/rest/api/user/current")
        XCTAssertFalse(instance.contains(URL(string: "https://elsewhere.example/confluence/pages/1")!))
        XCTAssertFalse(instance.contains(URL(string: "https://wiki.example/confluence-other/1")!))
        let page = instance.pageURL(id: "123", webUI: "https://evil.example/steal")
        XCTAssertEqual(page.host, "wiki.example")
        XCTAssertEqual(page.path, "/confluence/pages/viewpage.action")
        for invalid in ["http://wiki.example", "https://user:secret@wiki.example", "https://wiki.example?pat=secret", "file:///tmp"] {
            XCTAssertThrowsError(try ConfluenceInstance(invalid))
        }
        XCTAssertEqual(ConfluenceClient.escapedCQL("a\" OR type=\"user\\"), "a\\\" OR type=\\\"user\\\\")
        let text = try ConfluenceClient.readableHTML("<h1>Titel</h1><p>Text &amp; mehr</p><ul><li>Eins</li><li>Zwei</li></ul><table><tr><td>A</td><td>B</td></tr></table><script>geheim()</script>")
        XCTAssertTrue(text.contains("Titel\n")); XCTAssertTrue(text.contains("Text & mehr")); XCTAssertTrue(text.contains("• Eins")); XCTAssertTrue(text.contains("A | B |"))
        XCTAssertFalse(text.contains("geheim"))
        XCTAssertEqual(try ConfluenceClient.readableHTML("<p>" + String(repeating: "a", count: 30_000) + "</p>").count, 18_000)
    }

    func testConfluenceCurrentUserRequiresAuthenticationAndKeepsContextPath() async throws {
        let recorder = BackendRequestRecorder()
        let session = backendSession()
        defer { session.invalidateAndCancel(); BackendURLProtocol.reset() }
        BackendURLProtocol.set { request in
            recorder.append(request)
            return (200, [:], Data(#"{"type":"anonymous","displayName":"Anonymous"}"#.utf8))
        }
        let client = try ConfluenceClient(baseURL: "https://wiki.example/confluence", pat: "test-pat", session: session)
        do { try await client.testConnection(); XCTFail("anonymous is not authenticated") }
        catch ConfluenceError.unauthenticated {}
        BackendURLProtocol.set { request in
            recorder.append(request)
            return (200, [:], Data(#"{"type":"known","username":"testuser","userKey":"123"}"#.utf8))
        }
        try await client.testConnection()
        XCTAssertEqual(recorder.requests.last?.url?.path, "/confluence/rest/api/user/current")
        XCTAssertEqual(recorder.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer test-pat")
    }

    func testRealInProcessMCPInitializeDiscoverAndCall() async throws {
        let recorder = BackendRequestRecorder()
        let session = backendSession()
        defer { session.invalidateAndCancel(); BackendURLProtocol.reset() }
        BackendURLProtocol.set { request in
            recorder.append(request)
            if request.url?.path.hasSuffix("content/search") == true {
                return (200, [:], Data(#"{"results":[{"id":"42","type":"page","status":"current","title":"Wissen","_links":{"webui":"/confluence/pages/42"}}]}"#.utf8))
            }
            return (200, [:], Data(#"{"id":"42","type":"page","status":"current","title":"Wissen","_links":{"webui":"https://evil.example/redirect"},"body":{"view":{"value":"<h2>Abschnitt</h2><p>Beleg</p>"}}}"#.utf8))
        }
        let mcp = ConfluenceMCP(session: session)
        let settings = ConfluenceSettings(enabled: true, baseURL: "https://wiki.example/confluence")
        try await mcp.connect(settings: settings, pat: "mcp-pat", isEnabled: { true })
        let search = try await mcp.call(name: "confluence_search", argument: "x\" OR type=user")
        let found = try JSONDecoder().decode([ConfluencePage].self, from: Data(search.utf8))
        XCTAssertEqual(found.map(\.id), ["42"])
        XCTAssertNil(found.first?.text)
        let raw = try await mcp.call(name: "confluence_get_page", argument: "42")
        let page = try JSONDecoder().decode(ConfluencePage.self, from: Data(raw.utf8))
        XCTAssertTrue(page.text?.contains("Beleg") == true)
        XCTAssertEqual(page.url.host, "wiki.example")
        XCTAssertTrue(recorder.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer mcp-pat" && $0.url?.host == "wiki.example" })
        let cql = URLComponents(url: try XCTUnwrap(recorder.requests.first?.url), resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "cql" })?.value
        XCTAssertEqual(cql, "type = page AND status = current AND text ~ \"x\\\" OR type=user\" ORDER BY lastmodified DESC")
        await mcp.invalidate()
        do { _ = try await mcp.call(name: "confluence_get_page", argument: "42"); XCTFail("invalidated MCP must stop") }
        catch ChatError.toolUnavailable {}
    }

    func testURLSessionSSEHandlesContentAndFunctionFragments() async throws {
        let session = backendSession()
        defer { session.invalidateAndCancel(); BackendURLProtocol.reset() }
        let sse = """
        : keepalive

        data: {"choices":[{"delta":{"content":"Hallo 🌱"}}]}

        data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

        data: [DONE]

        """
        BackendURLProtocol.set { _ in (200, ["Content-Type": "text/event-stream"], Data(sse.utf8)) }
        let result = try await AIChatClient(session: session).complete(messages: [.init(role: "user", content: "Hallo")], tools: [], settings: .init(baseURL: "https://ai.example", model: "manual", enabled: true), apiKey: "", stream: true, onDelta: { _ in })
        XCTAssertEqual(result.content, "Hallo 🌱")
        BackendURLProtocol.set { _ in (400, ["Content-Type": "application/json"], Data(#"{"error":{"message":"stream is not supported"}}"#.utf8)) }
        do {
            _ = try await AIChatClient(session: session).complete(messages: [], tools: [], settings: .init(baseURL: "https://ai.example", model: "manual", enabled: true), apiKey: "", stream: true, onDelta: { _ in })
            XCTFail("explicit capability error")
        } catch ChatError.unsupportedStreaming {}
        BackendURLProtocol.set { _ in (429, [:], Data(#"{"error":{"message":"tools unsupported rate limit"}}"#.utf8)) }
        do {
            _ = try await AIChatClient(session: session).complete(messages: [], tools: [], settings: .init(baseURL: "https://ai.example", model: "manual", enabled: true), apiKey: "", stream: true, onDelta: { _ in })
            XCTFail("rate limit is not a capability fallback")
        } catch AIClientError.httpStatus(429) {}
    }
}

@MainActor final class ChatCoordinatorTests: XCTestCase {
    private var root: URL!
    override func setUp() async throws { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func setup(_ client: any AIChatServing) throws -> (StillStore, ChatStore, ChatCoordinator) {
        let store = StillStore(rootURL: root, seedIfEmpty: false)
        try store.updateSettings(.init(baseURL: "https://ai.example", model: "chosen-model", enabled: true))
        let chats = ChatStore(rootURL: root)
        let coordinator = ChatCoordinator(store: store, chatStore: chats, client: client)
        return (store, chats, coordinator)
    }

    private func finished(_ coordinator: ChatCoordinator) async throws {
        for _ in 0..<300 {
            if !coordinator.isRunning { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("generation did not finish")
    }

    func testPersistenceRecoversPendingAndProtectsCorruptFile() throws {
        let chats = ChatStore(rootURL: root)
        let conversation = try chats.create(title: "Gespräch")
        let noteID = UUID()
        let source = ChatSource(id: "local:\(noteID)", title: "Notiz", noteID: noteID)
        try chats.update(conversation.id, persist: false) { $0.messages.append(.init(role: .assistant, content: "Teil", sources: [source], status: .pending)) }
        chats.flushPendingWrites()
        let reopened = ChatStore(rootURL: root)
        XCTAssertEqual(reopened.conversations.first?.messages.first?.status, .interrupted)
        XCTAssertEqual(reopened.conversations.first?.messages.first?.sources, [source])
        try reopened.rename(conversation.id, title: "Neu")
        XCTAssertEqual(ChatStore(rootURL: root).conversations.first?.title, "Neu")
        try reopened.delete(conversation.id)
        XCTAssertTrue(ChatStore(rootURL: root).conversations.isEmpty)
        let file = root.appendingPathComponent("conversations.json")
        let corrupt = Data("not json".utf8)
        try corrupt.write(to: file)
        let broken = ChatStore(rootURL: root)
        XCTAssertNotNil(broken.errorMessage)
        XCTAssertThrowsError(try broken.create())
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
    }

    func testWholeTurnHistoryNeverStartsWithOrphanAssistant() {
        let messages = [ChatMessage(role: .assistant, content: "orphan"), .init(role: .user, content: "12345"), .init(role: .assistant, content: "67890"),
                        .init(role: .user, content: "last"), .init(role: .assistant, content: "answer")]
        let history = ChatCoordinator.boundedHistory(messages, limit: 12)
        XCTAssertEqual(history.map(\.content), ["last", "answer"])
        XCTAssertEqual(history.map(\.role), ["user", "assistant"])
    }

    func testSourceRecordedOnlyAfterReadAndToolIDsArePreserved() async throws {
        let client = ScriptedChatClient(steps: [.tool("local_search", #"{"query":"Evidence"}"#), .tool("local_read", "PLACEHOLDER"), .text("Antwort")])
        let (store, chats, coordinator) = try setup(client)
        let note = try store.createNote(section: .notes, title: "Evidence", markdown: String(repeating: "Beleg ", count: 5_000))
        await client.replaceArguments(at: 1, with: "{\"noteID\":\"\(note.id.uuidString)\"}")
        coordinator.draft = "Frage"; coordinator.send()
        try await finished(coordinator)
        let answer = try XCTUnwrap(chats.conversations.first?.messages.last)
        XCTAssertEqual(answer.status, .complete)
        XCTAssertEqual(answer.sources.map(\.noteID), [note.id])
        let calls = await client.captures
        XCTAssertTrue(calls.allSatisfy { $0.settings.model == "chosen-model" })
        XCTAssertEqual(calls[1].messages.last?.role, "tool")
        XCTAssertEqual(calls[1].messages.last?.tool_call_id, "call-0")
        let toolContent = calls.last!.messages.filter { $0.role == "tool" }.compactMap(\.content)
        XCTAssertLessThanOrEqual(toolContent.reduce(0) { $0 + $1.count }, 18_000)
        let bytes = try String(contentsOf: root.appendingPathComponent("conversations.json"), encoding: .utf8)
        XCTAssertFalse(bytes.contains("tool_calls")); XCTAssertFalse(bytes.contains(String(repeating: "Beleg ", count: 100)))
    }

    func testCurrentNoteScopeGuardsSearchAndRejectsOutOfScopeLocalRead() async throws {
        let client = ScriptedChatClient(steps: [
            .tool("local_search", #"{"query":"Allowed"}"#),
            .tool("local_read", "PLACEHOLDER"),
            .text("Antwort ohne Zugriff auf die andere Notiz")
        ])
        let (store, chats, coordinator) = try setup(client)
        let allowed = try store.createNote(section: .notes, title: "Allowed source", markdown: "Allowed body")
        let outside = try store.createNote(section: .notes, title: "Outside source", markdown: "OUT_OF_SCOPE_PRIVATE_SENTINEL")
        await client.replaceArguments(at: 1, with: "{\"noteID\":\"\(outside.id.uuidString)\"}")

        coordinator.draft = "Fasse die aktuelle Notiz zusammen"
        coordinator.send(context: ChatRequestContext(localScope: .currentNote,
                                                     anchorNoteID: allowed.id,
                                                     includeConfluence: false))
        try await finished(coordinator)

        let answer = try XCTUnwrap(chats.conversations.first?.messages.last)
        XCTAssertEqual(answer.status, .complete)
        XCTAssertTrue(answer.sources.isEmpty, "An out-of-scope read must not be recorded as a source")
        let calls = await client.captures
        XCTAssertEqual(calls.first?.tools.count, 2)
        XCTAssertTrue(calls.first?.messages.first?.content?.contains(allowed.id.uuidString) == true)
        XCTAssertTrue(calls.first?.messages.first?.content?.contains(allowed.title) == true)
        XCTAssertFalse(calls.first?.messages.first?.content?.contains(outside.id.uuidString) == true)
        XCTAssertFalse(calls.first?.messages.first?.content?.contains(outside.title) == true)
        XCTAssertTrue(calls[1].messages.last?.content?.contains(allowed.title) == true)
        XCTAssertFalse(calls[1].messages.last?.content?.contains(outside.title) == true)
        XCTAssertFalse(calls[2].messages.last?.content?.contains("OUT_OF_SCOPE_PRIVATE_SENTINEL") == true)
    }

    func testSearchOnlyHasNoSourcesAndHiddenWikiCannotBeRead() async throws {
        let client = ScriptedChatClient(steps: [.tool("local_search", #"{"query":"Hidden"}"#), .text("Keine Quelle")])
        let (store, chats, coordinator) = try setup(client)
        _ = try store.createNote(section: .wiki, title: "Hidden", markdown: "Private Wiki")
        try store.updateFeatureSettings(wikiEnabled: false, confluenceSettings: .empty)
        // Configuration observations settle before a new request starts.
        await Task.yield()
        coordinator.draft = "Frage"; coordinator.send(); try await finished(coordinator)
        XCTAssertEqual(chats.conversations.first?.messages.last?.sources, [])
        let calls = await client.captures
        XCTAssertFalse(calls.last?.messages.last?.content?.contains("Hidden") == true)
    }

    func testExplicitCapabilityFallbackKeepsModelAndDoesNotDuplicateUser() async throws {
        let client = ScriptedChatClient(steps: [.failure(.unsupportedStreaming), .failure(.unsupportedTools), .text("Ohne Werkzeuge")])
        let (_, chats, coordinator) = try setup(client)
        coordinator.draft = "Frage"; coordinator.send(); try await finished(coordinator)
        let calls = await client.captures
        XCTAssertEqual(calls.map(\.stream), [true, false, false])
        XCTAssertEqual(calls.map { $0.tools.count }, [2, 2, 0])
        XCTAssertTrue(calls.allSatisfy { $0.settings.model == "chosen-model" })
        XCTAssertEqual(chats.conversations.first?.messages.filter { $0.role == .user }.count, 1)
        XCTAssertTrue(coordinator.notice?.contains("keine Werkzeuge") == true)
    }

    func testCancelKeepsPartialNavigationDoesNotStopAndRetryKeepsOneQuestion() async throws {
        let client = ScriptedChatClient(steps: [.delayed("Teil"), .text("Erneut")])
        let (_, chats, coordinator) = try setup(client)
        coordinator.draft = "Frage"; coordinator.send()
        let first = try XCTUnwrap(coordinator.selectedConversationID)
        for _ in 0..<100 {
            if chats.conversation(first)?.messages.last?.content == "Teil" { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        coordinator.newConversation()
        XCTAssertTrue(coordinator.isRunning)
        coordinator.selectConversation(first)
        coordinator.cancel()
        XCTAssertEqual(chats.conversation(first)?.messages.last?.content, "Teil")
        XCTAssertEqual(chats.conversation(first)?.messages.last?.status, .interrupted)
        coordinator.retry(); try await finished(coordinator)
        XCTAssertEqual(chats.conversation(first)?.messages.filter { $0.role == .user }.count, 1)
        XCTAssertEqual(chats.conversation(first)?.messages.last?.content, "Erneut")
    }

    func testSixToolRoundsAndConfigChangeStopStaleResponses() async throws {
        let client = ScriptedChatClient(steps: Array(repeating: .tool("local_search", #"{"query":"none"}"#), count: 7))
        let (_, chats, coordinator) = try setup(client)
        coordinator.draft = "Frage"; coordinator.send(); try await finished(coordinator)
        XCTAssertEqual(chats.conversations.first?.messages.last?.status, .failed)
        XCTAssertTrue(chats.conversations.first?.messages.last?.error?.contains("sechs") == true)
        let captures = await client.captures
        XCTAssertEqual(captures.count, 7)
        let delayed = ScriptedChatClient(steps: [.delayed("Alt")])
        let store2 = StillStore(rootURL: root.appendingPathComponent("second"), seedIfEmpty: false)
        try store2.updateSettings(.init(baseURL: "https://ai.example", model: "m", enabled: true))
        let chats2 = ChatStore(rootURL: store2.rootURL)
        let coordinator2 = ChatCoordinator(store: store2, chatStore: chats2, client: delayed)
        coordinator2.draft = "Frage"; coordinator2.send()
        try await Task.sleep(for: .milliseconds(20))
        try store2.updateSettings(.empty)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(coordinator2.isRunning)
        XCTAssertEqual(chats2.conversations.first?.messages.last?.status, .interrupted)
    }

    func testSettingsSaveImmediatelyFollowedByNewTurnDoesNotCancelNewRequest() async throws {
        let client = ScriptedChatClient(steps: [.text("Neue Antwort")])
        let api = MemoryCredentialStore("")
        let app = StillAppModel(rootURL: root, keyStore: api, confluenceKeys: { _ in MemoryCredentialStore("") }, chatClient: client)
        try app.saveSettings(ai: .init(baseURL: "https://ai.example", model: "chosen", enabled: true), apiKey: "", wikiEnabled: false, confluence: .empty, pat: "")
        app.chat.draft = "Neue Frage"
        app.chat.send()
        try await finished(app.chat)
        XCTAssertEqual(app.chat.activeConversation?.messages.last?.status, .complete)
        XCTAssertEqual(app.chat.activeConversation?.messages.last?.content, "Neue Antwort")
    }

    func testDeletingRunningConversationAndRememberingDrafts() async throws {
        let client = ScriptedChatClient(steps: [.delayed("Teil")])
        let (_, chats, coordinator) = try setup(client)
        coordinator.newConversation()
        let first = try XCTUnwrap(coordinator.selectedConversationID)
        coordinator.draft = "Entwurf A"
        coordinator.newConversation()
        let second = try XCTUnwrap(coordinator.selectedConversationID)
        coordinator.draft = "Entwurf B"
        coordinator.selectConversation(first)
        XCTAssertEqual(coordinator.draft, "Entwurf A")
        coordinator.selectConversation(second)
        XCTAssertEqual(coordinator.draft, "Entwurf B")
        coordinator.send()
        XCTAssertTrue(coordinator.isRunning)
        coordinator.deleteConversation(second)
        XCTAssertFalse(coordinator.isRunning)
        XCTAssertNil(chats.conversation(second))
        XCTAssertEqual(coordinator.selectedConversationID, first)
        XCTAssertEqual(coordinator.draft, "Entwurf A")
    }

    func testSettingsUseInjectedCredentialsAndAllowDisabledIncompleteConfluence() throws {
        let api = MemoryCredentialStore("old")
        let pat = MemoryCredentialStore("saved")
        let app = StillAppModel(rootURL: root, keyStore: api, confluenceKeys: { _ in pat })
        try app.saveSettings(ai: .empty, apiKey: "new", wikiEnabled: false,
                             confluence: .init(enabled: false, baseURL: "unfinished"), pat: "")
        XCTAssertFalse(app.store.wikiEnabled)
        XCTAssertEqual(try api.read(), "new")
        XCTAssertEqual(try pat.read(), "saved")
        api.failWrites = true
        XCTAssertThrowsError(try app.saveSettings(ai: .empty, apiKey: "failed", wikiEnabled: true, confluence: .empty, pat: ""))
        XCTAssertFalse(app.store.wikiEnabled)
    }
}

private struct BackendCapture: Sendable { var messages: [ChatWireMessage]; var tools: [ChatToolDefinition]; var settings: AISettings; var stream: Bool }
private actor ScriptedChatClient: AIChatServing {
    enum Step: Sendable { case text(String), tool(String, String), failure(ChatError), delayed(String) }
    var steps: [Step]
    private(set) var captures: [BackendCapture] = []
    init(steps: [Step]) { self.steps = steps }
    func replaceArguments(at index: Int, with arguments: String) {
        if case .tool(let name, _) = steps[index] { steps[index] = .tool(name, arguments) }
    }
    func complete(messages: [ChatWireMessage], tools: [ChatToolDefinition], settings: AISettings, apiKey: String, stream: Bool,
                  onDelta: @escaping @Sendable (String) async -> Void) async throws -> ChatCompletion {
        let index = captures.count
        captures.append(.init(messages: messages, tools: tools, settings: settings, stream: stream))
        guard !steps.isEmpty else { throw AIClientError.emptyResponse }
        switch steps.removeFirst() {
        case .text(let text): await onDelta(text); return .init(content: text, toolCalls: [])
        case .tool(let name, let arguments): return .init(content: "", toolCalls: [.init(id: "call-\(index)", function: .init(name: name, arguments: arguments))])
        case .failure(let error): throw error
        case .delayed(let text):
            await onDelta(text)
            try await Task.sleep(for: .seconds(10))
            await onDelta("später")
            return .init(content: text + "später", toolCalls: [])
        }
    }
}

private final class MemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String
    var failWrites = false
    init(_ value: String) { self.value = value }
    func read() throws -> String? { lock.lock(); defer { lock.unlock() }; return value }
    func write(_ value: String) throws { lock.lock(); defer { lock.unlock() }; if failWrites { throw AIKeyStoreError.keychain }; self.value = value }
}

private final class BackendRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return storage }
    func append(_ request: URLRequest) { lock.lock(); defer { lock.unlock() }; storage.append(request) }
}
private func backendSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [BackendURLProtocol.self]
    return URLSession(configuration: config)
}
private final class BackendURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> (Int, [String: String], Data)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: Handler?
    static func set(_ value: @escaping Handler) { lock.lock(); defer { lock.unlock() }; handler = value }
    static func reset() { lock.lock(); defer { lock.unlock() }; handler = nil }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let handler = Self.handler; Self.lock.unlock()
        guard let handler else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
        let (status, headers, data) = handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // Split at arbitrary byte boundaries, including inside UTF-8 characters.
        let midpoint = data.count / 2
        client?.urlProtocol(self, didLoad: data.prefix(midpoint))
        client?.urlProtocol(self, didLoad: data.suffix(from: midpoint))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
