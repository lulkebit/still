import SwiftUI

struct AISettingsView: View {
    @Environment(\.dismiss) private var dismiss
    let appModel: StillAppModel
    @State private var draft = AISettings.empty
    @State private var apiKey = ""
    @State private var savedKey = ""
    @State private var hasSavedKey = false
    @State private var clearSavedKey = false
    @State private var modelFetchTask: Task<Void, Never>?

    init(appModel: StillAppModel) { self.appModel = appModel }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.text("settings.title")).font(.system(size: 22, weight: .medium, design: .serif))
                Spacer()
                Button(L10n.text("action.done")) { saveAndClose() }
                    .buttonStyle(CalmButtonStyle()).pointerStyle(.link).calmHover()
                    .keyboardShortcut(.defaultAction).accessibilityIdentifier("save-ai-settings")
            }
            .padding(.bottom, 22)

            Toggle(L10n.text("settings.ai.enabled"), isOn: $draft.enabled)
                .toggleStyle(.switch).font(.system(size: 13)).padding(.bottom, 18)
                .pointerStyle(.link).calmHover(cornerRadius: 6)
                .accessibilityIdentifier("ai-enabled")

            VStack(alignment: .leading, spacing: 13) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.text("settings.ai.endpoint")).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    TextField(L10n.text("settings.ai.endpointPlaceholder"), text: $draft.baseURL)
                        .textFieldStyle(.roundedBorder).font(.system(size: 12)).disabled(!draft.enabled)
                        .accessibilityIdentifier("ai-base-url")
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.text("settings.ai.model")).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        TextField(L10n.text("settings.ai.modelPlaceholder"), text: $draft.model)
                            .textFieldStyle(.roundedBorder).font(.system(size: 12)).disabled(!draft.enabled)
                            .accessibilityIdentifier("ai-model")
                        if !appModel.availableModels.isEmpty {
                            Menu {
                                ForEach(appModel.availableModels, id: \.self) { model in
                                    Button(model) { draft.model = model }
                                }
                            } label: { Image(systemName: "chevron.down").font(.system(size: 11)).frame(width: 26, height: 26) }
                            .menuStyle(.borderlessButton).disabled(!draft.enabled)
                            .pointerStyle(draft.enabled ? .link : nil)
                            .calmHover(isEnabled: draft.enabled)
                            .accessibilityLabel(L10n.text("settings.ai.chooseModel"))
                        }
                        Button {
                            modelFetchTask?.cancel()
                            Task { await appModel.refreshModels(settings: draft, apiKey: effectiveKey) }
                        } label: {
                            if appModel.isFetchingModels { ProgressView().controlSize(.small).frame(width: 22) }
                            else { Image(systemName: "arrow.clockwise").font(.system(size: 11)).frame(width: 22) }
                        }
                        .buttonStyle(CalmButtonStyle()).disabled(!canFetchModels)
                        .pointerStyle(canFetchModels ? .link : nil).calmHover(isEnabled: canFetchModels)
                        .help(L10n.text("settings.ai.fetchModels"))
                        .accessibilityIdentifier("fetch-ai-models")
                    }
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.text("settings.ai.apiKey")).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    SecureField(apiKeyPlaceholder, text: $apiKey)
                        .textFieldStyle(.roundedBorder).font(.system(size: 12)).disabled(!draft.enabled)
                        .accessibilityIdentifier("ai-api-key")
                    if hasSavedKey && !clearSavedKey {
                        HStack(spacing: 8) {
                            Text(L10n.text("settings.ai.keyStatus")).font(.system(size: 10)).foregroundStyle(.secondary)
                            Spacer()
                            Button(L10n.text("settings.ai.clearKey")) { clearKey() }
                                .buttonStyle(CalmButtonStyle()).pointerStyle(.link).calmHover()
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .opacity(draft.enabled ? 1 : 0.55)

            Text(String(format: L10n.text("settings.ai.explanation"), "\(AIClient.contextLimit)"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 19)
            if !draft.enabled {
                Text(L10n.text("settings.ai.disabledHint"))
                    .font(.system(size: 11)).foregroundStyle(.tertiary).padding(.top, 9)
            }
            if let error = appModel.aiError {
                Text(error).font(.system(size: 11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true).padding(.top, 12)
            }
            Spacer(minLength: 0)
        }
        .padding(26).frame(width: 490, height: 490)
        .onAppear(perform: loadDraft)
        .onChange(of: draft.enabled) { _, enabled in
            if enabled { scheduleModelFetch() } else { modelFetchTask?.cancel() }
        }
        .onChange(of: draft.baseURL) { _, _ in
            appModel.clearAvailableModels()
            scheduleModelFetch()
        }
        .onChange(of: apiKey) { _, _ in
            appModel.clearAvailableModels()
            scheduleModelFetch()
        }
        .onDisappear { modelFetchTask?.cancel() }
    }

    private var effectiveKey: String {
        if clearSavedKey { return "" }
        if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return apiKey }
        return savedKey
    }

    private var apiKeyPlaceholder: String {
        hasSavedKey && !clearSavedKey ? L10n.text("settings.ai.keyPlaceholder") : L10n.text("settings.ai.keyPlaceholderNew")
    }

    private var canFetchModels: Bool {
        draft.enabled && !draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !appModel.isFetchingModels
    }

    private func loadDraft() {
        draft = appModel.store.settings
        savedKey = appModel.apiKeyForSettings()
        hasSavedKey = !savedKey.isEmpty
        clearSavedKey = false
        if draft.enabled && !draft.baseURL.isEmpty { scheduleModelFetch() }
    }

    private func scheduleModelFetch() {
        modelFetchTask?.cancel()
        guard draft.enabled, !draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let settings = draft
        let key = effectiveKey
        modelFetchTask = Task {
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled else { return }
            await appModel.refreshModels(settings: settings, apiKey: key)
        }
    }

    private func clearKey() {
        do {
            try appModel.removeAPIKey()
            hasSavedKey = false
            savedKey = ""
            apiKey = ""
            clearSavedKey = true
            scheduleModelFetch()
        } catch { appModel.aiError = L10n.message(for: error) }
    }

    private func saveAndClose() {
        do {
            try appModel.saveAISettings(draft, apiKey: effectiveKey)
            dismiss()
        } catch { appModel.aiError = L10n.message(for: error) }
    }
}
