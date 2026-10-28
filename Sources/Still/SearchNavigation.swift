import AppKit
import SwiftUI

enum SearchTarget: Hashable {
    case note(UUID)
    case task(UUID)
    case embeddedTask(noteID: UUID)
}

@MainActor
struct SearchHit: Identifiable {
    let id: String
    let target: SearchTarget
    let title: String
    let subtitle: String
    let icon: String
    let snippet: String?
    let contentMatch: Bool
    let findQuery: String?
    let favorite: Bool
    let updatedAt: Date
    let rank: Int

    init(note: Note, store: StillStore, query: String = "", rank: Int = 0, contentMatch: Bool = false) {
        id = "note:\(note.id.uuidString)"
        target = .note(note.id)
        title = note.title
        let root = L10n.text(note.section == .wiki ? "nav.wiki" : "nav.notes")
        subtitle = note.folders.isEmpty ? root : "\(root)  /  \(note.folders.joined(separator: " / "))"
        icon = note.section == .wiki ? "books.vertical" : "note.text"
        snippet = SearchIndex.snippet(in: note.markdown, query: query)
        self.contentMatch = contentMatch
        findQuery = SearchIndex.findQuery(in: note.markdown, query: query, includesPhrase: contentMatch)
        favorite = store.isFavoriteNote(note.id)
        updatedAt = note.updatedAt
        self.rank = rank
    }

    init(task: TaskItem, query: String = "", rank: Int = 0, contentMatch: Bool = false) {
        id = "task:\(task.id.uuidString)"
        target = .task(task.id)
        title = task.title
        subtitle = L10n.text("task.standalone")
        icon = "checklist"
        snippet = SearchIndex.snippet(in: task.detail, query: query)
        self.contentMatch = contentMatch
        findQuery = SearchIndex.findQuery(in: task.detail, query: query, includesPhrase: contentMatch)
        favorite = false
        updatedAt = task.updatedAt
        self.rank = rank
    }

    init(task: EmbeddedTask, store: StillStore, query: String = "", rank: Int = 0, contentMatch: Bool = false) {
        id = "embedded:\(task.id)"
        target = .embeddedTask(noteID: task.noteID)
        title = task.title
        subtitle = String(format: L10n.text("task.source"), task.noteTitle)
        icon = "checkmark.square"
        snippet = SearchIndex.snippet(in: task.line, query: query)
        self.contentMatch = contentMatch
        findQuery = SearchIndex.findQuery(in: task.line, query: query, includesPhrase: contentMatch)
        favorite = false
        updatedAt = store.visibleNotes.first(where: { $0.id == task.noteID })?.updatedAt ?? .distantPast
        self.rank = rank
    }
}

@MainActor
enum SearchIndex {
    static func results(query: String, store: StillStore) -> [SearchHit] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        var hits: [SearchHit] = []

        for note in store.visibleNotes {
            let titleHits = matchingTermCount(in: note.title, terms: terms)
            let titleMatches = titleHits == terms.count
            let contentMatches = contains(note.markdown, query)
            let contentTermsMatch = containsAllTerms(note.markdown, terms)
            let combinedMatches = containsAllTerms(note.title + "\n" + note.markdown, terms)
            guard titleMatches || contentTermsMatch || combinedMatches else { continue }
            hits.append(SearchHit(note: note, store: store, query: query,
                                  rank: titleRank(title: note.title, query: query, terms: terms),
                                  contentMatch: contentMatches))
        }

        for task in store.tasks {
            let titleHits = matchingTermCount(in: task.title, terms: terms)
            let titleMatches = titleHits == terms.count
            let contentMatches = contains(task.detail, query)
            let contentTermsMatch = containsAllTerms(task.detail, terms)
            let combinedMatches = containsAllTerms(task.title + "\n" + task.detail, terms)
            guard titleMatches || contentTermsMatch || combinedMatches else { continue }
            hits.append(SearchHit(task: task, query: query,
                                  rank: titleRank(title: task.title, query: query, terms: terms),
                                  contentMatch: contentMatches))
        }

