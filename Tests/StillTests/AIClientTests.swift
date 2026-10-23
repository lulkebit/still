import Foundation
import XCTest
@testable import Still

final class AIClientTests: XCTestCase {
    func testEndpointNormalizationKeepsProviderBasePathsAndSiblingEndpoints() throws {
        let cases: [(String, String, String)] = [
            ("https://provider.example", "/v1/chat/completions", "/v1/models"),
            ("https://provider.example/v1/", "/v1/chat/completions", "/v1/models"),
            ("https://provider.example/gateway/openai", "/gateway/openai/chat/completions", "/gateway/openai/models"),
            ("https://provider.example/proxy/chat/completions", "/proxy/chat/completions", "/proxy/models"),
            ("https://provider.example/proxy/models", "/proxy/chat/completions", "/proxy/models")
        ]

        for (baseURL, chatPath, modelsPath) in cases {
            XCTAssertEqual(try AIEndpointNormalizer.endpoint(baseURL: baseURL, kind: .chatCompletions).path, chatPath, baseURL)
            XCTAssertEqual(try AIEndpointNormalizer.endpoint(baseURL: baseURL, kind: .models).path, modelsPath, baseURL)
        }
        XCTAssertEqual(try AIEndpointNormalizer.endpoint(baseURL: "http://localhost:8080", kind: .models).absoluteString,
                       "http://localhost:8080/v1/models")
    }

    func testEndpointNormalizerRejectsCredentialsQueriesAndNonLoopbackHTTP() {
        let invalid = [
            "https://user:secret@provider.example/v1",
            "https://provider.example/v1?token=secret",
            "https://provider.example/v1#fragment",
            "http://provider.example/v1",
            "ftp://provider.example/v1",
            "provider.example"
        ]
        for baseURL in invalid {
            XCTAssertThrowsError(try AIEndpointNormalizer.endpoint(baseURL: baseURL, kind: .models), baseURL) { error in
                guard case AIClientError.invalidURL = error else { return XCTFail("Unexpected error for \(baseURL): \(error)") }
            }
        }
    }

    func testDisabledAIClientMakesNoHTTPRequests() async throws {
        let recorder = RequestRecorder()
        let client = AIClient(session: makeSession())
        StubURLProtocol.configure(statusCode: 200, body: Data("{}".utf8), recorder: recorder)
        defer { StubURLProtocol.reset() }

        do {
            _ = try await client.fetchModels(settings: .empty, apiKey: "")
            XCTFail("Disabled model discovery should fail before networking")
        } catch AIClientError.disabled {}
        do {
            _ = try await client.optimize(text: "selection", context: "", settings: .empty, apiKey: "")
            XCTFail("Disabled optimization should fail before networking")
        } catch AIClientError.disabled {}

        XCTAssertTrue(recorder.requests.isEmpty)
    }

