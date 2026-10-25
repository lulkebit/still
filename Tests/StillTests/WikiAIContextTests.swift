import Foundation
import XCTest
@testable import Still

final class WikiAIContextTests: XCTestCase {
    @MainActor
    func testOptimizeUsesNotesContextWithoutWikiAndKeepsTheContextLimit() async throws {
        let root = temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        let gate = AIContextProtocolGate(mode: .immediate,
                                         body: completionBody("Optimized result"))
        AIContextURLProtocol.configure(gate)
        defer { AIContextURLProtocol.reset() }

        let apiKey = IsolatedMemoryCredentialStore("in-memory-api-key")
        let app = StillAppModel(rootURL: root,
                                aiClient: AIClient(session: makeSession()),
                                keyStore: apiKey,
                                confluenceKeys: { _ in IsolatedMemoryCredentialStore("") })
        let normalFolder = try app.store.createFolder(section: .notes, parentPath: [], name: "Project Notes")
        let wikiFolder = try app.store.createFolder(section: .wiki, parentPath: [], name: "WIKI_FOLDER_PRIVATE_SENTINEL")
        try app.store.createNote(section: .wiki, folders: wikiFolder.path,
                                 title: "WIKI_TITLE_PRIVATE_SENTINEL",
                                 markdown: "WIKI_BODY_PRIVATE_SENTINEL")
        let localBody = "LOCAL_NOTE_CONTEXT_SENTINEL\n" + String(repeating: "n", count: AIClient.contextLimit + 2_000)
        let source = try app.store.createNote(section: .notes, folders: normalFolder.path,
                                              title: "Local draft", markdown: localBody)
        let settings = AISettings(baseURL: "https://provider.example/v1", model: "test-model", enabled: true)
        try app.saveSettings(ai: settings, apiKey: "in-memory-api-key", wikiEnabled: false,
                             confluence: .empty, pat: "")

        let outcome = try await app.performAIAction("optimize", noteID: source.id,
                                                    selectedText: "SELECTED_TEXT_SENTINEL")
        guard case .optimized(let replacement) = outcome else {
            return XCTFail("Expected an optimization result")
        }
        XCTAssertEqual(replacement, "Optimized result")

        let request = try XCTUnwrap(gate.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer in-memory-api-key")
        let body = try requestBody(request)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        let userContent = try XCTUnwrap(messages.first(where: { $0["role"] == "user" })?["content"])
        XCTAssertTrue(userContent.contains("SELECTED_TEXT_SENTINEL"))

        let context = try XCTUnwrap(extractWorkspaceContext(from: userContent))
        XCTAssertEqual(context.count, AIClient.contextLimit)
        XCTAssertTrue(context.contains("Project Notes"), "Normal folder context remains available")
        XCTAssertTrue(context.contains("LOCAL_NOTE_CONTEXT_SENTINEL"), "Normal note content remains available")
        XCTAssertFalse(context.contains("WIKI_FOLDER_PRIVATE_SENTINEL"))
        XCTAssertFalse(context.contains("WIKI_TITLE_PRIVATE_SENTINEL"))
        XCTAssertFalse(context.contains("WIKI_BODY_PRIVATE_SENTINEL"))
    }

    @MainActor
    func testWikiGenerationResponseIsDiscardedWhenWikiIsDisabledInFlight() async throws {
        let root = temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        let response = completionBody(#"{"pages":[{"title":"LATE_WIKI_PAGE_SENTINEL","folders":["Late Folder"],"markdown":"Late content"}]}"#)
        let gate = AIContextProtocolGate(mode: .held, body: response)
        AIContextURLProtocol.configure(gate)
        defer { AIContextURLProtocol.reset() }

        let app = StillAppModel(rootURL: root,
                                aiClient: AIClient(session: makeSession()),
                                keyStore: IsolatedMemoryCredentialStore("memory-only-key"),
                                confluenceKeys: { _ in IsolatedMemoryCredentialStore("") })
        let source = try app.store.createNote(section: .notes, title: "Source", markdown: "Local context")
        let settings = AISettings(baseURL: "https://provider.example/v1", model: "test-model", enabled: true)
        try app.saveSettings(ai: settings, apiKey: "memory-only-key", wikiEnabled: true,
                             confluence: .empty, pat: "")
        let originalNoteCount = app.store.notes.count

        let generation = Task { @MainActor in
            try await app.performAIAction("wiki", noteID: source.id,
                                          selectedText: "Selected source material")
        }
        _ = try await gate.waitForRequest()

        try app.saveSettings(ai: settings, apiKey: "memory-only-key", wikiEnabled: false,
                             confluence: .empty, pat: "")
        gate.releaseHeldResponse()

        do {
            _ = try await generation.value
            XCTFail("A response from a request started before Wiki was disabled must be discarded")
        } catch is CancellationError {
            // The stale result is intentionally rejected after it arrives.
        }

        XCTAssertFalse(app.store.wikiEnabled)
        XCTAssertEqual(app.store.notes.count, originalNoteCount)
        XCTAssertFalse(app.store.notes.contains { $0.title == "LATE_WIKI_PAGE_SENTINEL" })
        XCTAssertFalse(app.store.notes.contains { $0.folders.contains("Late Folder") })
    }

    @MainActor
    func testStandaloneTaskIDWorksForOptimizeAndEnabledWikiButNotDisabledWiki() async throws {
        let root = temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        defer { AIContextURLProtocol.reset() }

        let apiKey = IsolatedMemoryCredentialStore("task-api-key")
        let app = StillAppModel(rootURL: root,
                                aiClient: AIClient(session: makeSession()),
                                keyStore: apiKey,
                                confluenceKeys: { _ in IsolatedMemoryCredentialStore("") })
        let task = try app.store.createTask(title: "Standalone task source")
        let settings = AISettings(baseURL: "https://provider.example/v1", model: "test-model", enabled: true)
        try app.saveSettings(ai: settings, apiKey: "task-api-key", wikiEnabled: true,
                             confluence: .empty, pat: "")

        let optimizeGate = AIContextProtocolGate(mode: .immediate, body: completionBody("Task optimized"))
        AIContextURLProtocol.configure(optimizeGate)
        let optimized = try await app.performAIAction("optimize", noteID: task.id, selectedText: "Task source text")
        guard case .optimized(let replacement) = optimized else {
            return XCTFail("Standalone task IDs must remain valid optimization sources")
        }
        XCTAssertEqual(replacement, "Task optimized")
        XCTAssertEqual(optimizeGate.requests.count, 1)

        let wikiContent = #"{"pages":[{"title":"Task Wiki Output","folders":[],"markdown":"Generated from a task"}]}"#
        let wikiGate = AIContextProtocolGate(mode: .immediate, body: completionBody(wikiContent))
        AIContextURLProtocol.configure(wikiGate)
        let wikiOutcome = try await app.performAIAction("wiki", noteID: task.id, selectedText: "Task source text")
        guard case .wiki(let createdPages) = wikiOutcome else {
            return XCTFail("Standalone task IDs must remain valid Wiki-generation sources while Wiki is enabled")
        }
        XCTAssertEqual(createdPages.map(\.title), ["Task Wiki Output"])
        XCTAssertTrue(app.store.notes.contains { $0.title == "Task Wiki Output" })

        try app.saveSettings(ai: settings, apiKey: "task-api-key", wikiEnabled: false,
                             confluence: .empty, pat: "")
        let disabledWikiRequestCount = wikiGate.requests.count
        do {
            _ = try await app.performAIAction("wiki", noteID: task.id, selectedText: "Task source text")
            XCTFail("Wiki generation must remain unavailable when the Wiki feature is off")
        } catch AIClientError.disabled {}
        XCTAssertEqual(wikiGate.requests.count, disabledWikiRequestCount, "A disabled Wiki action must fail before networking")

        let disabledWikiOptimizeGate = AIContextProtocolGate(mode: .immediate, body: completionBody("Still optimized"))
        AIContextURLProtocol.configure(disabledWikiOptimizeGate)
        let optimizedWithWikiOff = try await app.performAIAction("optimize", noteID: task.id,
                                                                 selectedText: "Task source text")
        guard case .optimized(let offReplacement) = optimizedWithWikiOff else {
            return XCTFail("Optimization of a standalone task must remain available when only Wiki is disabled")
        }
        XCTAssertEqual(offReplacement, "Still optimized")

        let deleted = try app.store.createTask(title: "Already deleted task")
        try app.store.deleteTask(id: deleted.id)
        let previousRequestCount = disabledWikiOptimizeGate.requests.count
        do {
            _ = try await app.performAIAction("optimize", noteID: deleted.id, selectedText: "Task source text")
            XCTFail("Deleted task IDs must be rejected as stale AI sources")
        } catch AIClientError.disabled {}
        XCTAssertEqual(disabledWikiOptimizeGate.requests.count, previousRequestCount)
    }

    @MainActor
    func testDeletingStandaloneTaskWhileItsOptimizeRequestIsInFlightDiscardsTheResponse() async throws {
        let root = temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        let gate = AIContextProtocolGate(mode: .held, body: completionBody("Stale task optimization"))
        AIContextURLProtocol.configure(gate)
        defer { AIContextURLProtocol.reset() }

        let app = StillAppModel(rootURL: root,
                                aiClient: AIClient(session: makeSession()),
                                keyStore: IsolatedMemoryCredentialStore("task-api-key"),
                                confluenceKeys: { _ in IsolatedMemoryCredentialStore("") })
        let task = try app.store.createTask(title: "In-flight task")
        try app.saveSettings(ai: AISettings(baseURL: "https://provider.example/v1", model: "test-model", enabled: true),
                             apiKey: "task-api-key", wikiEnabled: true, confluence: .empty, pat: "")

        let action = Task { @MainActor in
            try await app.performAIAction("optimize", noteID: task.id, selectedText: "Task source text")
        }
        _ = try await gate.waitForRequest()
        try app.store.deleteTask(id: task.id)
        gate.releaseHeldResponse()

        do {
            _ = try await action.value
            XCTFail("An AI response for a deleted standalone task must be discarded")
        } catch is CancellationError {}
    }

    private func temporaryWorkspace() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("StillWikiAIContext-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AIContextURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func extractWorkspaceContext(from message: String) -> String? {
        let opening = "<workspace-context>\n"
        let closing = "\n</workspace-context>"
        guard let start = message.range(of: opening)?.upperBound,
              let end = message.range(of: closing, range: start..<message.endIndex)?.lowerBound else { return nil }
        return String(message[start..<end])
    }

    private func completionBody(_ content: String) -> Data {
        let payload: [String: Any] = ["choices": [["message": ["content": content]]]]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    private func requestBody(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = buffer.withUnsafeMutableBufferPointer { pointer in
                stream.read(pointer.baseAddress!, maxLength: pointer.count)
            }
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
            if count == 0 { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }
}

private final class IsolatedMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String

    init(_ value: String) { self.value = value }

    func read() throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func write(_ value: String) throws {
        lock.lock()
        defer { lock.unlock() }
        self.value = value
    }
}

private final class AIContextProtocolGate: @unchecked Sendable {
    enum Mode: Sendable { case immediate, held }

    let mode: Mode
    let body: Data
    private let lock = NSLock()
    private var capturedRequests: [URLRequest] = []
    private var heldProtocol: AIContextURLProtocol?

    init(mode: Mode, body: Data) {
        self.mode = mode
        self.body = body
    }

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return capturedRequests
    }

    func capture(_ request: URLRequest, protocolInstance: AIContextURLProtocol) {
        lock.lock()
        capturedRequests.append(request)
        if mode == .held { heldProtocol = protocolInstance }
        lock.unlock()
        if mode == .immediate { protocolInstance.sendResponse(body) }
    }

    func releaseHeldResponse() {
        lock.lock()
        let protocolInstance = heldProtocol
        heldProtocol = nil
        lock.unlock()
        guard let protocolInstance else { return }
        DispatchQueue.global().async { protocolInstance.sendResponse(self.body) }
    }

    func waitForRequest() async throws -> URLRequest {
        for _ in 0..<400 {
            if let request = requests.first { return request }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw AIContextTestError.requestTimedOut
    }
}

private enum AIContextTestError: Error { case requestTimedOut }

private final class AIContextURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var gate: AIContextProtocolGate?

    static func configure(_ value: AIContextProtocolGate) {
        lock.lock()
        gate = value
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        gate = nil
        lock.unlock()
    }

    private static func currentGate() -> AIContextProtocolGate? {
        lock.lock()
        defer { lock.unlock() }
        return gate
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let gate = Self.currentGate() else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        gate.capture(request, protocolInstance: self)
    }

    func sendResponse(_ body: Data) {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