        for task in store.embeddedTasks {
            let titleHits = matchingTermCount(in: task.title, terms: terms)
            let titleMatches = titleHits == terms.count
            let sourceMatches = matchingTermCount(in: task.noteTitle, terms: terms) == terms.count
            let contentMatches = contains(task.line, query)
            let contentTermsMatch = containsAllTerms(task.line, terms)
            let combinedMatches = containsAllTerms(task.title + "\n" + task.noteTitle + "\n" + task.line, terms)
            guard titleMatches || sourceMatches || contentTermsMatch || combinedMatches else { continue }
            let rank = titleMatches ? titleRank(title: task.title, query: query, terms: terms)
                : (sourceMatches ? 45 : 100)
            hits.append(SearchHit(task: task, store: store, query: query, rank: rank,
                                  contentMatch: contentMatches))
        }

        let recentPosition = Dictionary(uniqueKeysWithValues: store.recentNoteIDs.enumerated().map { ($1, $0) })
        return hits.sorted { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            if lhs.favorite != rhs.favorite { return lhs.favorite }
            let leftRecent = targetNoteID(lhs.target).flatMap { recentPosition[$0] } ?? Int.max
            let rightRecent = targetNoteID(rhs.target).flatMap { recentPosition[$0] } ?? Int.max
            if leftRecent != rightRecent { return leftRecent < rightRecent }
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            let titleOrder = lhs.title.localizedStandardCompare(rhs.title)
            if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
            return lhs.id < rhs.id
        }
    }

    static func titleRank(title: String, query: String, terms: [String]) -> Int {
        if title.compare(query, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame { return 0 }
        if title.range(of: query, options: [.caseInsensitive, .diacriticInsensitive])?.lowerBound == title.startIndex { return 10 }
        if contains(title, query) { return 20 }
        let matched = matchingTermCount(in: title, terms: terms)
        return matched == terms.count ? 30 : 40 + (terms.count - matched)
    }

    static func snippet(in source: String, query: String) -> String? {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let candidates = source.components(separatedBy: .newlines).map {
            plainText($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { line in
            !line.isEmpty && terms.contains(where: { term in contains(line, term) })
        }
        guard let clean = candidates.max(by: { matchingTermCount(in: $0, terms: terms) < matchingTermCount(in: $1, terms: terms) }) else {
            return nil
        }
        let match = clean.range(of: query, options: [.caseInsensitive, .diacriticInsensitive])
            ?? terms.lazy.compactMap { clean.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) }.first
        guard let match else { return String(clean.prefix(140)) }
        let before = String(clean[..<match.lowerBound].suffix(56))
        let after = String(clean[match.upperBound...].prefix(72))
        let excerpt = before + String(clean[match]) + after
        return (before.count < clean.distance(from: clean.startIndex, to: match.lowerBound) ? "…" : "")
            + excerpt
            + (after.count < clean.distance(from: match.upperBound, to: clean.endIndex) ? "…" : "")
    }

    static func findQuery(in source: String, query: String, includesPhrase: Bool) -> String? {
        guard !query.isEmpty else { return nil }
        if includesPhrase { return query }
        return query.split(whereSeparator: \.isWhitespace).map(String.init).first { contains(source, $0) }
    }

    static func plainText(_ markdown: String) -> String {
        var text = markdown
        for (pattern, replacement) in [
            (#"^\s{0,3}#{1,6}\s+"#, ""),
            (#"^\s{0,3}>\s?"#, ""),
            (#"^\s*[-*+]\s+(?:\[[ xX]\]\s+)?"#, ""),
            (#"\[([^\]]+)\]\([^)]+\)"#, "$1"),
            (#"[*_~`]"#, "")
        ] {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return text
    }

    private static func targetNoteID(_ target: SearchTarget) -> UUID? {
        switch target {
        case .note(let id): id
        case .embeddedTask(let noteID): noteID
        case .task: nil
        }
    }

    private static func matchingTermCount(in text: String, terms: [String]) -> Int {
        terms.filter { contains(text, $0) }.count
    }

    private static func containsAllTerms(_ text: String, _ terms: [String]) -> Bool {
        !terms.isEmpty && matchingTermCount(in: text, terms: terms) == terms.count
    }

    private static func contains(_ text: String, _ query: String) -> Bool {
        text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}

struct GlobalSearchBoard: View {
    let store: StillStore
    let query: String
    @Binding var selectedIndex: Int
    let onOpenNote: (UUID, String?) -> Void
    let onOpenTask: (UUID) -> Void
    let onOpenEmbeddedTask: (UUID, String?) -> Void

    private var results: [SearchHit] { SearchIndex.results(query: query, store: store) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.text("list.searchResults"))
                        .font(.system(size: 21, weight: .medium, design: .serif))
                    Text(query).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(results.count)").font(.system(size: 11, design: .rounded)).foregroundStyle(.tertiary)
            }
            .padding(.bottom, 18)
            if results.isEmpty {
                Text(L10n.text("list.noSearchResults"))
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, hit in
                                SearchResultRow(hit: hit, query: query, selected: selectedIndex == index, onOpen: { open(hit) })
                                    .id(hit.id)
                                    .overlay(alignment: .bottom) {
                                        Rectangle().fill(Color.primary.opacity(0.04)).frame(height: 0.5)
                                    }
                                }
                        }
                    }
                    .onChange(of: selectedIndex) { _, index in
                        guard results.indices.contains(index) else { return }
                        proxy.scrollTo(results[index].id, anchor: .center)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 52).padding(.top, 58).padding(.bottom, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: query) { _, _ in selectedIndex = 0 }
        .onChange(of: results.count) { _, count in selectedIndex = count == 0 ? 0 : min(selectedIndex, count - 1) }
    }

    private func open(_ hit: SearchHit) {
        switch hit.target {
        case .note(let id): onOpenNote(id, hit.findQuery)
        case .task(let id): onOpenTask(id)
        case .embeddedTask(let noteID): onOpenEmbeddedTask(noteID, hit.findQuery)
        }
    }
}

struct QuickOpenOverlay: View {
    let store: StillStore
    let onClose: () -> Void
    let onOpenNote: (UUID, String?) -> Void
    let onOpenTask: (UUID) -> Void
    let onOpenEmbeddedTask: (UUID, String?) -> Void
    @State private var focusController = QuickOpenFocusController()
    @State private var query = ""
    @State private var selectedIndex = 0

    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var favoriteHits: [SearchHit] { store.favoriteNotes.map { SearchHit(note: $0, store: store) } }
    private var recentHits: [SearchHit] {
        let favorites = Set(store.favoriteNoteIDs)
        return store.recentNotes.filter { !favorites.contains($0.id) }.map { SearchHit(note: $0, store: store) }
    }
    private var visibleHits: [SearchHit] {
        isSearching ? SearchIndex.results(query: query, store: store) : favoriteHits + recentHits
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.17).ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: cancel)

            VStack(spacing: 0) {
                HStack(spacing: 11) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .regular)).foregroundStyle(.secondary)
                    QuickOpenTextField(text: $query, placeholder: L10n.text("quickOpen.placeholder"),
                                       focusController: focusController,
                                       onMove: moveSelection, onCommit: openSelected, onCancel: cancel)
                        .frame(height: 26)
                    Text("⌘K").font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 17).padding(.vertical, 14)

                Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            if !isSearching {
                                if !favoriteHits.isEmpty {
                                    sectionTitle("quickOpen.favorites")
                                    ForEach(Array(favoriteHits.enumerated()), id: \.element.id) { index, hit in
                                        row(hit, at: index)
                                    }
                                }
                                if !recentHits.isEmpty {
                                    sectionTitle("quickOpen.recents")
                                    ForEach(Array(recentHits.enumerated()), id: \.element.id) { offset, hit in
                                        row(hit, at: favoriteHits.count + offset)
                                    }
                                }
                            } else {
                                ForEach(Array(visibleHits.enumerated()), id: \.element.id) { index, hit in
                                    row(hit, at: index)
                                }
                            }
                            if visibleHits.isEmpty {
                                Text(isSearching ? L10n.text("list.noSearchResults") : L10n.text("quickOpen.empty"))
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12).padding(.vertical, 18)
                            }
                        }
                        .padding(8)
                    }
                    .frame(maxHeight: .infinity)
                    .onChange(of: selectedIndex) { _, index in
                        guard visibleHits.indices.contains(index) else { return }
                        proxy.scrollTo(visibleHits[index].id, anchor: .center)
                    }
                }

                Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 0.5)
                HStack(spacing: 15) {
                    Label(L10n.text("quickOpen.navigateHint"), systemImage: "arrow.up.arrow.down")
                    Label(L10n.text("quickOpen.openHint"), systemImage: "return")
                    Spacer()
                    Text("ESC").font(.system(size: 9, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
                }
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .padding(.horizontal, 15).padding(.vertical, 10)
            }
            .frame(width: 620, height: 500)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(Color.primary.opacity(0.1), lineWidth: 0.7)
            }
            .shadow(color: .black.opacity(0.13), radius: 30, y: 12)
            .accessibilityIdentifier("quick-open-panel")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .zIndex(10)
        .transaction { $0.animation = nil }
        .onChange(of: query) { _, _ in selectedIndex = 0 }
        .onChange(of: visibleHits.count) { _, count in
            selectedIndex = count == 0 ? 0 : min(selectedIndex, count - 1)
        }
    }

    @ViewBuilder
    private func sectionTitle(_ key: String) -> some View {
        Text(L10n.text(key).uppercased())
            .font(.system(size: 9, weight: .medium)).tracking(0.8).foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 4)
    }

    private func row(_ hit: SearchHit, at index: Int) -> some View {
        SearchResultRow(hit: hit, query: isSearching ? query : "", selected: selectedIndex == index,
                        onOpen: { open(hit) }, onMoveFavorite: hit.targetNote.map { id in
                            { store.toggleFavoriteNote(id) }
                        })
            .id(hit.id)
    }

    private func moveSelection(_ delta: Int) {
        guard !visibleHits.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + visibleHits.count) % visibleHits.count
    }

    private func openSelected() {
        guard visibleHits.indices.contains(selectedIndex) else { return }
        open(visibleHits[selectedIndex])
    }

    private func cancel() {
        focusController.cancelAndRestorePreviousResponder()
        onClose()
    }

    private func open(_ hit: SearchHit) {
        focusController.dismissWithoutRestoring()
        switch hit.target {
        case .note(let id): onOpenNote(id, hit.findQuery)
        case .task(let id): onOpenTask(id)
        case .embeddedTask(let noteID): onOpenEmbeddedTask(noteID, hit.findQuery)
        }
    }
}