    func testModelChatAndWikiRequestsAndResponseErrors() async throws {
        let recorder = RequestRecorder()
        let client = AIClient(session: makeSession())
        defer { StubURLProtocol.reset() }

        StubURLProtocol.configure(statusCode: 200,
                                  body: Data(#"{"data":[{"id":"zeta"},{"id":""},{"id":"alpha"}]}"#.utf8),
                                  recorder: recorder)
        let models = try await client.fetchModels(
            settings: AISettings(baseURL: "https://provider.example/gateway/openai", model: "manual-model", enabled: true),
            apiKey: "  test-secret \n")
        XCTAssertEqual(models, ["alpha", "zeta"])
        let modelRequest = try XCTUnwrap(recorder.requests.last)
        XCTAssertEqual(modelRequest.httpMethod, "GET")
        XCTAssertEqual(modelRequest.url?.path, "/gateway/openai/models")
        XCTAssertEqual(modelRequest.value(forHTTPHeaderField: "Authorization"), "Bearer test-secret")

        StubURLProtocol.configure(statusCode: 200,
                                  body: Data(#"{"choices":[{"message":{"content":"**Concise** 🌱"}}]}"#.utf8),
                                  recorder: recorder)
        let optimized = try await client.optimize(
            text: "Important selection: 42 東京",
            context: "Terminology only",
            settings: AISettings(baseURL: "https://provider.example/v1", model: "manual-model", enabled: true),
            apiKey: " \n")
        XCTAssertEqual(optimized, "**Concise** 🌱")
        let chatRequest = try XCTUnwrap(recorder.requests.last)
        XCTAssertEqual(chatRequest.url?.path, "/v1/chat/completions")
        XCTAssertNil(chatRequest.value(forHTTPHeaderField: "Authorization"))
        let chatBody = try requestBody(chatRequest).jsonObject() as? [String: Any]
        XCTAssertEqual(chatBody?["model"] as? String, "manual-model")
        XCTAssertNil(chatBody?["temperature"])
        XCTAssertNil(chatBody?["response_format"])
        let messages = try XCTUnwrap(chatBody?["messages"] as? [[String: String]])
        XCTAssertEqual(messages.map { $0["role"] }, ["system", "user"])
        XCTAssertTrue(messages[1]["content"]?.contains("Important selection: 42 東京") == true)
        XCTAssertTrue(messages[1]["content"]?.contains("Terminology only") == true)

        let wikiJSONData = try JSONSerialization.data(withJSONObject: [
            "pages": [[
                "title": "München Café",
                "folders": ["Wissen mit Leerzeichen"],
                "markdown": "## Details\n\nSicheres Markdown ✓"
            ]]
        ])
        let wikiJSON = try XCTUnwrap(String(data: wikiJSONData, encoding: .utf8))
        let wikiEnvelope: [String: Any] = [
            "choices": [["message": ["content": "```json\n\(wikiJSON)\n```"]]]
        ]
        StubURLProtocol.configure(statusCode: 200,
                                  body: try JSONSerialization.data(withJSONObject: wikiEnvelope),
                                  recorder: recorder)
        let pages = try await client.generateWikiPages(
            selection: "Selected source",
            context: "Related note",
            settings: AISettings(baseURL: "https://provider.example/proxy/chat/completions", model: "manual-model", enabled: true),
            apiKey: "wiki-key")
        XCTAssertEqual(pages, [GeneratedWikiPage(title: "München Café", folders: ["Wissen mit Leerzeichen"], markdown: "## Details\n\nSicheres Markdown ✓")])
        let wikiRequest = try XCTUnwrap(recorder.requests.last)
        XCTAssertEqual(wikiRequest.url?.path, "/proxy/chat/completions")
        XCTAssertEqual(wikiRequest.value(forHTTPHeaderField: "Authorization"), "Bearer wiki-key")

        StubURLProtocol.configure(statusCode: 503, body: Data("unavailable".utf8), recorder: recorder)
        do {
            _ = try await client.fetchModels(settings: AISettings(baseURL: "https://provider.example/proxy/models", model: "", enabled: true), apiKey: "")
            XCTFail("A non-success HTTP response should surface as an HTTP status error")
        } catch AIClientError.httpStatus(let status) {
            XCTAssertEqual(status, 503)
        }

        StubURLProtocol.configure(statusCode: 200, body: Data("not JSON".utf8), recorder: recorder)
        do {
            _ = try await client.fetchModels(settings: AISettings(baseURL: "https://provider.example", model: "", enabled: true), apiKey: "")
            XCTFail("Malformed model JSON should be reported")
        } catch AIClientError.malformedResponse {}

        StubURLProtocol.configure(statusCode: 200, body: Data(#"{"choices":[]}"#.utf8), recorder: recorder)
        do {
            _ = try await client.optimize(text: "selection", context: "", settings: AISettings(baseURL: "https://provider.example", model: "m", enabled: true), apiKey: "")
            XCTFail("Missing assistant content should be reported as empty")
        } catch AIClientError.emptyResponse {}

        StubURLProtocol.configure(statusCode: 200, body: Data(#"{"choices":[{"message":{"content":"not JSON"}}]}"#.utf8), recorder: recorder)
        do {
            _ = try await client.generateWikiPages(selection: "selection", context: "", settings: AISettings(baseURL: "https://provider.example", model: "m", enabled: true), apiKey: "")
            XCTFail("Non-JSON wiki output should be rejected")
        } catch AIClientError.malformedResponse {}

        StubURLProtocol.configure(statusCode: 200,
                                  body: Data(#"{"choices":[{"message":{"content":"{\"pages\":[]}"}}]}"#.utf8),
                                  recorder: recorder)
        do {
            _ = try await client.generateWikiPages(selection: "selection", context: "", settings: AISettings(baseURL: "https://provider.example", model: "m", enabled: true), apiKey: "")
            XCTFail("An empty wiki page list should be rejected")
        } catch AIClientError.emptyResponse {}
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func requestBody(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
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

private extension Data {
    func jsonObject() throws -> Any {
        try JSONSerialization.jsonObject(with: self, options: [.fragmentsAllowed])
    }
}

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var capturedRequests: [URLRequest] = []

    func append(_ request: URLRequest) {
        lock.lock()
        capturedRequests.append(request)
        lock.unlock()
    }

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return capturedRequests
    }
}

private struct StubResponse: Sendable {
    let statusCode: Int
    let body: Data
    let recorder: RequestRecorder
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let stateLock = NSLock()
    nonisolated(unsafe) private static var response: StubResponse?

    static func configure(statusCode: Int, body: Data, recorder: RequestRecorder) {
        stateLock.lock()
        response = StubResponse(statusCode: statusCode, body: body, recorder: recorder)
        stateLock.unlock()
    }

    static func reset() {
        stateLock.lock()
        response = nil
        stateLock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.stateLock.lock()
        let configured = Self.response
        Self.stateLock.unlock()
        guard let configured else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        configured.recorder.append(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: configured.statusCode,
                                       httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: configured.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
