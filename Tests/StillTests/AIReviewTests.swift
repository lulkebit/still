import AppKit
import XCTest
@testable import Still

@MainActor
final class AIReviewTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("still-ai-review-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        AIReviewURLProtocol.reset()
    }

    func testTaskProposalDoesNotMutateUntilAcceptedAndRemainsOneUndoOperation() async throws {
        let original = "Please make this clearer before tomorrow."
        let app = try makeApp(response: "clarify")
        let task = try app.store.createTask(title: "Review copy")
        var taskWithDetail = task
        taskWithDetail.detail = original
        try app.store.updateTask(taskWithDetail)
        let textView = TaskSelectionTextView(frame: NSRect(x: 0, y: 0, width: 360, height: 120))
        textView.allowsUndo = true
        textView.string = original
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 180),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(textView)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        let delegate = TaskDetailStoreDelegate(store: app.store, taskID: task.id)
        var undoSyncCount = 0
        let undoObserver = TaskTextUndoObserver(textView: textView) { text in
            undoSyncCount += 1
            guard var current = app.store.tasks.first(where: { $0.id == task.id }) else { return }
            current.detail = text
            try? app.store.updateTask(current)
        }
        textView.delegate = delegate
        let selectionRange = (original as NSString).range(of: "make this clearer")
        let snapshot = TaskTextSelectionSnapshot(text: "make this clearer", range: selectionRange)
        textView.setSelectedRange(selectionRange)

        XCTAssertTrue(app.beginAIReview(target: .task(task.id), originalDocument: original,
                                        selectedText: snapshot.text, range: snapshot.range,
                                        applyTaskReplacement: { textView.replace($0, for: snapshot) }))
        app.generateAIReview()
        try await waitForProposal(app)

        XCTAssertEqual(app.store.tasks.first(where: { $0.id == task.id })?.detail, original)
        XCTAssertEqual(textView.string, original)
        XCTAssertEqual(app.pendingAIReview?.proposedText, "clarify")

        app.acceptAIReview()
        let revised = "Please clarify before tomorrow."
        XCTAssertEqual(textView.string, revised)
        XCTAssertEqual(app.store.tasks.first(where: { $0.id == task.id })?.detail, revised)
        let undoManager = try XCTUnwrap(textView.undoManager)
        XCTAssertTrue(undoManager.canUndo)
        undoManager.undo()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(textView.string, original)
        XCTAssertGreaterThan(undoSyncCount, 0, "Undo should sync the text view back to the task store")
        XCTAssertEqual(app.store.tasks.first(where: { $0.id == task.id })?.detail, original)
        _ = undoObserver
    }

    func testDiscardLeavesSourceUntouchedAndSourceOrSettingsChangesInvalidateReview() async throws {
        let app = try makeApp(response: "Proposed")
        let original = "Original task details"
        let task = try app.store.createTask(title: "Review")
        var taskWithDetail = task
        taskWithDetail.detail = original
        try app.store.updateTask(taskWithDetail)
        let range = (original as NSString).range(of: "Original")
        let snapshot = TaskTextSelectionSnapshot(text: "Original", range: range)
        let apply: (String) -> Bool = { _ in XCTFail("Discarded proposals cannot be applied"); return false }

        XCTAssertTrue(app.beginAIReview(target: .task(task.id), originalDocument: original,
                                        selectedText: snapshot.text, range: range, applyTaskReplacement: apply))
        app.generateAIReview()
        try await waitForProposal(app)
        app.discardAIReview()
        XCTAssertNil(app.pendingAIReview)
        XCTAssertEqual(app.store.tasks.first(where: { $0.id == task.id })?.detail, original)

        XCTAssertTrue(app.beginAIReview(target: .task(task.id), originalDocument: original,
                                        selectedText: snapshot.text, range: range, applyTaskReplacement: apply))
        var changed = task
        changed.detail = "Changed while review was open"
        try app.store.updateTask(changed)
        try await waitForInvalidation(app)
        XCTAssertNil(app.pendingAIReview)

        let updatedRange = (changed.detail as NSString).range(of: "Changed")
        XCTAssertTrue(app.beginAIReview(target: .task(task.id), originalDocument: changed.detail,
                                        selectedText: "Changed", range: updatedRange, applyTaskReplacement: apply))
        try app.store.deleteTask(id: task.id)
        try await waitForInvalidation(app)
        XCTAssertNil(app.pendingAIReview)

        var settingsTask = try app.store.createTask(title: "Settings invalidation")
        settingsTask.detail = "Review this"
        try app.store.updateTask(settingsTask)
        let settingsRange = (settingsTask.detail as NSString).range(of: "Review")
        XCTAssertTrue(app.beginAIReview(target: .task(settingsTask.id), originalDocument: settingsTask.detail,
                                        selectedText: "Review", range: settingsRange, applyTaskReplacement: apply))
        let settings = AISettings(baseURL: "https://provider.example/v1", model: "next-model", enabled: true)
        try app.saveSettings(ai: settings, apiKey: "review-test-key", wikiEnabled: true,
                             confluence: .empty, pat: "")
        XCTAssertNil(app.pendingAIReview)
    }

    func testEditorDocumentSwitchOrMarkdownChangeDiscardsTheCapturedSelection() async throws {
        let app = try makeApp(response: "Proposed")
        let note = try app.store.createNote(section: .notes, title: "Editor source",
                                            markdown: "Keep this exact passage.")
        let original = note.markdown
        let range = (original as NSString).range(of: "exact passage")
        app.editorDocumentDidChange(note.id)
        XCTAssertTrue(app.beginAIReview(target: .note(note.id), originalDocument: original,
                                        selectedText: "exact passage", range: range))

        app.editorDocumentDidChange(UUID())
        XCTAssertNil(app.pendingAIReview)

        app.editorDocumentDidChange(note.id)
        XCTAssertTrue(app.beginAIReview(target: .note(note.id), originalDocument: original,
                                        selectedText: "exact passage", range: range))
        app.store.updateMarkdown(id: note.id, markdown: "The captured source changed.")
        try await waitForInvalidation(app)
        XCTAssertNil(app.pendingAIReview)
    }

    func testInvalidatedActionCannotClearBusyStateOwnedByNewerAction() async throws {
        let app = try makeApp(response: "Proposed", holdResponse: true)
        let task = try app.store.createTask(title: "Review")
        let first = Task { try await app.performAIAction("optimize", noteID: task.id, selectedText: "selected") }
        try await waitForRequests(1)
        XCTAssertTrue(app.aiBusy)

        try app.removeAPIKey()
        XCTAssertFalse(app.aiBusy)
        let second = Task { try await app.performAIAction("optimize", noteID: task.id, selectedText: "selected") }
        try await waitForRequests(2)
        XCTAssertTrue(app.aiBusy)

        AIReviewURLProtocol.completeNext()
        do {
            _ = try await first.value
            XCTFail("The invalidated request should be rejected")
        } catch is CancellationError {}
        XCTAssertTrue(app.aiBusy, "The old action must not clear the newer action's busy state")

        AIReviewURLProtocol.completeNext()
        _ = try await second.value
        XCTAssertFalse(app.aiBusy)
    }

    private func makeApp(response: String, holdResponse: Bool = false) throws -> StillAppModel {
        let payload: [String: Any] = ["choices": [["message": ["content": response]]]]
        let data = try JSONSerialization.data(withJSONObject: payload)
        AIReviewURLProtocol.configure(body: data, holdResponse: holdResponse)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AIReviewURLProtocol.self]
        let app = StillAppModel(rootURL: root,
                                aiClient: AIClient(session: URLSession(configuration: configuration)),
                                keyStore: AIReviewCredentialStore("review-test-key"),
                                confluenceKeys: { _ in AIReviewCredentialStore("") })
        let settings = AISettings(baseURL: "https://provider.example/v1", model: "review-model", enabled: true)
        try app.saveSettings(ai: settings, apiKey: "review-test-key", wikiEnabled: true,
                             confluence: .empty, pat: "")
        return app
    }

    private func waitForProposal(_ app: StillAppModel) async throws {
        for _ in 0..<300 {
            if let request = app.pendingAIReview, !request.isGenerating, request.proposedText != nil { return }
            if app.pendingAIReview?.error != nil { XCTFail("Review generation failed: \(app.pendingAIReview?.error ?? "")"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("AI proposal did not arrive")
    }

    private func waitForInvalidation(_ app: StillAppModel) async throws {
        for _ in 0..<30 {
            if app.pendingAIReview == nil { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func waitForRequests(_ count: Int) async throws {
        for _ in 0..<300 {
            if AIReviewURLProtocol.pendingCount >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for held AI request")
    }
}

@MainActor
private final class TaskDetailStoreDelegate: NSObject, NSTextViewDelegate {
    private let store: StillStore
    private let taskID: UUID

    init(store: StillStore, taskID: UUID) {
        self.store = store
        self.taskID = taskID
    }

    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView,
              var task = store.tasks.first(where: { $0.id == taskID }) else { return }
        task.detail = textView.string
        try? store.updateTask(task)
    }
}

private final class AIReviewCredentialStore: CredentialStore, @unchecked Sendable {
    private let value: String
    init(_ value: String) { self.value = value }
    func read() throws -> String? { value }
    func write(_ value: String) throws {}
}

private final class AIReviewURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responseBody: Data?
    nonisolated(unsafe) private static var holdsResponses = false
    nonisolated(unsafe) private static var pendingResponses: [AIReviewURLProtocol] = []

    static var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pendingResponses.count
    }

    static func configure(body: Data, holdResponse: Bool = false) {
        lock.lock()
        responseBody = body
        holdsResponses = holdResponse
        pendingResponses = []
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        responseBody = nil
        holdsResponses = false
        pendingResponses = []
        lock.unlock()
    }

    static func completeNext() {
        lock.lock()
        let pending = pendingResponses.isEmpty ? nil : pendingResponses.removeFirst()
        let body = responseBody
        lock.unlock()
        guard let pending, let body else { return }
        pending.finish(with: body)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let body = Self.responseBody
        let holdsResponses = Self.holdsResponses
        if holdsResponses { Self.pendingResponses.append(self) }
        Self.lock.unlock()
        if holdsResponses { return }
        guard let body else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func finish(with body: Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