private struct SearchResultRow: View {
    let hit: SearchHit
    let query: String
    let selected: Bool
    let onOpen: () -> Void
    var onMoveFavorite: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onOpen) {
                HStack(spacing: 10) {
                    Image(systemName: hit.icon).font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 17)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(highlighted(hit.title, query: query))
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(.primary).lineLimit(1)
                        if let snippet = hit.snippet {
                            Text(highlighted(snippet, query: query))
                                .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                        } else {
                            Text(hit.subtitle).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    if selected {
                        Image(systemName: "return").font(.system(size: 9, weight: .medium)).foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 9).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(CalmButtonStyle()).pointerStyle(.link)

            if let onMoveFavorite {
                Button(action: onMoveFavorite) {
                    Image(systemName: hit.favorite ? "star.fill" : "star")
                        .font(.system(size: 11)).foregroundStyle(hit.favorite ? Color.accentColor : Color.secondary.opacity(0.55))
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(CalmButtonStyle()).pointerStyle(.link)
                .help(L10n.text(hit.favorite ? "quickOpen.removeFavorite" : "quickOpen.addFavorite"))
                .accessibilityLabel(L10n.text(hit.favorite ? "quickOpen.removeFavorite" : "quickOpen.addFavorite"))
            }
        }
        .background(selected ? Color.primary.opacity(0.065) : .clear, in: RoundedRectangle(cornerRadius: 6))
    }

    private func highlighted(_ text: String, query: String) -> AttributedString {
        var result = AttributedString(text)
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return result }
        for term in terms where !term.isEmpty {
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                  let range = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: searchStart..<text.endIndex) {
                if let lower = AttributedString.Index(range.lowerBound, within: result),
                   let upper = AttributedString.Index(range.upperBound, within: result) {
                    result[lower..<upper].foregroundColor = .accentColor
                    result[lower..<upper].backgroundColor = Color.accentColor.opacity(0.12)
                }
                searchStart = range.upperBound
            }
        }
        return result
    }
}

