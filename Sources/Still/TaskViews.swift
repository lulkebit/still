import AppKit
import SwiftUI

struct GlobalSearchBoard: View {
    let store: StillStore
    let query: String
    let onOpenNote: (UUID) -> Void
    let onOpenTask: (UUID) -> Void
    let onOpenEmbeddedTask: (EmbeddedTask) -> Void

    private enum Result: Identifiable {
        case note(Note)
        case task(TaskItem)
        case embedded(EmbeddedTask)

        var id: String {
            switch self {
            case .note(let value): "note:\(value.id)"
            case .task(let value): "task:\(value.id)"
            case .embedded(let value): "embedded:\(value.id)"
            }
        }
        var title: String {
            switch self {
            case .note(let value): value.title
            case .task(let value): value.title
            case .embedded(let value): value.title
            }
        }
        var subtitle: String {
            switch self {
            case .note(let value): L10n.text(value.section == .wiki ? "nav.wiki" : "nav.notes")
            case .task: L10n.text("task.standalone")
            case .embedded(let value): String(format: L10n.text("task.source"), value.noteTitle)
            }
        }
        var icon: String {
            switch self {
            case .note(let value): value.section == .wiki ? "books.vertical" : "note.text"
            case .task: "checklist"
            case .embedded: "checkmark.square"
            }
        }
    }

