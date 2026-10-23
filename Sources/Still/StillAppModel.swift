import Foundation
import Observation

@MainActor
@Observable
final class StillAppModel {
    let store: StillStore
    var aiBusy = false
    var aiError: String?
    var feedback: String?
    var availableModels: [String] = []
    var isFetchingModels = false
    private(set) var lastAIContextCharacters = 0

    @ObservationIgnored private let aiClient: AIClient
    @ObservationIgnored private let keyStore: AIKeyStore
    @ObservationIgnored private var modelRequestID = UUID()

    init(rootURL: URL? = nil, aiClient: AIClient = AIClient(), keyStore: AIKeyStore = AIKeyStore()) {
        let environmentPath = ProcessInfo.processInfo.environment["STILL_DATA_DIR"]
        let resolvedRoot = rootURL ?? environmentPath.flatMap { value in
            value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : URL(fileURLWithPath: value, isDirectory: true)
        }
        store = StillStore(rootURL: resolvedRoot)
        self.aiClient = aiClient
        self.keyStore = keyStore
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

    func saveAISettings(_ settings: AISettings, apiKey: String) throws {
        if settings.enabled {
            _ = try AIEndpointNormalizer.endpoint(baseURL: settings.baseURL, kind: .chatCompletions)
            guard !settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AIClientError.missingModel
            }
        }
        let previousSettings = store.settings
        try store.updateSettings(settings)
        do { try keyStore.write(apiKey) }
        catch {
            try? store.updateSettings(previousSettings)
            throw error
        }
        aiError = nil
        feedback = L10n.text("settings.ai.saved")
    }

    func removeAPIKey() throws {
        try keyStore.write("")
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
        aiBusy = true
        aiError = nil
        feedback = nil
        defer { aiBusy = false }

        let apiKey: String
        do { apiKey = try keyStore.read() ?? "" }
        catch { throw AIKeyStoreError.keychain }
        let context = aiContext()
        lastAIContextCharacters = context.count
        switch action {
        case "wiki":
            let pages = try await aiClient.generateWikiPages(selection: selectedText, context: context,
                                                             settings: store.settings, apiKey: apiKey)
            let created = try store.createWikiPages(pages)
            feedback = String(format: L10n.text("settings.ai.wikiCreated"), created.count)
            return .wiki(created)
        case "optimize":
            let replacement = try await aiClient.optimize(text: selectedText, context: context,
                                                          settings: store.settings, apiKey: apiKey)
            return .optimized(replacement)
        default:
            throw AIClientError.malformedResponse
        }
    }

    private func aiContext() -> String {
        var context = ""
        let folderLines = store.folders.sorted {
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
            context += "\n\(line)"
        }
        for note in store.notes.sorted(by: { $0.updatedAt > $1.updatedAt }) {
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