private extension SearchHit {
    var targetNote: UUID? {
        switch target {
        case .note(let id): id
        case .embeddedTask(let noteID): noteID
        case .task: nil
        }
    }
}

@MainActor
final class QuickOpenFocusController {
    private weak var field: QuickOpenNativeTextField?
    private var dismissed = false

    func attach(_ field: QuickOpenNativeTextField) {
        guard !dismissed else { return }
        self.field = field
    }

    func cancelAndRestorePreviousResponder() {
        guard !dismissed else { return }
        dismissed = true
        field?.cancelAndRestorePreviousResponder()
        field = nil
    }

    func dismissWithoutRestoring() {
        guard !dismissed else { return }
        dismissed = true
        field?.dismissWithoutRestoring()
        field = nil
    }
}

private struct QuickOpenTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let focusController: QuickOpenFocusController
    let onMove: (Int) -> Void
    let onCommit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> QuickOpenNativeTextField {
        let field = QuickOpenNativeTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.textColor = .labelColor
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 13)]
        )
        field.delegate = context.coordinator
        field.onMove = onMove
        field.onCommit = onCommit
        field.onCancel = onCancel
        field.stringValue = text
        field.setAccessibilityLabel(placeholder)
        field.setAccessibilityIdentifier("quick-open-search")
        focusController.attach(field)
        return field
    }

    func updateNSView(_ field: QuickOpenNativeTextField, context: Context) {
        context.coordinator.update(self)
        focusController.attach(field)
        field.onMove = onMove
        field.onCommit = onCommit
        field.onCancel = onCancel
        context.coordinator.synchronizeBinding(text, in: field)
        field.requestFocusIfNeeded()
    }

    final class Coordinator: SearchFieldCommandCoordinator {
        var parent: QuickOpenTextField
        init(_ parent: QuickOpenTextField) {
            self.parent = parent
            super.init()
            update(parent)
        }

        func update(_ parent: QuickOpenTextField) {
            self.parent = parent
            recordInitialBindingText(parent.text)
            onMove = parent.onMove
            onSubmit = parent.onCommit
            onCancel = parent.onCancel
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            let value = (field.currentEditor() as? NSTextView)?.string ?? field.stringValue
            withTransaction(transaction) { parent.text = value }
        }
    }
}

