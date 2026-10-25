import Foundation
import Observation

@MainActor
@Observable
final class StillAppModel {
    let store: StillStore
    let chatStore: ChatStore
    let chat: ChatCoordinator
    var aiBusy = false
    var aiError: String?
    var feedback: String?
    var availableModels: [String] = []
    var isFetchingModels = false
    private(set) var lastAIContextCharacters = 0

    @ObservationIgnored private let aiClient: AIClient
    @ObservationIgnored private let keyStore: any CredentialStore
    @ObservationIgnored private let confluenceKeys: (String) throws -> any CredentialStore
    @ObservationIgnored private var actionRequestID = UUID()
    @ObservationIgnored private var modelRequestID = UUID()

    init(rootURL: URL? = nil, aiClient: AIClient = AIClient(), keyStore: any CredentialStore = AIKeyStore(),
         confluenceKeys: @escaping (String) throws -> any CredentialStore = { try AIKeyStore.confluence(baseURL: $0) },
         chatClient: any AIChatServing = AIChatClient()) {
        let environmentPath = ProcessInfo.processInfo.environment["STILL_DATA_DIR"]
        let resolvedRoot = rootURL ?? environmentPath.flatMap { value in
            value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : URL(fileURLWithPath: value, isDirectory: true)
        }
        let noteStore = StillStore(rootURL: resolvedRoot)
        store = noteStore
        let conversationStore = ChatStore(rootURL: noteStore.rootURL)
        chatStore = conversationStore
        chat = ChatCoordinator(store: noteStore, chatStore: conversationStore, client: chatClient,
                               readAPIKey: { try keyStore.read() ?? "" }, readPAT: { try confluenceKeys($0).read() ?? "" })
        self.aiClient = aiClient
        self.keyStore = keyStore
        self.confluenceKeys = confluenceKeys
    }

    func apiKeyForSettings() -> String {
        do { return try keyStore.read() ?? "" }
        catch {
            aiError = L10n.message(for: error)
            return ""
        }
    }

    func hasSavedAPIKey() -> Bool {
        (try? keyStore.read())?.isEmpty == false
    }

    func confluencePATForSettings(baseURL: String) -> String {
        do { return try confluenceKeys(baseURL).read() ?? "" }
        catch { return "" }
    }

    func removeConfluencePAT(baseURL: String) throws {
        try confluenceKeys(baseURL).write("")
        chat.configurationDidChange()
    }

    func testConfluenceConnection(settings: ConfluenceSettings, pat: String) async throws {
        try await ConfluenceClient(baseURL: settings.baseURL, pat: pat).testConnection()
    }

    func saveAISettings(_ settings: AISettings, apiKey: String) throws {
        try saveSettings(ai: settings, apiKey: apiKey, wikiEnabled: store.wikiEnabled,
                         confluence: store.confluenceSettings, pat: "")
    }

