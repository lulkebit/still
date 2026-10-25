import Foundation

struct ChatToolCall: Codable, Equatable, Sendable {
    struct Function: Codable, Equatable, Sendable { var name: String; var arguments: String }
    var id: String
    var type: String = "function"
    var function: Function
}

struct ChatWireMessage: Codable, Equatable, Sendable {
    var role: String
    var content: String?
    var tool_calls: [ChatToolCall]? = nil
    var tool_call_id: String? = nil
}

struct ChatToolDefinition: Encodable, Sendable {
    struct Function: Encodable, Sendable {
        struct Parameters: Encodable, Sendable {
            struct Property: Encodable, Sendable { let type = "string"; var description: String }
            let type = "object"
            var properties: [String: Property]
            var required: [String]
            let additionalProperties = false
        }
        var name: String
        var description: String
        var parameters: Parameters
    }
    let type = "function"
    var function: Function

    init(_ name: String, _ description: String, key: String) {
        function = Function(name: name, description: description, parameters: .init(properties: [key: .init(description: key)], required: [key]))
    }
}

struct ChatCompletion: Sendable { var content: String; var toolCalls: [ChatToolCall] }

/// SSE state is independent of URLSession so fragmented function calls can be tested directly.
struct ChatStreamParser {
    private(set) var content = ""
    private var calls: [Int: ChatToolCall] = [:]
    private(set) var finished = false
    private var finishReason: String?

    mutating func consume(_ json: String) throws -> String {
        if json == "[DONE]" { finished = true; return "" }
        struct Chunk: Decodable {
            struct Choice: Decodable {
                struct Delta: Decodable {
                    struct Call: Decodable {
                        struct Function: Decodable { var name: String?; var arguments: String? }
                        var index: Int; var id: String?; var type: String?; var function: Function?
                    }
                    var content: String?; var tool_calls: [Call]?
                }
                var index: Int?; var delta: Delta; var finish_reason: String?
            }
            var choices: [Choice]
        }
        let chunk: Chunk
        do { chunk = try JSONDecoder().decode(Chunk.self, from: Data(json.utf8)) }
        catch { throw ChatError.malformedStream }
        guard let choice = chunk.choices.first(where: { $0.index == nil || $0.index == 0 }) else { return "" }
        if let reason = choice.finish_reason { finishReason = reason; finished = true }
        let delta = choice.delta.content ?? ""
        content += delta
        guard content.count <= 200_000 else { throw ChatError.malformedStream }
        for fragment in choice.delta.tool_calls ?? [] {
            guard fragment.index >= 0, fragment.index < 32, fragment.type == nil || fragment.type == "function" else { throw ChatError.invalidToolArguments }
            var call = calls[fragment.index] ?? ChatToolCall(id: "", function: .init(name: "", arguments: ""))
            if let id = fragment.id {
                // IDs are identifiers, not token fragments; repeated identical IDs are allowed.
                guard call.id.isEmpty || call.id == id else { throw ChatError.invalidToolArguments }
                call.id = id
            }
            call.function.name += fragment.function?.name ?? ""
            call.function.arguments += fragment.function?.arguments ?? ""
            guard call.id.count <= 256, call.function.name.count <= 100, call.function.arguments.count <= 16_000 else { throw ChatError.invalidToolArguments }
            calls[fragment.index] = call
        }
        return delta
    }

    func result() throws -> ChatCompletion {
        guard finished, finishReason != "length", finishReason != "content_filter" else { throw ChatError.malformedStream }
        let ordered = calls.keys.sorted().compactMap { calls[$0] }
        guard ordered.allSatisfy({ !$0.id.isEmpty && !$0.function.name.isEmpty }), Set(ordered.map(\.id)).count == ordered.count else { throw ChatError.invalidToolArguments }
        guard !content.isEmpty || !ordered.isEmpty else { throw AIClientError.emptyResponse }
        return .init(content: content, toolCalls: ordered)
    }
}

protocol AIChatServing: Sendable {
    func complete(messages: [ChatWireMessage], tools: [ChatToolDefinition], settings: AISettings, apiKey: String,
                  stream: Bool, onDelta: @escaping @Sendable (String) async -> Void) async throws -> ChatCompletion
}

struct AIChatClient: AIChatServing {
    var session: URLSession = .shared

