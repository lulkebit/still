import Foundation
import MCP

/// A real MCP client/server connection entirely inside the app process.
actor ConfluenceMCP {
    private var client: Client?
    private var server: Server?
    private var revision = UUID()
    private let session: URLSession?
    private var networkSession: URLSession?

    init(session: URLSession? = nil) { self.session = session }

    func invalidate() async {
        revision = UUID()
        networkSession?.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
        networkSession = nil
        let oldClient = client; let oldServer = server
        client = nil; server = nil
        await oldClient?.disconnect()
        await oldServer?.stop()
    }

    func connect(settings: ConfluenceSettings, pat: String, isEnabled: @escaping @Sendable () async -> Bool) async throws {
        guard settings.enabled else { await invalidate(); throw ChatError.toolUnavailable }
        _ = try ConfluenceInstance(settings.baseURL)
        // Every connection binds freshly to the supplied PAT without retaining an identity hash.
        await invalidate()
        let requestRevision = revision
        let service = try ConfluenceClient(baseURL: settings.baseURL, pat: pat, session: session)
        networkSession = service.session
        let newServer = Server(name: "still-confluence", version: "1.0", capabilities: .init(tools: .init()))
        let tools = Self.tools
        await newServer.withMethodHandler(ListTools.self) { _ in
            guard await isEnabled() else { throw ChatError.toolUnavailable }
            return .init(tools: tools)
        }
        await newServer.withMethodHandler(CallTool.self) { params in
            guard await isEnabled() else { throw ChatError.toolUnavailable }
            let argument = try Self.argument(name: params.name, values: params.arguments ?? [:])
            let data: Data
            switch params.name {
            case "confluence_search": data = try JSONEncoder().encode(try await service.search(argument))
            case "confluence_get_page": data = try JSONEncoder().encode(try await service.readPage(argument))
            default: throw ChatError.toolUnavailable
            }
            try Task.checkCancellation()
            guard await isEnabled() else { throw ChatError.toolUnavailable }
            return .init(content: [.text(text: String(decoding: data, as: UTF8.self), annotations: nil, _meta: nil)])
        }
        let pair = await InMemoryTransport.createConnectedPair()
        let newClient = Client(name: "still", version: "1.0")
        do {
            try await newServer.start(transport: pair.server)
            _ = try await newClient.connect(transport: pair.client)
            let listed = try await newClient.listTools()
            guard Set(listed.tools.map(\.name)) == Set(tools.map(\.name)), revision == requestRevision, await isEnabled() else { throw ChatError.toolUnavailable }
            server = newServer; client = newClient
        } catch {
            await newClient.disconnect(); await newServer.stop()
            throw error
        }
    }

    func call(name: String, argument: String) async throws -> String {
        guard let client, Self.tools.contains(where: { $0.name == name }) else { throw ChatError.toolUnavailable }
        let currentRevision = revision
        let key = name == "confluence_search" ? "query" : "pageID"
        let values: [String: Value] = [key: .string(argument)]
        _ = try Self.argument(name: name, values: values)
        let result = try await client.callTool(name: name, arguments: values)
        try Task.checkCancellation()
        guard currentRevision == revision, result.isError != true else { throw ChatError.toolUnavailable }
        let text = result.content.compactMap { content -> String? in
            if case .text(let text, _, _) = content { return text }
            return nil
        }.joined(separator: "\n")
        guard !text.isEmpty else { throw ConfluenceError.invalidResponse }
        return text
    }

    private static func argument(name: String, values: [String: Value]) throws -> String {
        let key: String
        switch name {
        case "confluence_search": key = "query"
        case "confluence_get_page": key = "pageID"
        default: throw ChatError.toolUnavailable
        }
        guard values.count == 1, let value = values[key]?.stringValue, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.count <= (key == "query" ? 500 : 100), key != "pageID" || value.allSatisfy(\.isNumber) else { throw ChatError.invalidToolArguments }
        return value
    }

    private static var tools: [Tool] {
        [("confluence_search", "Find current Confluence pages. Search results are not page contents.", "query"),
         ("confluence_get_page", "Read a current Confluence page by numeric ID.", "pageID")].map { name, description, key in
            Tool(name: name, description: description, inputSchema: .object([
                "type": .string("object"), "properties": .object([key: .object(["type": .string("string")])]),
                "required": .array([.string(key)]), "additionalProperties": .bool(false)
            ]), annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false))
        }
    }
}