    private var results: [Result] {
        let notes = store.notes.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.markdown.localizedCaseInsensitiveContains(query) }.map(Result.note)
        let tasks = store.tasks.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.detail.localizedCaseInsensitiveContains(query) }.map(Result.task)
        let embedded = store.embeddedTasks.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.noteTitle.localizedCaseInsensitiveContains(query) }.map(Result.embedded)
        return (notes + tasks + embedded).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.text("list.searchResults")).font(.system(size: 21, weight: .medium, design: .serif))
                    Text(query).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(results.count)").font(.system(size: 11, design: .rounded)).foregroundStyle(.tertiary)
            }
            .padding(.bottom, 18)
            if results.isEmpty {
                Text(L10n.text("list.noSearchResults")).font(.system(size: 13)).foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(results) { result in
                            Button {
                                switch result {
                                case .note(let note): onOpenNote(note.id)
                                case .task(let task): onOpenTask(task.id)
                                case .embedded(let task): onOpenEmbeddedTask(task)
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: result.icon).font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 18)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(result.title).font(.system(size: 13, weight: .medium)).foregroundStyle(.primary).lineLimit(1)
                                        Text(result.subtitle).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "arrow.up.left").font(.system(size: 10)).foregroundStyle(.quaternary)
                                }
                                .padding(.horizontal, 10).padding(.vertical, 10).contentShape(Rectangle())
                            }
                            .buttonStyle(CalmButtonStyle()).pointerStyle(.link).calmHover(cornerRadius: 6)
                            .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.04)).frame(height: 0.5) }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 52).padding(.top, 58).padding(.bottom, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct TaskBoardView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let appModel: StillAppModel
    let query: String
    @Binding var selectedTaskID: UUID?
    let onOpenNote: (UUID) -> Void
    @State private var draftTitle = ""

    private var store: StillStore { appModel.store }
    private var sortedTasks: [TaskItem] { store.tasks.sorted { lhs, rhs in
        let leftRank = statusRank(lhs.status)
        let rightRank = statusRank(rhs.status)
        if leftRank != rightRank { return leftRank < rightRank }
        switch (lhs.dueDate, rhs.dueDate) {
        case let (left?, right?) where left != right: return left < right
        case (_?, nil): return true
        case (nil, _?): return false
        default: break
        }
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        let titleOrder = lhs.title.localizedStandardCompare(rhs.title)
        if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
        return lhs.id.uuidString < rhs.id.uuidString
    } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 17) {
                    Text(L10n.text("nav.tasks")).font(.system(size: 30, weight: .medium, design: .serif)).tracking(-0.5)
                    HStack(spacing: 9) {
                        TextField(L10n.text("task.newPlaceholder"), text: $draftTitle)
                            .textFieldStyle(.plain).font(.system(size: 13))
                            .onSubmit(addTask).accessibilityIdentifier("new-task-title")
                        Button(action: addTask) {
                            Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).frame(width: 28, height: 28)
                        }
                        .buttonStyle(CalmButtonStyle()).pointerStyle(.link).calmHover()
                        .foregroundStyle(.secondary).help(L10n.text("task.add"))
                        .accessibilityIdentifier("new-task")
                    }
                    .padding(.horizontal, 11).padding(.vertical, 6)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.05), lineWidth: 0.5))
                }

                VStack(alignment: .leading, spacing: 9) {
                    sectionHeading("task.standalone", count: sortedTasks.count)
                    if sortedTasks.isEmpty {
                        Text(L10n.text("task.empty")).font(.system(size: 12)).foregroundStyle(.tertiary).padding(.vertical, 7)
                    } else {
                        ForEach(sortedTasks) { task in
                            StandaloneTaskRow(task: task, appModel: appModel,
                                              isExpanded: selectedTaskID == task.id,
                                              onToggle: { toggle(task) },
                                              onExpand: { selectedTaskID = selectedTaskID == task.id ? nil : task.id },
                                              onOpenNote: onOpenNote,
                                              onDelete: { delete(task) })
                        }
                    }
                }

                let embedded = store.embeddedTasks.sorted { $0.noteTitle.localizedStandardCompare($1.noteTitle) == .orderedAscending }
                VStack(alignment: .leading, spacing: 9) {
                    sectionHeading("task.checklists", count: embedded.count)
                    if embedded.isEmpty {
                        Text(L10n.text("task.noChecklists")).font(.system(size: 12)).foregroundStyle(.tertiary).padding(.vertical, 7)
                    } else {
                        ForEach(embedded) { item in
                            HStack(spacing: 10) {
                                Button { store.toggleEmbeddedTask(item) } label: {
                                    Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 16)).foregroundStyle(item.isDone ? Color.accentColor : Color.secondary)
                                }
                                .buttonStyle(CalmButtonStyle()).pointerStyle(.link).calmHover(cornerRadius: 6)
                                .accessibilityLabel(L10n.text(item.isDone ? "task.reopen" : "task.complete"))
                                Button { onOpenNote(item.noteID) } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.title).font(.system(size: 12)).foregroundStyle(item.isDone ? .secondary : .primary)
                                            .strikethrough(item.isDone, color: .secondary).lineLimit(2)
                                        Text(String(format: L10n.text("task.source"), item.noteTitle))
                                            .font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                }
                                .buttonStyle(CalmButtonStyle()).pointerStyle(.link).calmHover(cornerRadius: 6)
                            }
                            .padding(.vertical, 7).overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.045)).frame(height: 0.5) }
                        }
                    }
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 50).padding(.top, 58).padding(.bottom, 60)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .accessibilityIdentifier("task-board")
    }

    private func sectionHeading(_ key: String, count: Int) -> some View {
        HStack {
            Text(L10n.text(key)).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            Text("\(count)").font(.system(size: 10)).foregroundStyle(.tertiary)
            Spacer()
        }.padding(.bottom, 3)
    }

    private func statusRank(_ status: TaskStatus) -> Int {
        switch status { case .open: 0; case .waiting: 1; case .done: 2 }
    }

    private func addTask() {
        do {
            let task = try store.createTask(title: draftTitle)
            selectedTaskID = task.id
            draftTitle = ""
        } catch { store.report(error) }
    }

    private func toggle(_ task: TaskItem) {
        var updated = task
        updated.status = task.status == .done ? .open : .done
        withAnimation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.94)) {
            do { try store.updateTask(updated) } catch { store.report(error) }
        }
    }

    private func delete(_ task: TaskItem) {
        do { try store.deleteTask(id: task.id) }
        catch { store.report(error) }
    }
}

