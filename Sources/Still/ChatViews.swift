import AppKit
import SwiftUI
import Textual

@MainActor
struct ChatView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let appModel: StillAppModel
    @Bindable private var chat: ChatCoordinator
    let onOpenSettings: () -> Void
    let onOpenSource: (ChatSource) -> Void
    let onOpenExternalLink: (URL) -> Void

    private var conversation: ChatConversation? { chat.activeConversation }
    private var contextAnchorNote: Note? {
        appModel.currentNoteID.flatMap { id in appModel.store.visibleNotes.first(where: { $0.id == id }) }
    }
    private var settings: AISettings { appModel.store.settings }
    private var selectedModel: String { settings.model.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isAIConfigured: Bool {
        settings.enabled && !selectedModel.isEmpty &&
        (try? AIEndpointNormalizer.endpoint(baseURL: settings.baseURL, kind: .chatCompletions)) != nil
    }
    private var currentRun: Bool {
        guard let conversation else { return false }
        return conversation.id == chat.runningConversationID
    }

    init(appModel: StillAppModel, onOpenSettings: @escaping () -> Void,
         onOpenSource: @escaping (ChatSource) -> Void, onOpenExternalLink: @escaping (URL) -> Void) {
        self.appModel = appModel
        self._chat = Bindable(wrappedValue: appModel.chat)
        self.onOpenSettings = onOpenSettings
        self.onOpenSource = onOpenSource
        self.onOpenExternalLink = onOpenExternalLink
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                if let conversation {
                    ChatTranscript(
                        conversation: conversation,
                        statusText: currentRun ? chat.statusText : nil,
                        isRunning: currentRun,
                        canRetry: isAIConfigured && !chat.isRunning,
                        isAIConfigured: isAIConfigured,
                        appModel: appModel,
                        onRetry: { chat.retry() },
                        onOpenSettings: onOpenSettings,
                        onOpenSource: onOpenSource,
                        onOpenExternalLink: onOpenExternalLink
                    )
                    .id(conversation.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .transition(CalmMotion.reveal(reduceMotion: reduceMotion))
                } else {
                    emptyConversation
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .transition(CalmMotion.reveal(reduceMotion: reduceMotion))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .animation(reduceMotion ? nil : CalmMotion.standard, value: chat.selectedConversationID)

            composer
                .padding(.bottom, 22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("chat-view")
    }

    private var emptyConversation: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.tertiary)
            Text(L10n.text("chat.emptyTitle"))
                .font(.system(size: 22, weight: .medium, design: .serif))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 40)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 9) {
            Group {
                if let error = appModel.chatStore.errorMessage {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("chat-store-error")
                        .transition(CalmMotion.reveal(reduceMotion: reduceMotion))
                }
            }
            .animation(reduceMotion ? nil : CalmMotion.standard, value: appModel.chatStore.errorMessage)

            Group {
                if let notice = chat.notice {
                    Label(notice, systemImage: "info.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("chat-notice")
                        .transition(CalmMotion.reveal(reduceMotion: reduceMotion))
                }
            }
            .animation(reduceMotion ? nil : CalmMotion.standard, value: chat.notice)

            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    ChatComposerTextView(text: $chat.draft, contextID: conversation?.id, isEditable: isAIConfigured) {
                        if chat.canSend { sendMessage() }
                    }
                    if chat.draft.isEmpty {
                        Text(L10n.text("chat.placeholder"))
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 12)
                            .padding(.top, 9)
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: 100)
                .accessibilityIdentifier("chat-composer")

                HStack(spacing: 12) {
                    Picker(L10n.text("chat.context.title"), selection: $chat.localContextScope) {
                        ForEach(ChatLocalContextScope.allCases) { scope in
                            Text(L10n.text(scope.localizationKey))
                                .tag(scope)
                                .disabled((scope == .currentNote || scope == .currentFolder) && contextAnchorNote == nil)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .accessibilityLabel(L10n.text("chat.context.title"))
                    .accessibilityIdentifier("chat-local-context")

                    Toggle(L10n.text("chat.context.confluence"), isOn: $chat.includeConfluenceInContext)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 10))
                        .disabled(!appModel.store.confluenceSettings.enabled)
                        .help(L10n.text(appModel.store.confluenceSettings.enabled
                                        ? "chat.context.confluenceHelp"
                                        : "chat.context.confluenceUnavailable"))
                        .accessibilityIdentifier("chat-confluence-context")
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 9)

                if chat.localContextScope == .currentNote || chat.localContextScope == .currentFolder {
                    Text(chatContextDescription)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                }

                Text(L10n.text("chat.context.historyNote"))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)

                HStack(spacing: 8) {
                    Text(selectedModel.isEmpty
                         ? L10n.text("chat.noModel")
                         : String(format: L10n.text("chat.model"), selectedModel))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .accessibilityIdentifier("chat-selected-model")
                    if !isAIConfigured {
                        Button(L10n.text("chat.configureAI"), action: onOpenSettings)
                            .font(.system(size: 11))
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .pointerStyle(.link)
                            .calmHover(cornerRadius: 5)
                            .accessibilityIdentifier("chat-open-settings")
                    }
                    Spacer(minLength: 8)

                    Group {
                        if currentRun {
                            Text(chat.statusText ?? L10n.text("chat.working"))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .accessibilityIdentifier("chat-running-status")
                                .transition(CalmMotion.reveal(reduceMotion: reduceMotion))
                        } else if chat.isRunning {
                            Text(L10n.text("chat.otherConversationRunning"))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .accessibilityIdentifier("chat-other-running-status")
                                .transition(CalmMotion.reveal(reduceMotion: reduceMotion))
                        }
                    }
                    .animation(reduceMotion ? nil : CalmMotion.quick, value: currentRun)
                    .animation(reduceMotion ? nil : CalmMotion.quick, value: chat.isRunning)

                    ZStack(alignment: .trailing) {
                        if currentRun {
                            Button(action: chat.cancel) {
                                Label(L10n.text("chat.stop"), systemImage: "stop.fill")
                                    .labelStyle(.titleAndIcon)
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .buttonStyle(CalmButtonStyle())
                            .pointerStyle(.link)
                            .calmHover(cornerRadius: 6)
                            .accessibilityIdentifier("chat-stop")
                            .transition(CalmMotion.reveal(reduceMotion: reduceMotion))
                        } else {
                            Button(action: sendMessage) {
                                Label(L10n.text("chat.send"), systemImage: "arrow.up")
                                    .labelStyle(.titleAndIcon)
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .buttonStyle(CalmButtonStyle())
                            .pointerStyle(chat.canSend ? .link : nil)
                            .calmHover(isEnabled: chat.canSend)
                            .disabled(!chat.canSend)
                            .accessibilityIdentifier("chat-send")
                            .transition(CalmMotion.reveal(reduceMotion: reduceMotion))
                        }
                    }
                    .frame(minWidth: 66, alignment: .trailing)
                    .animation(reduceMotion ? nil : CalmMotion.quick, value: currentRun)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
            }
            .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.07), lineWidth: 0.7))
        }
        .frame(maxWidth: 760)
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity)
    }

    private func sendMessage() {
        chat.send(context: ChatRequestContext(
            localScope: chat.localContextScope,
            anchorNoteID: appModel.currentNoteID,
            includeConfluence: chat.includeConfluenceInContext
        ))
    }

    private var chatContextDescription: String {
        guard let note = contextAnchorNote else { return L10n.text("chat.context.noCurrentNote") }
        let location = ([L10n.text(note.section == .wiki ? "nav.wiki" : "nav.notes")] + note.folders).joined(separator: " / ")
        if chat.localContextScope == .currentNote {
            return String(format: L10n.text("chat.context.anchorNote"), note.title, location)
        }
        let noteCount = ChatContextPolicy.allowedLocalNoteIDs(
            for: ChatRequestContext(localScope: .currentFolder,
                                    anchorNoteID: note.id,
                                    includeConfluence: false),
            visibleNotes: appModel.store.visibleNotes).count
        return String(format: L10n.text("chat.context.anchorFolder"), location, noteCount)
    }
}

