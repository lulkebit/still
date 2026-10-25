import SwiftUI

private enum SettingsTab: String, CaseIterable, Identifiable, Hashable {
    case general
    case ai
    case confluence

    var id: Self { self }

    var title: String {
        switch self {
        case .general: L10n.text("settings.tab.general")
        case .ai: L10n.text("settings.tab.ai")
        case .confluence: L10n.text("settings.tab.confluence")
        }
    }

    var symbol: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .ai: "sparkles"
        case .confluence: "globe"
        }
    }
}

private enum SettingsInput: Hashable {
    case aiEndpoint
    case aiModel
    case aiKey
    case confluenceEndpoint
    case confluencePAT
}

private extension View {
    func settingsInput(isFocused: Bool) -> some View {
        textFieldStyle(.plain)
            .padding(.vertical, 5)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(isFocused ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.12))
                    .frame(height: isFocused ? 1 : 0.5)
                    .allowsHitTesting(false)
            }
    }
}

struct AISettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let appModel: StillAppModel
    @State private var selectedTab: SettingsTab = .general
    @FocusState private var focusedTab: SettingsTab?
    @FocusState private var focusedInput: SettingsInput?
    @AppStorage("appLanguage") private var appLanguage = "de"
    @State private var draft = AISettings.empty
    @State private var wikiEnabled = true
    @State private var confluenceDraft = ConfluenceSettings.empty
    @State private var apiKey = ""
    @State private var savedKey = ""
    @State private var hasSavedKey = false
    @State private var clearSavedKey = false
    @State private var confluencePAT = ""
    @State private var savedConfluencePAT = ""
    @State private var hasSavedConfluencePAT = false
    @State private var modelFetchTask: Task<Void, Never>?
    @State private var confluenceTestTask: Task<Void, Never>?
    @State private var confluenceTestID = UUID()
    @State private var isTestingConfluence = false
    @State private var confluenceTestMessage: String?
    @State private var confluenceTestSucceeded = false

    init(appModel: StillAppModel) { self.appModel = appModel }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.text("settings.title"))
                    .font(.system(size: 22, weight: .medium, design: .serif))
                Spacer()
                Button(L10n.text("action.done"), action: saveAndClose)
                    .buttonStyle(CalmButtonStyle()).pointerStyle(.link).calmHover()
                    .keyboardShortcut(.defaultAction).accessibilityIdentifier("save-ai-settings")
            }
            .padding(.bottom, 12)

            settingsTabBar
                .padding(.bottom, 12)

            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 0.5)
                .padding(.bottom, 12)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Color.clear
                            .frame(height: 1)
                            .id("settings-content-top")

                        ZStack(alignment: .topLeading) {
                            Group {
                                switch selectedTab {
                                case .general: generalSettings
                                case .ai: aiSettings
                                case .confluence: confluenceSettings
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 1)
                            .padding(.top, 2)
                            .padding(.bottom, 8)
                            .id(selectedTab)
                            .transition(settingsContentTransition)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.visible)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("settings-content")
                .onChange(of: selectedTab) { oldTab, newTab in
                    guard oldTab != newTab else { return }
                    withAnimation(nil) {
                        proxy.scrollTo("settings-content-top", anchor: .top)
                    }
                }
            }

            if let error = appModel.aiError {
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            }
        }
        .padding(24)
        .frame(width: 560, height: 570)
        .background {
            Group {
                if reduceTransparency {
                    Color(nsColor: .windowBackgroundColor)
                } else {
                    VisualEffectBackground()
                }
            }
            .ignoresSafeArea()
        }
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
        .onChange(of: confluenceDraft.baseURL) { _, baseURL in
            loadConfluencePAT(for: baseURL)
            clearConfluenceTestState()
        }
        .onChange(of: confluenceDraft.enabled) { _, _ in clearConfluenceTestState() }
        .onChange(of: confluencePAT) { _, _ in clearConfluenceTestState() }
        .onDisappear {
            modelFetchTask?.cancel()
            confluenceTestTask?.cancel()
        }
    }

    private var settingsTabBar: some View {
        HStack(spacing: 14) {
            ForEach(SettingsTab.allCases) { tab in
                let isSelected = selectedTab == tab
                VStack(spacing: 5) {
                    Button {
                        selectTab(tab)
                    } label: {
                        Label {
                            Text(tab.title)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        } icon: {
                            Image(systemName: tab.symbol)
                        }
                        .font(.system(size: 11, weight: isSelected ? .medium : .regular))
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                        .labelStyle(.titleAndIcon)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(CalmButtonStyle())
                    .pointerStyle(.link)
                    .focused($focusedTab, equals: tab)
                    .accessibilityLabel(tab.title)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    .accessibilityIdentifier("settings-tab-\(tab.rawValue)")

                    Rectangle()
                        .fill(focusedTab == tab ? Color.accentColor.opacity(0.75) : isSelected ? Color.primary.opacity(0.45) : .clear)
                        .frame(height: 1)
                        .animation(reduceMotion ? nil : CalmMotion.quick, value: isSelected)
                        .animation(reduceMotion ? nil : CalmMotion.quick, value: focusedTab == tab)
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(.bottom, 2)
        .accessibilityElement(children: .contain)
    }

    private var settingsContentTransition: AnyTransition {
        CalmMotion.reveal(reduceMotion: reduceMotion)
    }

    private func selectTab(_ tab: SettingsTab) {
        guard selectedTab != tab else { return }
        withAnimation(reduceMotion ? nil : CalmMotion.standard) {
            selectedTab = tab
        }
    }

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.text("settings.general.title"))
                    .font(.system(size: 15, weight: .medium))
                Text(L10n.text("settings.general.wikiDescription"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle(L10n.text("settings.general.wikiEnabled"), isOn: $wikiEnabled)
                .toggleStyle(.switch).font(.system(size: 13))
                .pointerStyle(.link).calmHover(cornerRadius: 6)
                .accessibilityIdentifier("wiki-enabled")
            Picker(L10n.text("settings.general.language"), selection: $appLanguage) {
                Text(L10n.text("settings.general.language.german")).tag("de")
            }
            .pickerStyle(.menu)
            .font(.system(size: 12))
            .pointerStyle(.link).calmHover(cornerRadius: 6)
            .accessibilityIdentifier("settings-language")
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var aiSettings: some View {
        VStack(alignment: .leading, spacing: 15) {
            Toggle(L10n.text("settings.ai.enabled"), isOn: $draft.enabled)
                .toggleStyle(.switch).font(.system(size: 13))
                .pointerStyle(.link).calmHover(cornerRadius: 6)
                .accessibilityIdentifier("ai-enabled")

            VStack(alignment: .leading, spacing: 13) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.text("settings.ai.endpoint"))
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    TextField(L10n.text("settings.ai.endpointPlaceholder"), text: $draft.baseURL)
                        .font(.system(size: 12)).disabled(!draft.enabled)
                        .focused($focusedInput, equals: .aiEndpoint)
                        .settingsInput(isFocused: focusedInput == .aiEndpoint)
                        .accessibilityIdentifier("ai-base-url")
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.text("settings.ai.model"))
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        TextField(L10n.text("settings.ai.modelPlaceholder"), text: $draft.model)
                            .font(.system(size: 12)).disabled(!draft.enabled)
                            .focused($focusedInput, equals: .aiModel)
                            .settingsInput(isFocused: focusedInput == .aiModel)
                            .accessibilityIdentifier("ai-model")
                        if !appModel.availableModels.isEmpty {
                            Menu {
                                ForEach(appModel.availableModels, id: \.self) { model in
                                    Button(model) { draft.model = model }
                                }
                            } label: {
                                Image(systemName: "chevron.down").font(.system(size: 11)).frame(width: 26, height: 26)
                            }
                            .menuStyle(.borderlessButton).disabled(!draft.enabled)
                            .pointerStyle(draft.enabled ? .link : nil).calmHover(isEnabled: draft.enabled)
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
                    Text(L10n.text("settings.ai.apiKey"))
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    SecureField(apiKeyPlaceholder, text: $apiKey)
                        .font(.system(size: 12)).disabled(!draft.enabled)
                        .focused($focusedInput, equals: .aiKey)
                        .settingsInput(isFocused: focusedInput == .aiKey)
                        .accessibilityIdentifier("ai-api-key")
                    if hasSavedKey && !clearSavedKey {
                        HStack(spacing: 8) {
                            Text(L10n.text("settings.ai.keyStatus"))
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                            Spacer()
                            Button(L10n.text("settings.ai.clearKey"), action: clearKey)
                                .buttonStyle(CalmButtonStyle()).pointerStyle(.link).calmHover()
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .opacity(draft.enabled ? 1 : 0.55)

            Text(String(format: L10n.text("settings.ai.explanation"), "\(AIClient.contextLimit)"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 3)
            if !draft.enabled {
                Text(L10n.text("settings.ai.disabledHint"))
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var confluenceSettings: some View {
        VStack(alignment: .leading, spacing: 15) {
            Toggle(L10n.text("settings.confluence.enabled"), isOn: $confluenceDraft.enabled)
                .toggleStyle(.switch).font(.system(size: 13))
                .pointerStyle(.link).calmHover(cornerRadius: 6)
                .accessibilityIdentifier("confluence-enabled")

            VStack(alignment: .leading, spacing: 13) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.text("settings.confluence.endpoint"))
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    TextField(L10n.text("settings.confluence.endpointPlaceholder"), text: $confluenceDraft.baseURL)
                        .font(.system(size: 12)).disabled(!confluenceDraft.enabled)
                        .focused($focusedInput, equals: .confluenceEndpoint)
                        .settingsInput(isFocused: focusedInput == .confluenceEndpoint)
                        .accessibilityIdentifier("confluence-base-url")
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.text("settings.confluence.pat"))
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    SecureField(confluencePATPlaceholder, text: $confluencePAT)
                        .font(.system(size: 12)).disabled(!confluenceDraft.enabled)
                        .focused($focusedInput, equals: .confluencePAT)
                        .settingsInput(isFocused: focusedInput == .confluencePAT)
                        .accessibilityIdentifier("confluence-pat")
                    if hasSavedConfluencePAT {
                        HStack(spacing: 8) {
                            Text(L10n.text("settings.confluence.patSaved"))
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                            Spacer()
                            Button(L10n.text("settings.confluence.removePAT"), action: removeConfluencePAT)
                                .buttonStyle(CalmButtonStyle()).pointerStyle(.link).calmHover()
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                                .accessibilityIdentifier("remove-confluence-pat")
                        }
                    }
                }
            }
            .opacity(confluenceDraft.enabled ? 1 : 0.55)

            Button(action: testConfluenceConnection) {
                HStack(spacing: 7) {
                    if isTestingConfluence { ProgressView().controlSize(.small) }
                    else { Image(systemName: "network") }
                    Text(L10n.text(isTestingConfluence ? "settings.confluence.testing" : "settings.confluence.test"))
                }
            }
            .buttonStyle(CalmButtonStyle()).disabled(!canTestConfluence)
            .pointerStyle(canTestConfluence ? .link : nil).calmHover(isEnabled: canTestConfluence)
            .accessibilityIdentifier("test-confluence-connection")

            if let confluenceTestMessage {
                Label(confluenceTestMessage, systemImage: confluenceTestSucceeded ? "checkmark.circle" : "exclamationmark.circle")
                    .font(.system(size: 11)).foregroundStyle(confluenceTestSucceeded ? Color.secondary : Color.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("confluence-test-status")
            }
            Text(L10n.text("settings.confluence.explanation"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 2)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var effectiveKey: String {
        if clearSavedKey { return "" }
        if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return apiKey }
        return savedKey
    }

    private var apiKeyPlaceholder: String {
        hasSavedKey && !clearSavedKey ? L10n.text("settings.ai.keyPlaceholder") : L10n.text("settings.ai.keyPlaceholderNew")
    }

    private var confluenceEffectivePAT: String {
        if !confluencePAT.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return confluencePAT }
        return savedConfluencePAT
    }

    private var confluencePATPlaceholder: String {
        hasSavedConfluencePAT ? L10n.text("settings.confluence.patPlaceholder") : L10n.text("settings.confluence.patPlaceholderNew")
    }

    private var canFetchModels: Bool {
        draft.enabled && !draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !appModel.isFetchingModels
    }

    private var canTestConfluence: Bool {
        confluenceDraft.enabled && !confluenceDraft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isTestingConfluence
    }

    private func loadDraft() {
        draft = appModel.store.settings
        wikiEnabled = appModel.store.wikiEnabled
        confluenceDraft = appModel.store.confluenceSettings
        savedKey = appModel.apiKeyForSettings()
        hasSavedKey = !savedKey.isEmpty
        clearSavedKey = false
        loadConfluencePAT(for: confluenceDraft.baseURL)
        if draft.enabled && !draft.baseURL.isEmpty { scheduleModelFetch() }
    }

    private func loadConfluencePAT(for baseURL: String) {
        confluencePAT = ""
        savedConfluencePAT = appModel.confluencePATForSettings(baseURL: baseURL)
        hasSavedConfluencePAT = !savedConfluencePAT.isEmpty
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

    private func removeConfluencePAT() {
        let baseURL = confluenceDraft.baseURL
        do {
            if hasSavedConfluencePAT { try appModel.removeConfluencePAT(baseURL: baseURL) }
            confluencePAT = ""
            savedConfluencePAT = ""
            hasSavedConfluencePAT = false
            confluenceDraft.enabled = false
            clearConfluenceTestState()
        } catch {
            confluenceTestMessage = L10n.message(for: error)
            confluenceTestSucceeded = false
        }
    }

    private func testConfluenceConnection() {
        confluenceTestTask?.cancel()
        let requestID = UUID()
        confluenceTestID = requestID
        let settings = confluenceDraft
        let pat = confluenceEffectivePAT
        isTestingConfluence = true
        confluenceTestMessage = nil
        confluenceTestTask = Task { @MainActor in
            defer {
                if confluenceTestID == requestID { isTestingConfluence = false }
            }
            do {
                try await appModel.testConfluenceConnection(settings: settings, pat: pat)
                guard confluenceTestID == requestID else { return }
                confluenceTestSucceeded = true
                confluenceTestMessage = L10n.text("settings.confluence.testSuccess")
            } catch {
                guard confluenceTestID == requestID else { return }
                confluenceTestSucceeded = false
                confluenceTestMessage = L10n.message(for: error)
            }
        }
    }

    private func clearConfluenceTestState() {
        confluenceTestTask?.cancel()
        confluenceTestID = UUID()
        isTestingConfluence = false
        confluenceTestMessage = nil
        confluenceTestSucceeded = false
    }

    private func saveAndClose() {
        do {
            try appModel.saveSettings(
                ai: draft,
                apiKey: effectiveKey,
                wikiEnabled: wikiEnabled,
                confluence: confluenceDraft,
                pat: confluenceEffectivePAT
            )
            dismiss()
        } catch { appModel.aiError = L10n.message(for: error) }
    }
}