private struct StandaloneTaskRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let task: TaskItem
    let appModel: StillAppModel
    let isExpanded: Bool
    let onToggle: () -> Void
    let onExpand: () -> Void
    let onOpenNote: (UUID) -> Void
    let onDelete: () -> Void
    @State private var isWikiBusy = false
    @State private var titleDraft = ""
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Button(action: onToggle) {
                    Image(systemName: task.status == .done ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16)).foregroundStyle(task.status == .done ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(CalmButtonStyle()).pointerStyle(.link).calmHover(cornerRadius: 6)
                .accessibilityLabel(L10n.text(task.status == .done ? "task.reopen" : "task.complete"))
                Button(action: onExpand) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(task.title).font(.system(size: 13, weight: .regular)).foregroundStyle(task.status == .done ? .secondary : .primary)
                                .strikethrough(task.status == .done, color: .secondary).lineLimit(2)
                            if task.status == .waiting {
                                Text(L10n.text("task.status.waiting")).font(.system(size: 10)).foregroundStyle(.tertiary)
                            }
                        }
                        if task.dueDate != nil || task.priority == .high {
                            HStack(spacing: 8) {
                                if let dueDate = task.dueDate { Text(dueDate, style: .date) }
                                if task.priority == .high { Label(L10n.text("task.priority.high"), systemImage: "flag.fill") }
                            }.font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(CalmButtonStyle()).pointerStyle(.link).calmHover(cornerRadius: 6)
                Menu {
                    Button(L10n.text("task.details"), systemImage: "slider.horizontal.3", action: onExpand)
                    Divider()
                    Button(L10n.text("task.delete"), systemImage: "trash", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 11)).foregroundStyle(.tertiary).frame(width: 24, height: 24)
                }
                .menuStyle(.borderlessButton).pointerStyle(.link).calmHover(cornerRadius: 6)
            }
            .padding(.vertical, 8)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.05)).frame(height: 0.5) }

            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    TextField(L10n.text("task.titlePlaceholder"), text: $titleDraft)
                        .textFieldStyle(.plain).font(.system(size: 12, weight: .medium))
                        .focused($titleFocused).onSubmit(commitTitle)
                        .onChange(of: titleFocused) { _, focused in if !focused { commitTitle() } }
                        .onChange(of: task.title) { _, value in if !titleFocused { titleDraft = value } }
                        .accessibilityIdentifier("task-edit-title-\(task.id.uuidString)")
                    TaskDescriptionTextView(text: task.detail, onChange: updateDetail, onAIAction: performAI)
                        .frame(height: 100)
                        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 7))
                        .accessibilityIdentifier("task-description-\(task.id.uuidString)")
                    if isWikiBusy {
                        Label(L10n.text("action.aiBusy"), systemImage: "circle.dotted")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 12) {
                        Picker(L10n.text("task.status"), selection: Binding(get: { task.status }, set: updateStatus)) {
                            ForEach(TaskStatus.allCases) { status in Text(L10n.text(status.localizationKey)).tag(status) }
                        }
                        .labelsHidden().frame(width: 150).pointerStyle(.link).calmHover(cornerRadius: 6)
                        .accessibilityIdentifier("task-status")
                        Picker(L10n.text("task.priority"), selection: Binding(get: { task.priority }, set: updatePriority)) {
                            ForEach(TaskPriority.allCases) { priority in Text(L10n.text(priority.localizationKey)).tag(priority) }
                        }
                        .labelsHidden().frame(width: 130).pointerStyle(.link).calmHover(cornerRadius: 6)
                        .accessibilityIdentifier("task-priority")
                        if task.dueDate != nil {
                            DatePicker(L10n.text("task.dueDate"), selection: Binding(get: { task.dueDate ?? .now }, set: { updateDueDate($0) }), displayedComponents: .date)
                                .labelsHidden().accessibilityLabel(L10n.text("task.dueDate"))
                            Button { updateDueDate(nil) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                                .buttonStyle(CalmButtonStyle()).pointerStyle(.link).calmHover(cornerRadius: 6)
                                .help(L10n.text("task.clearDueDate"))
                        } else {
                            Button { updateDueDate(.now) } label: {
                                Label(L10n.text("task.addDueDate"), systemImage: "calendar.badge.plus")
                            }
                            .buttonStyle(CalmButtonStyle()).pointerStyle(.link).calmHover()
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    .font(.system(size: 11))
                    .controlSize(.small)
                }
                .padding(.leading, 26).padding(.top, 9).padding(.bottom, 13)
                .transition(.opacity.combined(with: .scale(scale: 0.985, anchor: .top)))
                .clipped()
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.90), value: isExpanded)
        .onAppear { titleDraft = task.title }
    }

    private func updateDetail(_ value: String) {
        var updated = task
        updated.detail = value
        do { try appModel.store.updateTask(updated) } catch { appModel.store.report(error) }
    }

    private func commitTitle() {
        let value = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { titleDraft = task.title; return }
        guard value != task.title else { return }
        var updated = task
        updated.title = value
        save(updated)
    }

    private func updateStatus(_ value: TaskStatus) { var updated = task; updated.status = value; save(updated) }
    private func updatePriority(_ value: TaskPriority) { var updated = task; updated.priority = value; save(updated) }
    private func updateDueDate(_ value: Date?) { var updated = task; updated.dueDate = value; save(updated) }
    private func save(_ updated: TaskItem) { do { try appModel.store.updateTask(updated) } catch { appModel.store.report(error) } }

    private func performAI(_ action: String, selectedText: String, range: NSRange, applyReplacement: @escaping (String) -> Bool) {
        guard !isWikiBusy else { return }
        let original = task.detail
        guard range.location >= 0, range.length > 0, NSMaxRange(range) <= (original as NSString).length else { return }
        let source = (original as NSString).substring(with: range)
        isWikiBusy = true
        Task { @MainActor in
            defer { isWikiBusy = false }
            do {
                let outcome = try await appModel.performAIAction(action, noteID: task.id, selectedText: source)
                switch outcome {
                case .wiki(let notes):
                    if let first = notes.first { onOpenNote(first.id) }
                case .optimized(let replacement):
                    guard let current = appModel.store.tasks.first(where: { $0.id == task.id }),
                          current.detail == original,
                          range.location + range.length <= (current.detail as NSString).length,
                          (current.detail as NSString).substring(with: range) == source else {
                        appModel.aiError = L10n.text("error.aiSelectionChanged")
                        return
                    }
                    if !applyReplacement(replacement) { appModel.aiError = L10n.text("error.aiSelectionChanged") }
                }
            } catch { appModel.aiError = L10n.message(for: error) }
        }
    }
}