    func complete(messages: [ChatWireMessage], tools: [ChatToolDefinition], settings: AISettings, apiKey: String,
                  stream: Bool, onDelta: @escaping @Sendable (String) async -> Void) async throws -> ChatCompletion {
        guard settings.enabled else { throw AIClientError.disabled }
        guard !settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIClientError.missingModel }
        let url = try AIEndpointNormalizer.endpoint(baseURL: settings.baseURL, kind: .chatCompletions)
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(stream ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        struct Body: Encodable {
            var model: String; var messages: [ChatWireMessage]; var stream: Bool; var tools: [ChatToolDefinition]?
        }
        request.httpBody = try JSONEncoder().encode(Body(model: settings.model, messages: messages, stream: stream, tools: tools.isEmpty ? nil : tools))
        if !stream {
            let (data, response) = try await session.data(for: request)
            try Self.validate(response, data: data, streaming: false, tools: !tools.isEmpty)
            struct Response: Decodable {
                struct Choice: Decodable { struct Message: Decodable { var content: String?; var tool_calls: [ChatToolCall]? }; var message: Message }
                var choices: [Choice]
            }
            let decoded: Response
            do { decoded = try JSONDecoder().decode(Response.self, from: data) }
            catch { throw AIClientError.malformedResponse }
            guard let message = decoded.choices.first?.message else { throw AIClientError.emptyResponse }
            let calls = message.tool_calls ?? []
            guard !message.content.orEmpty.isEmpty || !calls.isEmpty else { throw AIClientError.emptyResponse }
            try Self.validateCalls(calls)
            if let content = message.content { await onDelta(content) }
            return .init(content: message.content ?? "", toolCalls: calls)
        }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw AIClientError.network }
        if !(200..<300).contains(http.statusCode) {
            var data = Data()
            for try await byte in bytes { if data.count >= 64_000 { break }; data.append(byte) }
            try Self.validate(response, data: data, streaming: true, tools: !tools.isEmpty)
        }
        // A successful JSON response to stream:true is not explicit lack of support: do not retry it.
        guard http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true else { throw ChatError.malformedStream }
        var parser = ChatStreamParser()
        var events = ChatSSEDecoder()
        for try await byte in bytes {
            try Task.checkCancellation()
            if let event = try events.consume(byte) {
                let fragment = try parser.consume(event)
                if !fragment.isEmpty { await onDelta(fragment) }
                if parser.finished { break }
            }
        }
        if !parser.finished, let event = try events.finish() {
            let fragment = try parser.consume(event)
            if !fragment.isEmpty { await onDelta(fragment) }
        }
        try Task.checkCancellation()
        return try parser.result()
    }

    private static func validateCalls(_ calls: [ChatToolCall]) throws {
        guard calls.count <= 32, Set(calls.map(\.id)).count == calls.count,
              calls.allSatisfy({ $0.type == "function" && !$0.id.isEmpty && $0.id.count <= 256 && !$0.function.name.isEmpty && $0.function.name.count <= 100 && $0.function.arguments.count <= 16_000 }) else { throw ChatError.invalidToolArguments }
    }

    private static func validate(_ response: URLResponse, data: Data, streaming: Bool, tools: Bool) throws {
        guard let http = response as? HTTPURLResponse else { throw AIClientError.network }
        guard !(200..<300).contains(http.statusCode) else { return }
        // Inspect only bounded error text, never expose or persist provider payloads.
        let body = String(decoding: data.prefix(64_000), as: UTF8.self).lowercased()
        let explicit = ["not supported", "unsupported", "does not support", "not support", "not allowed", "unknown parameter", "unrecognized request argument"].contains { body.contains($0) }
        if [400, 404, 422, 501].contains(http.statusCode), explicit {
            if streaming && body.contains("stream") { throw ChatError.unsupportedStreaming }
            if tools && (body.contains("tool") || body.contains("function")) { throw ChatError.unsupportedTools }
        }
        throw AIClientError.httpStatus(http.statusCode)
    }
}

private extension Optional where Wrapped == String { var orEmpty: String { self ?? "" } }

/// Unlike AsyncBytes.lines this preserves the empty lines that delimit SSE events.
struct ChatSSEDecoder {
    private var line: [UInt8] = []
    private var dataLines: [String] = []
    private var size = 0
    private var previousCR = false

    mutating func consume(_ byte: UInt8) throws -> String? {
        if previousCR && byte == 10 { previousCR = false; return nil }
        previousCR = byte == 13
        if byte == 10 || byte == 13 { return try endLine() }
        line.append(byte)
        guard line.count <= 256_000 else { throw ChatError.malformedStream }
        return nil
    }

    mutating func finish() throws -> String? {
        if !line.isEmpty { _ = try endLine() }
        return dispatch()
    }

    private mutating func endLine() throws -> String? {
        defer { line.removeAll(keepingCapacity: true) }
        if line.isEmpty { return dispatch() }
        guard let text = String(bytes: line, encoding: .utf8) else { throw ChatError.malformedStream }
        if text.hasPrefix("data:") {
            var value = String(text.dropFirst(5))
            if value.hasPrefix(" ") { value.removeFirst() }
            size += value.count
            guard size <= 256_000 else { throw ChatError.malformedStream }
            dataLines.append(value)
        }
        return nil
    }

    private mutating func dispatch() -> String? {
        guard !dataLines.isEmpty else { return nil }
        let event = dataLines.joined(separator: "\n")
        dataLines = []; size = 0
        return event
    }
}