    func saveSettings(ai: AISettings, apiKey: String, wikiEnabled: Bool, confluence: ConfluenceSettings, pat: String) throws {
        if ai.enabled {
            _ = try AIEndpointNormalizer.endpoint(baseURL: ai.baseURL, kind: .chatCompletions)
            guard !ai.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIClientError.missingModel }
        }
        let hasNewPAT = !pat.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let patKey: (any CredentialStore)?
        if confluence.enabled || hasNewPAT {
            _ = try ConfluenceInstance(confluence.baseURL)
            patKey = try confluenceKeys(confluence.baseURL)
        } else { patKey = nil }
        if confluence.enabled {
            _ = try ConfluenceInstance(confluence.baseURL)
            let candidate = pat.trimmingCharacters(in: .whitespacesAndNewlines)
            let saved = try patKey?.read() ?? ""
            guard !candidate.isEmpty || !saved.isEmpty else { throw ConfluenceError.missingPAT }
        }
        let previousAPIKey = try keyStore.read() ?? ""
        let previousPAT = try patKey?.read() ?? ""
        do {
            try keyStore.write(apiKey)
            if !pat.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { try patKey?.write(pat) }
            try store.updateAllSettings(ai: ai, wikiEnabled: wikiEnabled, confluenceSettings: confluence)
        } catch {
            try? keyStore.write(previousAPIKey)
            if !pat.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { try? patKey?.write(previousPAT) }
            throw error
        }
        actionRequestID = UUID()
        chat.configurationDidChange()
        clearAvailableModels()
        aiError = nil
        feedback = L10n.text("settings.ai.saved")
    }

    func removeAPIKey() throws {
        try keyStore.write("")
        actionRequestID = UUID()
        chat.configurationDidChange()
        aiError = nil
    }

    func refreshModels() async {
        guard store.settings.enabled else { return }
        await refreshModels(settings: store.settings, apiKey: (try? keyStore.read()) ?? "")
    }

    func refreshModels(settings: AISettings, apiKey: String) async {
        guard settings.enabled else { return }
        let requestID = UUID()
        modelRequestID = requestID
        isFetchingModels = true
        defer { if modelRequestID == requestID { isFetchingModels = false } }
        do {
            let models = try await aiClient.fetchModels(settings: settings, apiKey: apiKey)
            guard modelRequestID == requestID else { return }
            availableModels = models
            if models.isEmpty { aiError = L10n.text("settings.ai.noModels") }
            else { aiError = nil }
        } catch {
            guard modelRequestID == requestID else { return }
            aiError = L10n.message(for: error)
        }
    }

    func clearAvailableModels() {
        modelRequestID = UUID()
        availableModels = []
        isFetchingModels = false
    }

    func performAIAction(_ action: String, noteID: UUID, selectedText: String) async throws -> AIActionOutcome {
        guard !aiBusy else { throw AIClientError.busy }
        guard store.settings.enabled else { throw AIClientError.disabled }
        guard !store.settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIClientError.invalidURL
        }
        guard !store.settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIClientError.missingModel
        }
        guard !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIClientError.emptyResponse
        }
        let noteSource = store.notes.first(where: { $0.id == noteID })
        let taskSourceExists = noteSource == nil && store.tasks.contains(where: { $0.id == noteID })
        guard noteSource.map({ store.canAccess($0.section) }) ?? taskSourceExists,
              action != "wiki" || store.wikiEnabled else { throw AIClientError.disabled }
        let isTaskSource = taskSourceExists
        let requestID = UUID()
        actionRequestID = requestID
        let settings = store.settings
        let wikiEnabled = store.wikiEnabled
        aiBusy = true
        aiError = nil
        feedback = nil
        defer { aiBusy = false }

        let apiKey: String
        do { apiKey = try keyStore.read() ?? "" }
        catch { throw AIKeyStoreError.keychain }
        func validateResult() throws {
            try Task.checkCancellation()
            let sourceStillExists: Bool
            if isTaskSource {
                sourceStillExists = store.tasks.contains(where: { $0.id == noteID })
            } else if let current = store.visibleNotes.first(where: { $0.id == noteID }) {
                sourceStillExists = store.canAccess(current.section)
            } else {
                sourceStillExists = false
            }
            guard actionRequestID == requestID, store.settings == settings, store.settings.enabled,
                  store.wikiEnabled == wikiEnabled,
                  sourceStillExists,
                  action != "wiki" || store.wikiEnabled else { throw CancellationError() }
        }
        let context = aiContext()
        lastAIContextCharacters = context.count
        switch action {
        case "wiki":
            let pages = try await aiClient.generateWikiPages(selection: selectedText, context: context,
                                                             settings: settings, apiKey: apiKey)
            try validateResult()
            let created = try store.createWikiPages(pages)
            feedback = String(format: L10n.text("settings.ai.wikiCreated"), created.count)
            return .wiki(created)
        case "optimize":
            let replacement = try await aiClient.optimize(text: selectedText, context: context,
                                                          settings: settings, apiKey: apiKey)
            try validateResult()
            return .optimized(replacement)
        default:
            throw AIClientError.malformedResponse
        }
    }

    private func aiContext() -> String {
        var context = ""
        let folderLines = store.visibleFolders.sorted {
            let left = "\($0.section.rawValue)/\($0.path.joined(separator: "/"))"
            let right = "\($1.section.rawValue)/\($1.path.joined(separator: "/"))"
            return left.localizedStandardCompare(right) == .orderedAscending
        }.map { folder in
            let section = L10n.text(folder.section == .wiki ? "nav.wiki" : "nav.notes")
            let folderLabel = L10n.text("ai.folderContextLabel")
            return "[\(section) – \(folderLabel)] \(folder.path.joined(separator: " / "))"
        }
        for line in folderLines {
            guard context.count < AIClient.contextLimit else { break }
            context += String("\n\(line)".prefix(AIClient.contextLimit - context.count))
        }
        for note in store.visibleNotes.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            guard context.count < AIClient.contextLimit else { break }
            let label = note.section == .wiki ? L10n.text("nav.wiki") : L10n.text("nav.notes")
            let path = note.folders.isEmpty ? "" : " — \(note.folders.joined(separator: " / "))"
            let block = "\n\n[\(label)] \(note.title)\(path)\n\(note.markdown)"
            let remaining = AIClient.contextLimit - context.count
            context += String(block.prefix(remaining))
        }
        return context
    }
}

enum AIActionOutcome {
    case wiki([Note])
    case optimized(String)
}
