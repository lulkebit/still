import AppKit
import SwiftUI

enum AIReviewTarget: Equatable {
    case note(UUID)
    case task(UUID)

    var sourceID: UUID {
        switch self {
        case .note(let id), .task(let id): id
        }
    }

    var isTask: Bool {
        if case .task = self { return true }
        return false
    }
}

struct AIReviewRequest: Identifiable, Equatable {
    let id: UUID
    let target: AIReviewTarget
    let originalDocument: String
    let selectedText: String
    let range: NSRange
    let settingsSnapshot: AISettings
    let initialContextAnchorNoteID: UUID?
    var contextSelection = AIContextSelection()
    var contextAnchorNoteID: UUID?
    var proposedText: String?
    var generationID: UUID?
    var isGenerating = false
    var error: String?

    init(target: AIReviewTarget, originalDocument: String, selectedText: String,
         range: NSRange, settingsSnapshot: AISettings, contextAnchorNoteID: UUID?) {
        id = UUID()
        self.target = target
        self.originalDocument = originalDocument
        self.selectedText = selectedText
        self.range = range
        self.settingsSnapshot = settingsSnapshot
        self.initialContextAnchorNoteID = contextAnchorNoteID
        self.contextAnchorNoteID = contextAnchorNoteID
    }
}

@MainActor
struct AIReviewSheet: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable private var appModel: StillAppModel
    @State private var isSourcePickerPresented = false
    @State private var sourceQuery = ""

    init(appModel: StillAppModel) {
        self._appModel = Bindable(wrappedValue: appModel)
    }

    private var request: AIReviewRequest? { appModel.pendingAIReview }
    private var sourceNotes: [Note] { appModel.store.visibleNotes }
    private var filteredSourceNotes: [Note] {
        let query = sourceQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sourceNotes }
        return sourceNotes.filter { note in
            note.title.localizedCaseInsensitiveContains(query)
                || note.folders.joined(separator: " / ").localizedCaseInsensitiveContains(query)
        }
    }
    private func anchorNote(for request: AIReviewRequest) -> Note? {
        request.contextAnchorNoteID.flatMap { id in sourceNotes.first(where: { $0.id == id }) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 18)

            if let request {
                contextControls(for: request)
                    .padding(.bottom, 17)

                if let proposed = request.proposedText {
                    comparison(original: request.selectedText, proposed: proposed)
                        .frame(maxHeight: .infinity)
                        .padding(.bottom, 16)
                } else {
                    selectionPreview(request.selectedText)
                        .frame(maxHeight: .infinity)
                        .padding(.bottom, 16)
                }

                footer(for: request)
            } else {
                Spacer()
            }
        }
        .padding(24)
        .frame(width: 720, height: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .onDisappear { appModel.discardAIReview() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.text("ai.review.title"))
                    .font(.system(size: 22, weight: .medium, design: .serif))
                Text(L10n.text("ai.review.subtitle"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(L10n.text("ai.review.discard"), action: appModel.discardAIReview)
                .buttonStyle(CalmButtonStyle())
                .pointerStyle(.link)
                .calmHover(cornerRadius: 6)
                .keyboardShortcut(.cancelAction)
        }
    }

    @ViewBuilder
    private func contextControls(for request: AIReviewRequest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.text("ai.context.title"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker(L10n.text("ai.context.title"), selection: Binding(
                    get: { request.contextSelection.choice },
                    set: { appModel.setAIReviewContextChoice($0) }
                )) {
                    ForEach(AIContextChoice.allCases) { choice in
                        Text(L10n.text(choice.localizationKey))
                            .tag(choice)
                            .disabled((choice == .currentNote || choice == .currentFolder) && anchorNote(for: request) == nil)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .disabled(request.isGenerating)
            }

            if request.contextSelection.choice == .selectedSources {
                if sourceNotes.isEmpty {
                    Text(L10n.text("ai.context.noSources"))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                } else {
                    HStack(spacing: 8) {
                        Button {
                            isSourcePickerPresented.toggle()
                        } label: {
                            HStack(spacing: 6) {
                                Text(String(format: L10n.text("ai.context.selectedCount"), request.contextSelection.selectedSourceIDs.count))
                                Image(systemName: "chevron.down").font(.system(size: 8, weight: .medium))
                            }
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(CalmButtonStyle()).pointerStyle(.link).calmHover(cornerRadius: 5)
                        .disabled(request.isGenerating)
                        .popover(isPresented: $isSourcePickerPresented, arrowEdge: .bottom) {
                            sourcePicker(for: request)
                        }
                        Text(L10n.text("ai.context.visibleOnly"))
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                }
            } else {
                Text(contextSummary(for: request))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func selectionPreview(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("ai.review.original"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            ScrollView {
                Text(verbatim: text)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.07), lineWidth: 0.7))
        }
    }

    private func comparison(original: String, proposed: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if proposed == original {
                Text(L10n.text("ai.review.noChanges"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            HStack(alignment: .top, spacing: 12) {
                comparisonColumn(title: L10n.text("ai.review.original"), text: original)
                comparisonColumn(title: L10n.text("ai.review.proposed"), text: proposed)
            }
        }
    }

    private func comparisonColumn(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            ScrollView {
                Text(verbatim: text)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.07), lineWidth: 0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func footer(for request: AIReviewRequest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = request.error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if request.isGenerating {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(L10n.text("action.aiBusy"))
                }
                Spacer()
                if let proposed = request.proposedText {
                    Button(L10n.text("ai.review.regenerate")) {
                        appModel.generateAIReview()
                    }
                    .buttonStyle(CalmButtonStyle())
                    .pointerStyle(.link)
                    .calmHover(cornerRadius: 6)
                    .disabled(request.isGenerating)
                    Button {
                        appModel.acceptAIReview()
                    } label: {
                        Label(L10n.text("ai.review.accept"), systemImage: "checkmark")
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                    }
                    .buttonStyle(CalmButtonStyle())
                    .pointerStyle(.link)
                    .calmHover(cornerRadius: 6)
                    .keyboardShortcut(.defaultAction)
                    .disabled(request.isGenerating || proposed == request.selectedText)
                    .accessibilityIdentifier("ai-review-accept")
                } else {
                    Button(L10n.text(request.isGenerating ? "action.aiBusy" : "ai.review.generate")) {
                        appModel.generateAIReview()
                    }
                    .buttonStyle(CalmButtonStyle())
                    .pointerStyle(.link)
                    .calmHover(cornerRadius: 6)
                    .keyboardShortcut(.defaultAction)
                    .disabled(request.isGenerating || !canGenerate(request))
                    .accessibilityIdentifier("ai-review-generate")
                }
            }
        }
        .animation(reduceMotion ? nil : CalmMotion.quick, value: request.isGenerating)
    }

    private func canGenerate(_ request: AIReviewRequest) -> Bool {
        let hasAnchor = request.contextAnchorNoteID.map { id in sourceNotes.contains(where: { $0.id == id }) } == true
        let needsAnchor = request.contextSelection.choice == .currentNote || request.contextSelection.choice == .currentFolder
        guard request.contextSelection.choice != .selectedSources || !request.contextSelection.selectedSourceIDs.isEmpty else { return false }
        guard !needsAnchor || hasAnchor else { return false }
        return appModel.store.settings.enabled
            && !appModel.store.settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func contextSummary(for request: AIReviewRequest) -> String {
        let notes = AIContextPolicy.notes(for: request.contextSelection,
                                          anchorNoteID: request.contextAnchorNoteID,
                                          visibleNotes: sourceNotes)
        if request.contextSelection.choice == .none { return L10n.text("ai.context.noneDescription") }
        if request.contextSelection.choice == .selectedSources {
            return String(format: L10n.text("ai.context.selectedCount"), notes.count)
        }
        guard let anchor = anchorNote(for: request), !notes.isEmpty else {
            return L10n.text("ai.context.noCurrentSource")
        }
        if request.contextSelection.choice == .currentNote {
            return String(format: L10n.text("ai.context.anchorNote"), anchor.title)
        }
        let location = ([L10n.text(anchor.section == .wiki ? "nav.wiki" : "nav.notes")] + anchor.folders).joined(separator: " / ")
        return String(format: L10n.text("ai.context.anchorFolder"), location, notes.count)
    }

    private func sourcePicker(for request: AIReviewRequest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("ai.context.selectedSources"))
                .font(.system(size: 12, weight: .medium, design: .serif))
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(.tertiary)
                TextField(L10n.text("ai.context.searchSources"), text: $sourceQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .accessibilityIdentifier("ai-review-source-search")
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(filteredSourceNotes) { note in
                        let isSelected = request.contextSelection.selectedSourceIDs.contains(note.id)
                        Button {
                            appModel.toggleAIReviewSource(note.id)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 13)).foregroundStyle(isSelected ? .secondary : .tertiary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(note.title).font(.system(size: 11)).foregroundStyle(.primary).lineLimit(1)
                                    Text(([L10n.text(note.section == .wiki ? "nav.wiki" : "nav.notes")] + note.folders).joined(separator: " / "))
                                        .font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 7).padding(.vertical, 6).contentShape(Rectangle())
                        }
                        .buttonStyle(CalmButtonStyle()).pointerStyle(.link).calmHover(cornerRadius: 5)
                    }
                    if filteredSourceNotes.isEmpty {
                        Text(L10n.text("ai.context.noMatches"))
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 330, height: 310)
    }
}