struct SearchQueryTextField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let placeholder: String
    let accessibilityLabel: String
    let onMove: (Int) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> SidebarSearchNativeTextField {
        let field = SidebarSearchNativeTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12)
        field.textColor = .labelColor
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: NSColor.tertiaryLabelColor, .font: NSFont.systemFont(ofSize: 12)]
        )
        field.delegate = context.coordinator
        field.stringValue = text
        field.onMove = onMove
        field.onSubmit = onSubmit
        field.onCancel = onCancel
        field.setAccessibilityLabel(accessibilityLabel)
        field.setAccessibilityIdentifier("global-search")
        field.onFocusAcquired = { [weak coordinator = context.coordinator] in
            coordinator?.parent.isFocused = true
        }
        field.setSearchFocus(isFocused)
        return field
    }

    func updateNSView(_ field: SidebarSearchNativeTextField, context: Context) {
        context.coordinator.update(self)
        field.onMove = onMove
        field.onSubmit = onSubmit
        field.onCancel = onCancel
        context.coordinator.synchronizeBinding(text, in: field)
        field.setSearchFocus(isFocused)
    }

    final class Coordinator: SearchFieldCommandCoordinator {
        var parent: SearchQueryTextField
        init(_ parent: SearchQueryTextField) {
            self.parent = parent
            super.init()
            update(parent)
        }

        func update(_ parent: SearchQueryTextField) {
            self.parent = parent
            recordInitialBindingText(parent.text)
            onMove = parent.onMove
            onSubmit = parent.onSubmit
            onCancel = parent.onCancel
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            let value = (field.currentEditor() as? NSTextView)?.string ?? field.stringValue
            withTransaction(transaction) { parent.text = value }
        }

        func controlTextDidBeginEditing(_ notification: Notification) { parent.isFocused = true }
        func controlTextDidEndEditing(_ notification: Notification) { parent.isFocused = false }
    }
}

