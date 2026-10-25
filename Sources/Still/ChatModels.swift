import Foundation

struct ChatSource: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var title: String
    var noteID: UUID? = nil
    var url: URL? = nil
}

struct ChatMessage: Identifiable, Codable, Equatable, Sendable {
    enum Role: String, Codable, Sendable { case user, assistant }
    enum Status: String, Codable, Sendable { case pending, complete, interrupted, failed }
    var id: UUID = UUID()
    var role: Role
    var content: String
    var sources: [ChatSource] = []
    var status: Status = .complete
    var error: String? = nil
    var model: String? = nil
}

struct ChatConversation: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var title: String = "Neues Gespräch"
    var messages: [ChatMessage] = []
    var createdAt: Date = .now
    var updatedAt: Date = .now
}