@MainActor
private struct ChatTranscript: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isFollowingLatest = true
    let conversation: ChatConversation
    let statusText: String?
    let isRunning: Bool
    let canRetry: Bool
    let isAIConfigured: Bool
    let appModel: StillAppModel
    let onRetry: () -> Void
    let onOpenSettings: () -> Void
    let onOpenSource: (ChatSource) -> Void
    let onOpenExternalLink: (URL) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(conversation.title)
                    .font(.system(size: 24, weight: .medium, design: .serif))
                    .lineLimit(1)
                    .accessibilityIdentifier("chat-title")
                Spacer(minLength: 12)
            }
            .frame(maxWidth: 760)
            .padding(.horizontal, 32)
            .padding(.top, 22)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 23) {
                        ForEach(Array(conversation.messages.enumerated()), id: \.element.id) { index, message in
                            ChatMessageRow(
                                message: message,
                                isLastAssistantMessage: index == conversation.messages.count - 1 && message.role == .assistant,
                                isRunning: isRunning && message.status == .pending,
                                statusText: isRunning && message.status == .pending ? statusText : nil,
                                canRetry: canRetry,
                                isAIConfigured: isAIConfigured,
                                notes: appModel.store.visibleNotes,
                                store: appModel.store,
                                onRetry: onRetry,
                                onOpenSettings: onOpenSettings,
                                onOpenSource: onOpenSource,
                                onOpenExternalLink: onOpenExternalLink
                            )
                            .transition(CalmMotion.reveal(reduceMotion: reduceMotion))
                            .id(message.id)
                        }
                        Color.clear.frame(height: 1).id("chat-bottom")
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 32)
                    .padding(.top, 20)
                    .padding(.bottom, 20)
                    .animation(reduceMotion ? nil : CalmMotion.standard, value: conversation.messages.count)
                }
                .accessibilityIdentifier("chat-transcript")
                .onAppear { scrollToBottom(using: proxy) }
                .onScrollGeometryChange(for: Bool.self, of: { geometry in
                    geometry.contentSize.height - geometry.visibleRect.maxY < 96
                }) { _, nearBottom in
                    isFollowingLatest = nearBottom
                }
                .onChange(of: conversation.id) { _, _ in
                    isFollowingLatest = true
                    scrollToBottom(using: proxy)
                }
                .onChange(of: conversation.messages.count) { _, _ in
                    guard isFollowingLatest else { return }
                    scrollToBottom(using: proxy)
                }
                .onChange(of: conversation.messages.last?.content) { _, _ in
                    guard isFollowingLatest else { return }
                    scrollToBottom(using: proxy)
                }
            }
        }
    }

    private func scrollToBottom(using proxy: ScrollViewProxy) {
        DispatchQueue.main.async { proxy.scrollTo("chat-bottom", anchor: .bottom) }
    }
}