final class SidebarSearchNativeTextField: NSTextField {
    var onMove: (Int) -> Void = { _ in }
    var onSubmit: () -> Void = {}
    var onCancel: () -> Void = {}
    var onFocusAcquired: () -> Void = {}
    private var shouldBeFocused = false
    private var focusReportScheduled = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: .stillFocusSearch, object: nil)
        guard window != nil else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(focusSearchFromShortcut(_:)),
                                               name: .stillFocusSearch, object: nil)
        requestFocusIfNeeded()
    }

    @objc private func focusSearchFromShortcut(_ notification: Notification) {
        guard let window, !isHiddenOrHasHiddenAncestor else { return }
        if let targetWindow = notification.object as? NSWindow {
            guard targetWindow === window else { return }
        } else {
            guard NSApp.keyWindow === window else { return }
        }
        // A command must transfer the native responder before the next key arrives;
        // waiting for the SwiftUI focus binding leaves that key in the editor.
        setSearchFocus(true)
    }

    func setSearchFocus(_ focused: Bool) {
        shouldBeFocused = focused
        if focused { requestFocusIfNeeded() }
        else if let window, isSearchFirstResponder(in: window) { window.makeFirstResponder(nil) }
    }

    private func requestFocusIfNeeded() {
        guard shouldBeFocused, let window else { return }
        if !isSearchFirstResponder(in: window) { window.makeFirstResponder(self) }
        guard isSearchFirstResponder(in: window), !focusReportScheduled else { return }
        // Only binding bookkeeping is deferred; native focus is already in place.
        // This also acknowledges a repeated shortcut when editing had already begun.
        focusReportScheduled = true
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self else { return }
            self.focusReportScheduled = false
            guard let window, self.window === window, self.shouldBeFocused,
                  self.isSearchFirstResponder(in: window) else { return }
            self.onFocusAcquired()
        }
    }

    private func isSearchFirstResponder(in window: NSWindow) -> Bool {
        window.firstResponder === self || isEditing(in: window)
    }

    func isEditing(in window: NSWindow) -> Bool {
        guard let editor = currentEditor() as? NSTextView,
              editor === window.firstResponder else { return false }
        return editor.delegate === self
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard modifiers.isEmpty else { super.keyDown(with: event); return }
        switch event.keyCode {
        case 126: onMove(-1)
        case 125: onMove(1)
        case 36, 76: onSubmit()
        case 53: onCancel()
        default: super.keyDown(with: event)
        }
    }
}

@MainActor
class SearchFieldCommandCoordinator: NSObject, NSTextFieldDelegate {
    var onMove: (Int) -> Void = { _ in }
    var onSubmit: () -> Void = {}
    var onCancel: () -> Void = {}
    private(set) var lastAppliedBindingText: String?

    func recordInitialBindingText(_ text: String) {
        if lastAppliedBindingText == nil { lastAppliedBindingText = text }
    }

