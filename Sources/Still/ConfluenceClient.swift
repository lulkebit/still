import Foundation
import SwiftSoup

struct ConfluencePage: Codable, Equatable, Sendable {
    var id: String
    var title: String
    var url: URL
    var text: String?
}

enum ConfluenceError: LocalizedError {
    case invalidURL, missingPAT, unauthenticated, invalidResponse, http(Int)
    var errorDescription: String? {
        switch self {
        case .invalidURL: "Bitte eine gültige HTTPS-Confluence-Instanz eingeben."
        case .missingPAT: "Bitte ein Confluence Personal Access Token eingeben."
        case .unauthenticated: "Confluence hat das Token nicht als angemeldeten Benutzer bestätigt."
        case .invalidResponse: "Confluence hat eine ungültige Antwort geliefert."
        case .http(let status): "Confluence-Anfrage fehlgeschlagen (HTTP \(status))."
        }
    }
}

/// All requests use the configured instance, never URLs supplied by page content.
struct ConfluenceInstance: Equatable, Sendable {
    let baseURL: URL
    var keychainAccount: String { baseURL.absoluteString }

    init(_ value: String) throws {
        guard var c = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = c.scheme?.lowercased(), let host = c.host?.lowercased(),
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)) else { throw ConfluenceError.invalidURL }
        c.scheme = scheme; c.host = host
        if (scheme == "https" && c.port == 443) || (scheme == "http" && c.port == 80) { c.port = nil }
        var path = c.path
        guard !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }), !path.contains("\\") else { throw ConfluenceError.invalidURL }
        while path.hasSuffix("/") { path.removeLast() }
        c.path = path
        guard let url = c.url else { throw ConfluenceError.invalidURL }
        baseURL = url
    }

    func endpoint(_ path: String, query: [URLQueryItem] = []) -> URL {
        var c = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        c.path += "/rest/api/" + path
        c.queryItems = query.isEmpty ? nil : query
        return c.url!
    }

    func pageURL(id: String, webUI: String?) -> URL {
        if let webUI, let url = URL(string: webUI, relativeTo: URL(string: baseURL.absoluteString + "/"))?.absoluteURL, contains(url) {
            return url
        }
        var c = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        c.path += "/pages/viewpage.action"
        c.queryItems = [URLQueryItem(name: "pageId", value: id)]
        return c.url!
    }

    func contains(_ url: URL) -> Bool {
        guard let candidate = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let base = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              candidate.scheme?.lowercased() == base.scheme, candidate.host?.lowercased() == base.host,
              candidate.port == base.port, candidate.user == nil, candidate.password == nil else { return false }
        return candidate.path == base.path || candidate.path.hasPrefix(base.path + "/")
    }
}