private struct TaskDescriptionTextView: NSViewRepresentable {
    var text: String
    var onChange: (String) -> Void
    var onAIAction: (String, String, NSRange, @escaping (String) -> Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange, onAIAction: onAIAction) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        let view = TaskSelectionTextView(frame: .zero)
        view.delegate = context.coordinator
        view.onAIAction = { [weak coordinator = context.coordinator] action, selected, range, apply in
            coordinator?.onAIAction(action, selected, range, apply)
        }
        view.font = .systemFont(ofSize: 12)
        view.textColor = .labelColor
        view.backgroundColor = .clear
        view.drawsBackground = false
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.textContainerInset = NSSize(width: 9, height: 8)
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.string = text
        scroll.documentView = view
        context.coordinator.textView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.onChange = onChange
        context.coordinator.onAIAction = onAIAction
        guard let view = scroll.documentView as? TaskSelectionTextView else { return }
        view.onAIAction = { [weak coordinator = context.coordinator] action, selected, range, apply in
            coordinator?.onAIAction(action, selected, range, apply)
        }
        if view.string != text, !view.hasMarkedText() { view.string = text }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var onChange: (String) -> Void
        var onAIAction: (String, String, NSRange, @escaping (String) -> Bool) -> Void
        weak var textView: NSTextView?

        init(onChange: @escaping (String) -> Void, onAIAction: @escaping (String, String, NSRange, @escaping (String) -> Bool) -> Void) {
            self.onChange = onChange
            self.onAIAction = onAIAction
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            onChange(view.string)
        }
    }
}

private final class TaskSelectionTextView: NSTextView {
    var onAIAction: ((String, String, NSRange, @escaping (String) -> Bool) -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu(title: "")
        let range = selectedRange()
        let selected = range.length > 0 && NSMaxRange(range) <= (string as NSString).length
            ? (string as NSString).substring(with: range) : ""
        let wiki = NSMenuItem(title: L10n.text("action.wiki"), action: #selector(createWikiFromSelection), keyEquivalent: "")
        wiki.target = self
        wiki.isEnabled = !selected.isEmpty
        let optimize = NSMenuItem(title: L10n.text("action.optimize"), action: #selector(optimizeSelection), keyEquivalent: "")
        optimize.target = self
        optimize.isEnabled = !selected.isEmpty
        menu.addItem(wiki)
        menu.addItem(optimize)
        if let native = super.menu(for: event), !native.items.isEmpty {
            menu.addItem(.separator())
            for item in native.items {
                if let copy = item.copy() as? NSMenuItem { menu.addItem(copy) }
            }
        }
        return menu
    }

    @objc private func createWikiFromSelection() { perform("wiki") }
    @objc private func optimizeSelection() { perform("optimize") }

    private func perform(_ action: String) {
        let range = selectedRange()
        guard range.length > 0, NSMaxRange(range) <= (string as NSString).length else { return }
        let originalSelection = (string as NSString).substring(with: range)
        onAIAction?(action, originalSelection, range) { [weak self] replacement in
            guard let self,
                  NSMaxRange(range) <= (self.string as NSString).length,
                  (self.string as NSString).substring(with: range) == originalSelection,
                  self.shouldChangeText(in: range, replacementString: replacement) else { return false }
            self.insertText(replacement, replacementRange: range)
            return true
        }
    }
}
