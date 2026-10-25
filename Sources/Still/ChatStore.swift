import Foundation
import Observation

@MainActor @Observable
final class ChatStore {
    private(set) var conversations: [ChatConversation] = []
    var errorMessage: String?
    let rootURL: URL
    @ObservationIgnored private var canWrite = true
    @ObservationIgnored private var autosaveTask: Task<Void, Never>?
    private var fileURL: URL { rootURL.appendingPathComponent("conversations.json") }

    init(rootURL: URL) {
        self.rootURL = rootURL
        do {
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                conversations = try JSONDecoder().decode([ChatConversation].self, from: Data(contentsOf: fileURL))
                var recovered = false
                for index in conversations.indices {
                    for message in conversations[index].messages.indices where conversations[index].messages[message].status == .pending {
                        conversations[index].messages[message].status = .interrupted
                        recovered = true
                    }
                }
                if recovered { try save() }
            }
        } catch {
            errorMessage = "Gespräche konnten nicht geladen werden. Die vorhandene Datei bleibt erhalten."
            canWrite = false
        }
    }

    func conversation(_ id: UUID) -> ChatConversation? { conversations.first { $0.id == id } }

    @discardableResult func create(title: String = "Neues Gespräch") throws -> ChatConversation {
        let conversation = ChatConversation(title: title)
        try commit(conversations + [conversation])
        return conversation
    }

    func rename(_ id: UUID, title: String) throws {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        try update(id) { $0.title = String(title.prefix(200)) }
    }

    func delete(_ id: UUID) throws { try commit(conversations.filter { $0.id != id }) }

    func update(_ id: UUID, persist: Bool = true, _ mutation: (inout ChatConversation) -> Void) throws {
        var next = conversations
        guard let index = next.firstIndex(where: { $0.id == id }) else { return }
        mutation(&next[index])
        next[index].updatedAt = .now
        if persist { try commit(next) }
        else {
            conversations = next
            if autosaveTask == nil {
                autosaveTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(750))
                    guard !Task.isCancelled, let self else { return }
                    self.autosaveTask = nil
                    do { try self.save() } catch { self.errorMessage = "Gespräche konnten nicht gespeichert werden." }
                }
            }
        }
    }

    func flushPendingWrites() {
        do { try save() } catch { errorMessage = "Gespräche konnten nicht gespeichert werden." }
    }

    func save() throws {
        autosaveTask?.cancel()
        autosaveTask = nil
        guard canWrite else { throw ChatError.persistence }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(conversations).write(to: fileURL, options: .atomic)
    }

    private func commit(_ next: [ChatConversation]) throws {
        let previous = conversations
        conversations = next
        do { try save(); errorMessage = nil }
        catch { conversations = previous; errorMessage = "Gespräche konnten nicht gespeichert werden."; throw error }
    }
}

enum ChatError: LocalizedError, Equatable {
    case persistence, invalidToolArguments, toolUnavailable, toolLimit, contextLimit, malformedStream
    case unsupportedStreaming, unsupportedTools
    var errorDescription: String? {
        switch self {
        case .persistence: "Gespräche konnten nicht gespeichert werden."
        case .invalidToolArguments: "Die KI hat ungültige Werkzeugargumente geliefert."
        case .toolUnavailable: "Diese Wissensquelle ist nicht verfügbar."
        case .toolLimit: "Die maximale Anzahl von sechs Werkzeugrunden wurde erreicht. Bitte grenze die Frage ein."
        case .contextLimit: "Das Wissenslimit für diese Antwort wurde erreicht."
        case .malformedStream: "Die KI hat eine ungültige Streaming-Antwort geliefert."
        case .unsupportedStreaming: "Der Anbieter unterstützt Streaming nicht."
        case .unsupportedTools: "Der Anbieter unterstützt Werkzeuge nicht."
        }
    }
}
