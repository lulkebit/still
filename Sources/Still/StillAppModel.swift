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
    var currentNoteID: UUID?
    var pendingAIReview: AIReviewRequest?
    private(set) var lastAIContextCharacters = 0
    private(set) var editorDocumentID: UUID?

    @ObservationIgnored private let aiClient: AIClient
    @ObservationIgnored private let keyStore: any CredentialStore
    @ObservationIgnored private let confluenceKeys: (String) throws -> any CredentialStore
    @ObservationIgnored private var actionRequestID = UUID()
    @ObservationIgnored private var activeAIActionID: UUID?
    @ObservationIgnored private var modelRequestID = UUID()
    @ObservationIgnored weak var editorCommands: EditorCommandBus?
    @ObservationIgnored private var aiReviewApplyHandlers: [UUID: (String) -> Bool] = [:]
    @ObservationIgnored private var aiReviewTask: Task<Void, Never>?

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
        observeAIReviewInvalidation()
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
        invalidateAIAction()
        discardAIReview()
        chat.configurationDidChange()
        clearAvailableModels()
        aiError = nil
        feedback = L10n.text("settings.ai.saved")
    }

    func removeAPIKey() throws {
        try keyStore.write("")
        invalidateAIAction()
        discardAIReview()
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

    func performAIAction(_ action: String, noteID: UUID, selectedText: String,
                         context suppliedContext: String? = nil,
                         actionOwnerID: UUID? = nil) async throws -> AIActionOutcome {
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
        let requestID = actionOwnerID ?? UUID()
        actionRequestID = requestID
        activeAIActionID = requestID
        let settings = store.settings
        let wikiEnabled = store.wikiEnabled
        aiBusy = true
        aiError = nil
        feedback = nil
        defer {
            if activeAIActionID == requestID {
                activeAIActionID = nil
                aiBusy = false
            }
        }

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
        let context = suppliedContext ?? aiContext()
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

    func editorDocumentDidChange(_ id: UUID?) {
        editorDocumentID = id
        guard let request = pendingAIReview, case .note(let noteID) = request.target,
              id != noteID else { return }
        discardAIReview()
    }

    @discardableResult
    func beginAIReview(target: AIReviewTarget, originalDocument: String, selectedText: String,
                       range: NSRange, applyTaskReplacement: ((String) -> Bool)? = nil) -> Bool {
        guard store.settings.enabled,
              !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              TaskTextSelectionSnapshot(text: selectedText, range: range).matches(originalDocument),
              sourceDocument(for: target) == originalDocument else {
            aiError = L10n.text("error.aiSelectionChanged")
            return false
        }
        if case .note(let id) = target, editorDocumentID != id {
            aiError = L10n.text("error.aiSelectionChanged")
            return false
        }
        if target.isTask && applyTaskReplacement == nil {
            aiError = L10n.text("error.aiSelectionChanged")
            return false
        }

        discardAIReview()
        let anchor = target.isTask ? currentNoteID : target.sourceID
        var request = AIReviewRequest(target: target, originalDocument: originalDocument,
                                      selectedText: selectedText, range: range,
                                      settingsSnapshot: store.settings, contextAnchorNoteID: anchor)
        if anchor == nil { request.contextSelection.choice = .none }
        pendingAIReview = request
        if let applyTaskReplacement { aiReviewApplyHandlers[request.id] = applyTaskReplacement }
        return true
    }

    func setAIReviewContextChoice(_ choice: AIContextChoice) {
        guard var request = pendingAIReview, !request.isGenerating,
              request.contextSelection.choice != choice else { return }
        request.contextSelection.choice = choice
        request.proposedText = nil
        request.error = nil
        pendingAIReview = request
    }

    func toggleAIReviewSource(_ id: UUID) {
        guard var request = pendingAIReview, !request.isGenerating,
              store.visibleNotes.contains(where: { $0.id == id }) else { return }
        if !request.contextSelection.selectedSourceIDs.insert(id).inserted {
            request.contextSelection.selectedSourceIDs.remove(id)
        }
        request.proposedText = nil
        request.error = nil
        pendingAIReview = request
    }

    func generateAIReview() {
        guard var request = pendingAIReview, !request.isGenerating else { return }
        guard isAIReviewValid(request) else {
            aiError = L10n.text("error.aiSelectionChanged")
            discardAIReview()
            return
        }
        if request.contextSelection.choice == .currentNote || request.contextSelection.choice == .currentFolder {
            let anchorID = request.target.isTask ? currentNoteID : request.target.sourceID
            guard let anchorID, store.visibleNotes.contains(where: { $0.id == anchorID }) else {
                request.error = L10n.text("ai.context.noCurrentSource")
                pendingAIReview = request
                return
            }
            request.contextAnchorNoteID = anchorID
        }
        if request.contextSelection.choice == .selectedSources {
            let visibleIDs = Set(store.visibleNotes.map(\.id))
            request.contextSelection.selectedSourceIDs.formIntersection(visibleIDs)
            guard !request.contextSelection.selectedSourceIDs.isEmpty else {
                request.error = L10n.text("ai.context.noSources")
                pendingAIReview = request
                return
            }
        }

        let generationID = UUID()
        request.generationID = generationID
        request.contextAnchorNoteID = request.target.isTask ? currentNoteID : request.target.sourceID
        request.proposedText = nil
        request.error = nil
        request.isGenerating = true
        pendingAIReview = request
        let context = AIContextPolicy.makeContext(
            for: request.contextSelection,
            anchorNoteID: request.contextAnchorNoteID,
            visibleNotes: store.visibleNotes,
            visibleFolders: store.visibleFolders,
            limit: AIClient.contextLimit
        )
        aiReviewTask?.cancel()
        aiReviewTask = Task { [weak self] in
            guard let self else { return }
            await self.generateAIReview(request: request, context: context, generationID: generationID)
        }
    }

    func acceptAIReview() {
        guard let request = pendingAIReview, let proposedText = request.proposedText,
              isAIReviewValid(request) else {
            aiError = L10n.text("error.aiSelectionChanged")
            discardAIReview()
            return
        }

        switch request.target {
        case .note(let id):
            guard editorDocumentID == id, let editorCommands, editorCommands.hasActiveEditor else {
                aiError = L10n.text("error.aiSelectionChanged")
                discardAIReview()
                return
            }
            editorCommands.send(.replaceSelection(original: request.selectedText,
                                                  replacement: proposedText,
                                                  range: request.range,
                                                  documentID: id))
            finishAIReview(request)
        case .task:
            guard let apply = aiReviewApplyHandlers[request.id], apply(proposedText) else {
                aiError = L10n.text("error.aiSelectionChanged")
                discardAIReview()
                return
            }
            finishAIReview(request)
        }
    }

    func discardAIReview() {
        guard let request = pendingAIReview else {
            if aiReviewTask != nil {
                aiReviewTask?.cancel()
                aiReviewTask = nil
                invalidateAIAction()
            }
            aiReviewApplyHandlers.removeAll()
            return
        }
        aiReviewTask?.cancel()
        aiReviewTask = nil
        if let generationID = request.generationID {
            invalidateAIAction(ownerID: generationID)
        }
        aiReviewApplyHandlers[request.id] = nil
        pendingAIReview = nil
    }

    private func generateAIReview(request: AIReviewRequest, context: String, generationID: UUID) async {
        guard !Task.isCancelled,
              pendingAIReview?.id == request.id,
              pendingAIReview?.generationID == generationID else { return }
        do {
            let outcome = try await performAIAction("optimize", noteID: request.target.sourceID,
                                                    selectedText: request.selectedText, context: context,
                                                    actionOwnerID: generationID)
            guard pendingAIReview?.id == request.id,
                  pendingAIReview?.generationID == generationID else { return }
            guard isAIReviewValid(request) else {
                aiError = L10n.text("error.aiSelectionChanged")
                discardAIReview()
                return
            }
            guard case .optimized(let replacement) = outcome, var current = pendingAIReview else { return }
            current.proposedText = replacement
            current.isGenerating = false
            current.error = nil
            pendingAIReview = current
            aiReviewTask = nil
        } catch {
            guard pendingAIReview?.id == request.id,
                  pendingAIReview?.generationID == generationID,
                  var current = pendingAIReview else { return }
            current.isGenerating = false
            current.error = L10n.message(for: error)
            pendingAIReview = current
            aiReviewTask = nil
        }
    }

    private func finishAIReview(_ request: AIReviewRequest) {
        aiReviewTask?.cancel()
        aiReviewTask = nil
        aiReviewApplyHandlers[request.id] = nil
        pendingAIReview = nil
    }

    private func invalidateAIAction(ownerID: UUID? = nil) {
        guard ownerID == nil || activeAIActionID == ownerID else { return }
        actionRequestID = UUID()
        activeAIActionID = nil
        aiBusy = false
    }

    private func isAIReviewValid(_ request: AIReviewRequest) -> Bool {
        guard store.settings.enabled, store.settings == request.settingsSnapshot,
              sourceDocument(for: request.target) == request.originalDocument,
              TaskTextSelectionSnapshot(text: request.selectedText, range: request.range)
                .matches(request.originalDocument) else { return false }
        if case .note(let id) = request.target, editorDocumentID != id { return false }
        if request.contextSelection.choice == .selectedSources {
            let visibleIDs = Set(store.visibleNotes.map(\.id))
            guard request.contextSelection.selectedSourceIDs.isSubset(of: visibleIDs) else { return false }
        }
        if request.target.isTask,
           request.contextSelection.choice == .currentNote || request.contextSelection.choice == .currentFolder,
           request.initialContextAnchorNoteID != currentNoteID { return false }
        return true
    }

    private func sourceDocument(for target: AIReviewTarget) -> String? {
        switch target {
        case .note(let id):
            guard let note = store.visibleNotes.first(where: { $0.id == id }), store.canAccess(note.section) else { return nil }
            return note.markdown
        case .task(let id):
            return store.tasks.first(where: { $0.id == id })?.detail
        }
    }

    private func invalidatePendingAIReviewIfStale() {
        guard let request = pendingAIReview, !isAIReviewValid(request) else { return }
        discardAIReview()
    }

    private func observeAIReviewInvalidation() {
        withObservationTracking {
            _ = store.settings
            _ = store.wikiEnabled
            _ = store.notes
            _ = store.tasks
            _ = store.visibleNotes
            _ = currentNoteID
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self else { return }
                self.invalidatePendingAIReviewIfStale()
                self.observeAIReviewInvalidation()
            }
        }
    }
}

enum AIActionOutcome {
    case wiki([Note])
    case optimized(String)
}