    func synchronizeBinding(_ text: String, in field: NSTextField) {
        guard lastAppliedBindingText != text else { return }
        lastAppliedBindingText = text
        if let editor = field.currentEditor() as? NSTextView,
           editor.delegate === field, editor.string != text {
            let selectedRange = editor.selectedRange()
            editor.string = text
            editor.setSelectedRange(NSRange(location: min(selectedRange.location, (text as NSString).length), length: 0))
        }
        if field.stringValue != text { field.stringValue = text }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch NSStringFromSelector(commandSelector) {
        case "moveUp:": onMove(-1); return true
        case "moveDown:": onMove(1); return true
        case "insertNewline:", "insertLineBreak:": onSubmit(); return true
        case "cancelOperation:": onCancel(); return true
        default: return false
        }
    }
}

final class QuickOpenNativeTextField: NSTextField {
    var onMove: (Int) -> Void = { _ in }
    var onCommit: () -> Void = {}
    var onCancel: () -> Void = {}
    private weak var capturedWindow: NSWindow?
    private weak var previousResponder: NSResponder?
    private var hasCapturedResponder = false
    private var isDismissed = false
    private var focusGeneration = 0
    private var focusRetryScheduled = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else {
            focusGeneration += 1
            focusRetryScheduled = false
            return
        }
        capturePreviousResponder(in: window)
        focusGeneration += 1
        requestFocusIfNeeded()
    }

    func requestFocusIfNeeded(attempt: Int = 0) {
        guard !isDismissed, let window else { return }
        if isQuickOpenFirstResponder(in: window) {
            focusRetryScheduled = false
            return
        }
        if window.makeFirstResponder(self) {
            focusRetryScheduled = false
            return
        }
        guard attempt < 2, !focusRetryScheduled else { return }
        focusRetryScheduled = true
        let generation = focusGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.035) { [weak self, weak window] in
            guard let self, let window, self.window === window,
                  self.focusGeneration == generation, !self.isDismissed else { return }
            self.focusRetryScheduled = false
            self.requestFocusIfNeeded(attempt: attempt + 1)
        }
    }

    func cancelAndRestorePreviousResponder() {
        guard !isDismissed else { return }
        isDismissed = true
        focusGeneration += 1
        defer { clearPreviousResponder() }
        guard let window, let capturedWindow, window === capturedWindow,
              let previousResponder, belongsToWindow(previousResponder, window: window) else { return }
        window.makeFirstResponder(previousResponder)
    }

    func dismissWithoutRestoring() {
        guard !isDismissed else { return }
        isDismissed = true
        focusGeneration += 1
        clearPreviousResponder()
    }

    private func capturePreviousResponder(in window: NSWindow) {
        guard !hasCapturedResponder || capturedWindow !== window else { return }
        hasCapturedResponder = true
        capturedWindow = window

        guard let responder = window.firstResponder, responder !== self else { return }
        if let fieldEditor = responder as? NSTextView, fieldEditor.isFieldEditor {
            if let owner = fieldEditor.delegate as? NSControl, owner.window === window {
                previousResponder = owner
            } else if let owner = fieldEditor.delegate as? NSView, owner.window === window {
                previousResponder = owner
            }
        } else if belongsToWindow(responder, window: window) {
            previousResponder = responder
        }
    }

    private func belongsToWindow(_ responder: NSResponder, window: NSWindow) -> Bool {
        if let view = responder as? NSView { return view.window === window }
        return responder === window
    }

    private func isQuickOpenFirstResponder(in window: NSWindow) -> Bool {
        window.firstResponder === self || isEditing(in: window)
    }

    func isEditing(in window: NSWindow) -> Bool {
        guard let editor = currentEditor() as? NSTextView,
              editor === window.firstResponder else { return false }
        return editor.delegate === self
    }

    private func clearPreviousResponder() {
        previousResponder = nil
        capturedWindow = nil
        hasCapturedResponder = false
        focusRetryScheduled = false
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard modifiers.isEmpty else { super.keyDown(with: event); return }
        switch event.keyCode {
        case 126: onMove(-1)
        case 125: onMove(1)
        case 36, 76: onCommit()
        case 53: onCancel()
        default: super.keyDown(with: event)
        }
    }
}