@MainActor
private struct ChatMessageRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let message: ChatMessage
    let isLastAssistantMessage: Bool
    let isRunning: Bool
    let statusText: String?
    let canRetry: Bool
    let isAIConfigured: Bool
    let notes: [Note]
    let store: StillStore
    let onRetry: () -> Void
    let onOpenSettings: () -> Void
    let onOpenSource: (ChatSource) -> Void
    let onOpenExternalLink: (URL) -> Void

    private var availableSources: [ChatSource] {
        message.sources.filter { ChatLinkPolicy.canOpen($0, notes: notes, store: store) }
    }

    var body: some View {
        Group {
            if message.role == .user {
                HStack(alignment: .top, spacing: 0) {
                    Spacer(minLength: 54)
                    messageContent
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
                        .frame(maxWidth: 590, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    messageContent
                    if isRunning && message.content.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(statusText ?? L10n.text("chat.working"))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    Group {
                        if message.status == .failed || message.status == .interrupted {
                            HStack(spacing: 10) {
                                Text(message.error ?? L10n.text(message.status == .failed ? "chat.answerFailed" : "chat.answerInterrupted"))
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                if isLastAssistantMessage && isAIConfigured {
                                    Button(L10n.text("chat.retry"), action: onRetry)
                                        .font(.system(size: 11, weight: .medium))
                                        .buttonStyle(.plain)
                                        .foregroundStyle(.secondary)
                                        .pointerStyle(canRetry ? .link : nil)
                                        .calmHover(isEnabled: canRetry)
                                        .disabled(!canRetry)
                                        .accessibilityIdentifier("chat-retry")
                                } else if isLastAssistantMessage {
                                    Button(L10n.text("chat.configureAI"), action: onOpenSettings)
                                        .font(.system(size: 11))
                                        .buttonStyle(.plain)
                                        .foregroundStyle(.secondary)
                                        .pointerStyle(.link)
                                        .calmHover(cornerRadius: 5)
                                }
                            }
                            .transition(CalmMotion.reveal(reduceMotion: reduceMotion))
                        }
                    }
                    .animation(reduceMotion ? nil : CalmMotion.standard, value: message.status)
                    ChatSourcesView(sources: availableSources, onOpen: onOpenSource)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityIdentifier("chat-message-\(message.role.rawValue)")
    }

    private var messageContent: some View {
        Group {
            if !message.content.isEmpty {
                StructuredText(markdown: message.content)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .textual.blockSpacing(.init(top: 4, bottom: 7))
                    .textual.overflowMode(.wrap)
                    .textual.imageAttachmentLoader(ChatImageAttachmentLoader())
                    .textual.textSelection(.enabled)
                    .environment(\.openURL, OpenURLAction { url in
                        guard let safeURL = ChatLinkPolicy.externalURL(url) else { return .discarded }
                        onOpenExternalLink(safeURL)
                        return .handled
                    })
            } else if message.role == .assistant && !isRunning {
                Text(L10n.text("chat.emptyAnswer"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ChatSourcesView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let sources: [ChatSource]
    let onOpen: (ChatSource) -> Void

    var body: some View {
        Group {
            if !sources.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.text("chat.sources"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) { sourceButtons }
                        VStack(alignment: .leading, spacing: 5) { sourceButtons }
                    }
                }
                .padding(.top, 2)
                .transition(CalmMotion.reveal(reduceMotion: reduceMotion))
            }
        }
        .animation(reduceMotion ? nil : CalmMotion.standard, value: sources.count)
    }

    @ViewBuilder private var sourceButtons: some View {
        ForEach(sources) { source in
            Button { onOpen(source) } label: {
                Label(source.title, systemImage: source.noteID == nil ? "link" : "doc.text")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .calmHover(cornerRadius: 4)
            .accessibilityIdentifier("chat-source-\(source.id)")
        }
    }
}

@MainActor
struct ChatSidebarContent: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let chatStore: ChatStore
    let chat: ChatCoordinator
    let onNewChat: () -> Void
    let onSelectConversation: (UUID) -> Void

    @State private var conversationToRename: ChatConversation?
    @State private var renameTitle = ""
    @State private var isRenaming = false
    @State private var conversationToDelete: ChatConversation?
    @State private var isConfirmingDelete = false

    private var sortedConversations: [ChatConversation] {
        chatStore.conversations.sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.text("chat.conversations").uppercased())
                    .font(.system(size: 10, weight: .medium))
                    .tracking(0.8)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 10)
                Spacer(minLength: 6)
            }
            .foregroundStyle(.secondary)
            .padding(.top, 22)
            .padding(.bottom, 7)

            Button(action: onNewChat) {
                Label(L10n.text("chat.new"), systemImage: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(CalmButtonStyle())
            .pointerStyle(.link)
            .calmHover(cornerRadius: 7)
            .accessibilityIdentifier("chat-new-conversation")

            ScrollView {
                LazyVStack(spacing: 2) {
                    if sortedConversations.isEmpty {
                        ChatEmptyListLabel(text: L10n.text("chat.noConversations"))
                    }
                    ForEach(sortedConversations) { conversation in
                        conversationRow(conversation)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.top, 8)
                .padding(.bottom, 8)
            }
            .accessibilityIdentifier("chat-conversation-list")
        }
        .sheet(isPresented: $isRenaming) {
            ChatRenameSheet(title: renameTitle) { title in
                if let conversationToRename {
                    chat.renameConversation(conversationToRename.id, title: title)
                }
            }
        }
        .confirmationDialog(
            L10n.text("chat.deleteTitle"),
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button(L10n.text("chat.delete"), role: .destructive) {
                if let conversationToDelete { chat.deleteConversation(conversationToDelete.id) }
                conversationToDelete = nil
            }
            .pointerStyle(.link)
            Button(L10n.text("action.cancel"), role: .cancel) { conversationToDelete = nil }
                .pointerStyle(.link)
        } message: {
            Text(L10n.text("chat.deleteBody"))
        }
    }

    private func conversationRow(_ conversation: ChatConversation) -> some View {
        HStack(spacing: 3) {
            Button { onSelectConversation(conversation.id) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(conversation.title)
                        .font(.system(size: 12, weight: chat.selectedConversationID == conversation.id ? .medium : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(conversation.updatedAt, style: .relative)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 9)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(CalmButtonStyle())
            .pointerStyle(.link)
            .calmHover(cornerRadius: 6)
            .accessibilityIdentifier("chat-conversation-\(conversation.id.uuidString)")

            Menu {
                Button(L10n.text("list.rename"), systemImage: "pencil") {
                    conversationToRename = conversation
                    renameTitle = conversation.title
                    isRenaming = true
                }
                Button(L10n.text("chat.delete"), systemImage: "trash", role: .destructive) {
                    conversationToDelete = conversation
                    isConfirmingDelete = true
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: 23, height: 26)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .pointerStyle(.link)
            .calmHover(cornerRadius: 5)
            .accessibilityLabel(String(format: L10n.text("chat.conversationActions"), conversation.title))
        }
        .background {
            RoundedRectangle(cornerRadius: 7)
                .fill(chat.selectedConversationID == conversation.id ? Color.primary.opacity(0.065) : .clear)
                .animation(reduceMotion ? nil : CalmMotion.quick, value: chat.selectedConversationID == conversation.id)
        }
    }
}

@MainActor
private struct ChatRenameSheet: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    @State private var title: String
    let onSave: (String) -> Void

    init(title: String, onSave: @escaping (String) -> Void) {
        self.onSave = onSave
        _title = State(initialValue: title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("chat.renameTitle"))
                .font(.system(size: 17, weight: .medium, design: .serif))
            TextField(L10n.text("dialog.namePlaceholder"), text: $title)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(save)
            HStack {
                Spacer()
                Button(L10n.text("action.cancel")) { dismiss() }
                    .pointerStyle(.link)
                    .calmHover()
                    .keyboardShortcut(.cancelAction)
                Button(L10n.text("action.save"), action: save)
                    .pointerStyle(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : .link)
                    .calmHover(isEnabled: !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 360)
        .onAppear { focused = true }
    }

    private func save() {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        onSave(value)
        dismiss()
    }
}

@MainActor
enum ChatLinkPolicy {
    static func externalURL(_ url: URL) -> URL? {
        guard !url.absoluteString.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), let checkedURL = components.url else { return nil }
        switch scheme {
        case "http", "https":
            guard let host = components.host, !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  components.user == nil, components.password == nil else { return nil }
        case "mailto":
            guard components.host == nil,
                  !components.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        default:
            return nil
        }
        return checkedURL
    }

    static func canOpen(_ source: ChatSource, notes: [Note], store: StillStore) -> Bool {
        if let noteID = source.noteID {
            guard let note = notes.first(where: { $0.id == noteID }) else { return false }
            return store.canAccess(note.section)
        }
        return source.url.flatMap(externalURL) != nil
    }
}

private struct ChatImageAttachmentLoader: AttachmentLoader {
    typealias Attachment = ChatImagePlaceholder

    func attachment(for _: URL, text: String, environment _: ColorEnvironmentValues) async throws -> ChatImagePlaceholder {
        ChatImagePlaceholder(text: text)
    }
}

private struct ChatImagePlaceholder: Textual.Attachment {
    let text: String

    var body: some View {
        Label(text.isEmpty ? L10n.text("chat.imageNotLoaded") : text,
              systemImage: "photo")
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
    }

    var description: String { text }

    func sizeThatFits(_ proposal: ProposedViewSize, in _: TextEnvironmentValues) -> CGSize {
        CGSize(width: min(proposal.width ?? 240, max(96, CGFloat(text.count * 6 + 28))), height: 18)
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.text == rhs.text }
    func hash(into hasher: inout Hasher) { hasher.combine(text) }
}

@MainActor
struct ChatComposerTextView: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var text: String
    var contextID: UUID?
    var isEditable: Bool
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false

        let textView = SubmitAwareTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textColor = .labelColor
        textView.font = .systemFont(ofSize: 13)
        textView.textContainerInset = NSSize(width: 9, height: 8)
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.onSubmit = onSubmit
        textView.isEditable = isEditable
        textView.string = text
        textView.draftContextID = contextID
        textView.setAccessibilityIdentifier("chat-composer-text")
        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.lastAppliedBinding = text
        context.coordinator.pendingContextID = contextID
        context.coordinator.pendingDraft = text
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? SubmitAwareTextView else { return }
        context.coordinator.parent = self
        scrollView.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        textView.onSubmit = onSubmit
        textView.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        textView.isEditable = isEditable
        context.coordinator.updateDraft(for: textView, draft: text, contextID: contextID)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatComposerTextView
        weak var textView: SubmitAwareTextView?
        var pendingExternalReset = false
        var pendingContextID: UUID?
        var pendingDraft = ""
        var lastAppliedBinding = ""

        init(_ parent: ChatComposerTextView) { self.parent = parent }

        @MainActor
        func updateDraft(for textView: SubmitAwareTextView, draft: String, contextID: UUID?) {
            if textView.hasMarkedText() {
                let hasExternalChange = textView.draftContextID != contextID || draft != lastAppliedBinding
                if hasExternalChange {
                    pendingExternalReset = true
                    pendingContextID = contextID
                    pendingDraft = draft
                }
                return
            }

            textView.synchronizeDraft(draft, contextID: contextID)
            pendingExternalReset = false
            pendingContextID = contextID
            pendingDraft = draft
            lastAppliedBinding = draft
        }

        @MainActor
        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? SubmitAwareTextView else { return }
            if pendingExternalReset {
                guard !textView.hasMarkedText() else { return }
                textView.synchronizeDraft(pendingDraft, contextID: pendingContextID)
                pendingExternalReset = false
                parent.text = pendingDraft
                lastAppliedBinding = pendingDraft
                return
            }
            parent.text = textView.string
            lastAppliedBinding = textView.string
        }
    }
}

@MainActor
final class SubmitAwareTextView: NSTextView {
    var onSubmit: () -> Void = {}
    var draftContextID: UUID?

    func synchronizeDraft(_ draft: String, contextID: UUID?) {
        let didChangeContext = draftContextID != contextID
        draftContextID = contextID
        guard didChangeContext || string != draft else { return }
        if string != draft {
            string = draft
            let end = (draft as NSString).length
            setSelectedRange(NSRange(location: end, length: 0))
        }
        undoManager?.removeAllActions()
    }

    override func keyDown(with event: NSEvent) {
        if (event.keyCode == 36 || event.keyCode == 76),
           !event.modifierFlags.contains(.shift),
           !hasMarkedText() {
            onSubmit()
            return
        }
        super.keyDown(with: event)
    }
}

private struct ChatEmptyListLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 18)
    }
}