private final class ConfluenceRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    // Refusing redirects also prevents same-origin redirects into login or another context.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct ConfluenceClient: Sendable {
    let instance: ConfluenceInstance
    private let pat: String
    let session: URLSession

    init(baseURL: String, pat: String, session: URLSession? = nil) throws {
        instance = try ConfluenceInstance(baseURL)
        self.pat = pat.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !self.pat.isEmpty else { throw ConfluenceError.missingPAT }
        self.session = session ?? URLSession(configuration: .ephemeral, delegate: ConfluenceRedirectPolicy(), delegateQueue: nil)
    }

    func testConnection() async throws {
        let data = try await get(instance.endpoint("user/current"))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["type"] as? String)?.lowercased() == "known" else { throw ConfluenceError.unauthenticated }
        let identifiers = ["username", "name", "userKey"].compactMap { object[$0] as? String }.filter { !$0.isEmpty }
        guard !identifiers.isEmpty, !identifiers.contains(where: { ["anonymous", "anonymous user"].contains($0.lowercased()) }) else { throw ConfluenceError.unauthenticated }
    }

    static func escapedCQL(_ query: String) -> String {
        // A quoted CQL text expression; user text can never introduce CQL operators.
        query.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    }

    func search(_ query: String) async throws -> [ConfluencePage] {
        let cql = "type = page AND status = current AND text ~ \"\(Self.escapedCQL(String(query.prefix(500))))\" ORDER BY lastmodified DESC"
        let data = try await get(instance.endpoint("content/search", query: [URLQueryItem(name: "cql", value: cql), URLQueryItem(name: "limit", value: "10")]))
        let response = try JSONDecoder().decode(SearchResponse.self, from: data)
        return try response.results.prefix(10).map { try page($0, readBody: false) }
    }

    func readPage(_ id: String) async throws -> ConfluencePage {
        guard !id.isEmpty, id.count <= 100, id.allSatisfy(\.isNumber) else { throw ChatError.invalidToolArguments }
        let data = try await get(instance.endpoint("content/\(id)", query: [URLQueryItem(name: "expand", value: "body.view")]))
        return try page(JSONDecoder().decode(PageResponse.self, from: data), readBody: true)
    }

    static func readableHTML(_ html: String, limit: Int = 18_000) throws -> String {
        let doc = try SwiftSoup.parse(String(html.prefix(1_000_000)))
        try doc.select("script,style,noscript,iframe,object").remove()
        let visitor = ConfluenceHTMLTextVisitor()
        try doc.traverse(visitor)
        let text = visitor.text
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        var output = ""
        var previousBlank = false
        for line in lines {
            if line.isEmpty && previousBlank { continue }
            previousBlank = line.isEmpty
            output += line + "\n"
            if output.count >= limit { break }
        }
        return String(output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(max(0, limit)))
    }

    private func page(_ value: PageResponse, readBody: Bool) throws -> ConfluencePage {
        guard !value.id.isEmpty, value.id.allSatisfy(\.isNumber), !value.title.isEmpty,
              value.type == nil || value.type == "page", value.status == nil || value.status == "current" else { throw ConfluenceError.invalidResponse }
        if readBody && value.body?.view?.value == nil { throw ConfluenceError.invalidResponse }
        return ConfluencePage(id: value.id, title: value.title, url: instance.pageURL(id: value.id, webUI: value._links?.webui),
                              text: try readBody ? Self.readableHTML(value.body!.view!.value) : nil)
    }

    private func get(_ url: URL) async throws -> Data {
        guard instance.contains(url) else { throw ConfluenceError.invalidURL }
        var request = URLRequest(url: url, timeoutInterval: 45)
        request.setValue("Bearer \(pat)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw ConfluenceError.invalidResponse }
        guard http.url.map(instance.contains) == true else { throw ConfluenceError.invalidURL }
        guard (200..<300).contains(http.statusCode) else { throw ConfluenceError.http(http.statusCode) }
        guard data.count <= 5_000_000 else { throw ConfluenceError.invalidResponse }
        return data
    }

    private struct SearchResponse: Decodable { var results: [PageResponse] }
    private struct PageResponse: Decodable {
        struct Links: Decodable { var webui: String? }
        struct Body: Decodable { struct View: Decodable { var value: String }; var view: View? }
        var id: String
        var title: String
        var type: String?
        var status: String?
        var _links: Links?
        var body: Body?
    }
}

private final class ConfluenceHTMLTextVisitor: NodeVisitor {
    var text = ""
    private let blocks: Set<String> = ["h1", "h2", "h3", "h4", "h5", "h6", "p", "div", "section", "article", "pre", "blockquote", "tr", "ul", "ol"]
    func head(_ node: Node, _ depth: Int) throws {
        if let element = node as? Element {
            let tag = element.tagName()
            if blocks.contains(tag) || tag == "br" { text += "\n" }
            if tag == "li" { text += "\n• " }
        } else if let node = node as? TextNode { text += node.getWholeText() }
    }
    func tail(_ node: Node, _ depth: Int) throws {
        guard let element = node as? Element else { return }
        let tag = element.tagName()
        if blocks.contains(tag) { text += "\n" }
        if tag == "td" || tag == "th" { text += " | " }
    }
}
