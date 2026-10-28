import AppKit
import SwiftUI

struct TaskBoardView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let appModel: StillAppModel
    let query: String
    @Binding var selectedTaskID: UUID?
    let onOpenNote: (UUID) -> Void
    @State private var draftTitle = ""
    @State private var focusPresentation = TaskFocusPresentationState()

    private var selectedFilter: TaskFocusFilter {
        get { focusPresentation.filter }
        nonmutating set { focusPresentation.filter = newValue }
    }
    private var showsDoneTasks: Bool {
        get { focusPresentation.showsDoneTasks }
        nonmutating set { focusPresentation.showsDoneTasks = newValue }
    }

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
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
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
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(Color.primary.opacity(0.09)).frame(height: 0.5).allowsHitTesting(false)
                        }
                    }

                    filterPicker

                    VStack(alignment: .leading, spacing: 0) {
                        sectionHeading(selectedFilter.localizationKey, count: visibleTasks(at: timeline.date).count).padding(.bottom, 5)
                        let focusedTasks = visibleTasks(at: timeline.date)
                        if focusedTasks.isEmpty {
                            Text(L10n.text(emptyMessageKey))
                                .font(.system(size: 12)).foregroundStyle(.tertiary).padding(.vertical, 7)
                                .transition(CalmMotion.reveal(reduceMotion: reduceMotion))
                        } else {
                            ForEach(focusedTasks) { task in
                                StandaloneTaskRow(task: task, appModel: appModel,
                                                  isExpanded: selectedTaskID == task.id,
                                                  now: timeline.date,
                                                  onToggle: { toggle(task) },
                                                  onExpand: { selectedTaskID = selectedTaskID == task.id ? nil : task.id },
                                                  onOpenNote: onOpenNote,
                                                  onDelete: { delete(task) })
                            }
                        }
                    }

                    if selectedFilter == .all {
                        let embedded = store.embeddedTasks.filter { !$0.isDone }
                            .sorted { $0.noteTitle.localizedStandardCompare($1.noteTitle) == .orderedAscending }
                        VStack(alignment: .leading, spacing: 9) {
                            sectionHeading(store.wikiEnabled ? "task.checklists" : "task.checklists.notesOnly", count: embedded.count)
                            if embedded.isEmpty {
                                Text(L10n.text(store.wikiEnabled ? "task.noChecklists" : "task.noChecklists.notesOnly"))
                                    .font(.system(size: 12)).foregroundStyle(.tertiary).padding(.vertical, 7)
                            } else {
                                ForEach(embedded) { item in embeddedTaskRow(item) }
                            }
                        }
                    }

                    if doneCount > 0 {
                        VStack(alignment: .leading, spacing: 8) {
                            Button {
                                withAnimation(reduceMotion ? nil : CalmMotion.quick) { focusPresentation.toggleDone() }
                            } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: doneExpanded ? "chevron.down" : "chevron.right")
                                        .font(.system(size: 9, weight: .medium)).foregroundStyle(.tertiary)
                                    Text(L10n.text("task.focus.done"))
                                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                                    Text("\(doneCount)")
                                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(CalmButtonStyle()).pointerStyle(.link)
                            .accessibilityIdentifier("task-done-section-toggle")

                            if doneExpanded {
                                ForEach(doneTasks) { task in
                                    StandaloneTaskRow(task: task, appModel: appModel,
                                                      isExpanded: selectedTaskID == task.id,
                                                      now: timeline.date,
                                                      onToggle: { toggle(task) },
                                                      onExpand: { selectedTaskID = selectedTaskID == task.id ? nil : task.id },
                                                      onOpenNote: onOpenNote,
                                                      onDelete: { delete(task) })
                                }
                                ForEach(doneEmbeddedTasks) { item in embeddedTaskRow(item) }
                            }
                        }
                    }
                }
                .frame(maxWidth: 720, alignment: .leading)
                .padding(.horizontal, 50).padding(.top, 58).padding(.bottom, 60)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .accessibilityIdentifier("task-board")
        .onAppear(perform: revealSelectedTaskIfNeeded)
        .onChange(of: selectedTaskID) { _, _ in revealSelectedTaskIfNeeded() }
        }
    }

    private var filterPicker: some View {
        HStack(spacing: 4) {
            ForEach(TaskFocusFilter.allCases) { filter in
                let isSelected = selectedFilter == filter
                Button {
                    selectedFilter = filter
                } label: {
                    Text(L10n.text(filter.localizationKey))
                        .font(.system(size: 11, weight: isSelected ? .medium : .regular))
                        .foregroundStyle(isSelected ? .primary : .secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(isSelected ? Color.primary.opacity(0.065) : .clear, in: Capsule())
                }
                .buttonStyle(CalmButtonStyle()).pointerStyle(.link).calmHover(cornerRadius: 18)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityIdentifier("task-focus-\(filter.rawValue)")
            }
            Spacer(minLength: 0)
        }
    }

    private var doneTasks: [TaskItem] { sortedTasks.filter { $0.status == .done } }
    private var doneEmbeddedTasks: [EmbeddedTask] {
        store.embeddedTasks.filter(\.isDone)
            .sorted { $0.noteTitle.localizedStandardCompare($1.noteTitle) == .orderedAscending }
    }
    private var doneCount: Int { doneTasks.count + doneEmbeddedTasks.count }
    private var doneExpanded: Bool { focusPresentation.showsDoneTasks }
    private var emptyMessageKey: String {
        selectedFilter == .all ? "task.empty" : "task.focus.empty.\(selectedFilter.rawValue)"
    }

    private func visibleTasks(at now: Date) -> [TaskItem] {
        TaskFocusPolicy.tasks(sortedTasks, matching: selectedFilter, now: now)
    }

    private func revealSelectedTaskIfNeeded() {
        guard let selectedTaskID, let selected = store.tasks.first(where: { $0.id == selectedTaskID }) else { return }
        focusPresentation.revealSelection(selected)
    }

    @ViewBuilder
    private func embeddedTaskRow(_ item: EmbeddedTask) -> some View {
        HStack(spacing: 10) {
            Button { store.toggleEmbeddedTask(item) } label: {
                Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16)).foregroundStyle(item.isDone ? Color.accentColor : Color.secondary)
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                    .animation(reduceMotion ? nil : CalmMotion.quick, value: item.isDone)
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
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.045)).frame(height: 0.5) }
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
            let task = try withAnimation(reduceMotion ? nil : CalmMotion.standard) {
                try store.createTask(title: draftTitle)
            }
            selectedFilter = .all
            selectedTaskID = task.id
            draftTitle = ""
        } catch { store.report(error) }
    }

    private func toggle(_ task: TaskItem) {
        var updated = task
        updated.status = task.status == .done ? .open : .done
        if updated.status == .done, selectedTaskID == task.id { focusPresentation.showsDoneTasks = true }
        withAnimation(reduceMotion ? nil : CalmMotion.quick) {
            do { try store.updateTask(updated) } catch { store.report(error) }
        }
    }

    private func delete(_ task: TaskItem) {
        do {
            try withAnimation(reduceMotion ? nil : CalmMotion.standard) {
                try store.deleteTask(id: task.id)
            }
            if selectedTaskID == task.id { selectedTaskID = nil }
        }
        catch { store.report(error) }
    }
}

private struct StandaloneTaskRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let task: TaskItem
    let appModel: StillAppModel
    let isExpanded: Bool
    let now: Date
    let onToggle: () -> Void
    let onExpand: () -> Void
    let onOpenNote: (UUID) -> Void
    let onDelete: () -> Void
    @State private var isWikiBusy = false
    @State private var pendingAIOriginal: String?
    @State private var pendingAIRange: NSRange?
    @State private var titleDraft = ""
    @State private var isRenaming = false
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Button(action: onToggle) {
                    Image(systemName: task.status == .done ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16)).foregroundStyle(task.status == .done ? Color.accentColor : Color.secondary)
                        .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                        .animation(reduceMotion ? nil : CalmMotion.quick, value: task.status)
                }
                .buttonStyle(CalmButtonStyle()).pointerStyle(.link)
                .accessibilityLabel(L10n.text(task.status == .done ? "task.reopen" : "task.complete"))
                if isRenaming {
                    TextField(L10n.text("task.titlePlaceholder"), text: $titleDraft)
                        .textFieldStyle(.plain).font(.system(size: 13, weight: .regular))
                        .focused($titleFocused).onSubmit(finishTitleEditing)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .task(id: isRenaming) {
                            guard isRenaming else { return }
                            await Task.yield()
                            guard !Task.isCancelled, isRenaming else { return }
                            titleFocused = true
                        }
                        .onChange(of: titleFocused) { _, focused in
                            if !focused && isRenaming { finishTitleEditing() }
                        }
                        .onChange(of: task.title) { _, value in
                            if !titleFocused { titleDraft = value }
                        }
                        .accessibilityLabel(L10n.text("list.rename"))
                        .accessibilityIdentifier("task-edit-title-\(task.id.uuidString)")
                } else {
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
                                    if let dueDate = task.dueDate {
                                        Text(dueDate, style: .date)
                                        if TaskFocusPolicy.isOverdue(task, now: now) {
                                            Text(L10n.text("task.overdue"))
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    if task.priority == .high { Label(L10n.text("task.priority.high"), systemImage: "flag.fill") }
                                }.font(.system(size: 10)).foregroundStyle(.tertiary)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(CalmButtonStyle()).pointerStyle(.link)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)

            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    TaskDescriptionTextView(
                        text: task.detail,
                        isBusy: isWikiBusy,
                        isAIEnabled: appModel.store.settings.enabled && !appModel.aiBusy,
                        isWikiEnabled: appModel.store.wikiEnabled,
                        busySelectionRange: pendingAIRange,
                        busySourceText: pendingAIOriginal,
                        reduceMotion: reduceMotion,
                        onChange: updateDetail,
                        onAIAction: performAI
                    )
                        .frame(height: 100)
                        .accessibilityIdentifier("task-description-\(task.id.uuidString)")
                    HStack(spacing: 12) {
                        Picker(L10n.text("task.status"), selection: Binding(get: { task.status }, set: updateStatus)) {
                            ForEach(TaskStatus.allCases) { status in Text(L10n.text(status.localizationKey)).tag(status) }
                        }
                        .labelsHidden().pickerStyle(.menu).buttonStyle(.borderless).fixedSize().pointerStyle(.link)
                        .accessibilityLabel(L10n.text("task.status"))
                        .accessibilityIdentifier("task-status")
                        Picker(L10n.text("task.priority"), selection: Binding(get: { task.priority }, set: updatePriority)) {
                            ForEach(TaskPriority.allCases) { priority in Text(L10n.text(priority.localizationKey)).tag(priority) }
                        }
                        .labelsHidden().pickerStyle(.menu).buttonStyle(.borderless).fixedSize().pointerStyle(.link)
                        .accessibilityLabel(L10n.text("task.priority"))
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
                .padding(.leading, 25).padding(.top, 9).padding(.bottom, 13)
                .transition(CalmMotion.reveal(reduceMotion: reduceMotion))
                .clipped()
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 0.5).allowsHitTesting(false)
        }
        .contextMenu {
            Button(L10n.text("list.rename"), systemImage: "pencil", action: beginTitleEditing)
            Button(L10n.text("task.delete"), systemImage: "trash", role: .destructive, action: onDelete)
        }
        .transition(CalmMotion.reveal(reduceMotion: reduceMotion))
        .animation(reduceMotion ? nil : CalmMotion.standard, value: isExpanded)
        .onAppear { titleDraft = task.title }
        .onChange(of: task.detail) { _, detail in
            if isWikiBusy && detail != pendingAIOriginal { finishAIAction() }
        }
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

    private func beginTitleEditing() {
        titleDraft = task.title
        isRenaming = true
    }

    private func finishTitleEditing() {
        commitTitle()
        isRenaming = false
    }

    private func updateStatus(_ value: TaskStatus) { var updated = task; updated.status = value; save(updated) }
    private func updatePriority(_ value: TaskPriority) { var updated = task; updated.priority = value; save(updated) }
    private func updateDueDate(_ value: Date?) { var updated = task; updated.dueDate = value; save(updated) }
    private func save(_ updated: TaskItem) { do { try appModel.store.updateTask(updated) } catch { appModel.store.report(error) } }

    private func performAI(_ action: String, selectedText: String, range: NSRange, applyReplacement: @escaping (String) -> Bool) {
        guard !isWikiBusy, !appModel.aiBusy, appModel.store.settings.enabled,
              action != "wiki" || appModel.store.wikiEnabled else { return }
        let original = task.detail
        guard range.location >= 0, range.length > 0, NSMaxRange(range) <= (original as NSString).length else { return }
        let source = (original as NSString).substring(with: range)
        guard source == selectedText else {
            appModel.aiError = L10n.text("error.aiSelectionChanged")
            return
        }
        if action == "optimize" {
            _ = appModel.beginAIReview(target: .task(task.id), originalDocument: original,
                                       selectedText: source, range: range,
                                       applyTaskReplacement: applyReplacement)
            return
        }
        pendingAIOriginal = original
        pendingAIRange = range
        isWikiBusy = true
        Task { @MainActor in
            defer { finishAIAction() }
            do {
                let outcome = try await appModel.performAIAction(action, noteID: task.id, selectedText: source)
                switch outcome {
                case .wiki(let notes):
                    finishAIAction()
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

    private func finishAIAction() {
        pendingAIOriginal = nil
        pendingAIRange = nil
        isWikiBusy = false
    }
}

struct TaskTextSelectionSnapshot: Equatable {
    let text: String
    let range: NSRange

    func matches(_ content: String) -> Bool {
        range.location >= 0 && range.length > 0 && NSMaxRange(range) <= (content as NSString).length
            && (content as NSString).substring(with: range) == text
    }
}

@MainActor
final class TaskTextUndoObserver {
    private weak var textView: NSTextView?
    private weak var observedUndoManager: UndoManager?
    private var notificationTokens: [NSObjectProtocol] = []
    private let onUndoOrRedo: (String) -> Void

    init(textView: NSTextView, onUndoOrRedo: @escaping (String) -> Void) {
        self.textView = textView
        self.onUndoOrRedo = onUndoOrRedo
        refresh()
    }

    func refresh() {
        guard let textView, let undoManager = textView.undoManager,
              observedUndoManager !== undoManager else { return }
        cancel()
        observedUndoManager = undoManager
        let center = NotificationCenter.default
        for name in [Notification.Name.NSUndoManagerDidUndoChange, Notification.Name.NSUndoManagerDidRedoChange] {
            notificationTokens.append(center.addObserver(forName: name, object: undoManager, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, let textView = self.textView else { return }
                    self.onUndoOrRedo(textView.string)
                }
            })
        }
    }

    func cancel() {
        for token in notificationTokens { NotificationCenter.default.removeObserver(token) }
        notificationTokens.removeAll()
        observedUndoManager = nil
    }
}

private struct TaskDescriptionTextView: NSViewRepresentable {
    var text: String
    var isBusy: Bool
    var isAIEnabled: Bool
    var isWikiEnabled: Bool
    var busySelectionRange: NSRange?
    var busySourceText: String?
    var reduceMotion: Bool
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
        view.textContainerInset = NSSize(width: 0, height: 8)
        view.textContainer?.lineFragmentPadding = 0
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.string = text
        view.isAIEnabled = isAIEnabled
        view.isWikiEnabled = isWikiEnabled
        view.setAIBusy(isBusy, selectionRange: busySelectionRange, sourceText: busySourceText, reduceMotion: reduceMotion)
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
        context.coordinator.observeUndoChanges(for: view)
        view.isAIEnabled = isAIEnabled
        view.isWikiEnabled = isWikiEnabled
        if view.string != text, !view.hasMarkedText() {
            if isBusy && text != busySourceText {
                view.setAIBusy(false, selectionRange: nil, sourceText: nil, reduceMotion: true)
            }
            view.string = text
        }
        view.setAIBusy(isBusy, selectionRange: busySelectionRange, sourceText: busySourceText, reduceMotion: reduceMotion)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        guard let view = scroll.documentView as? TaskSelectionTextView else { return }
        view.delegate = nil
        view.onAIAction = nil
        view.setAIBusy(false, selectionRange: nil, sourceText: nil, reduceMotion: true)
        coordinator.cancelUndoObservation()
        coordinator.textView = nil
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var onChange: (String) -> Void
        var onAIAction: (String, String, NSRange, @escaping (String) -> Bool) -> Void
        weak var textView: NSTextView?
        private var undoObserver: TaskTextUndoObserver?

        init(onChange: @escaping (String) -> Void, onAIAction: @escaping (String, String, NSRange, @escaping (String) -> Bool) -> Void) {
            self.onChange = onChange
            self.onAIAction = onAIAction
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            if let taskTextView = view as? TaskSelectionTextView, taskTextView.isAIBusy {
                taskTextView.setAIBusy(false, selectionRange: nil, sourceText: nil, reduceMotion: true)
            }
            onChange(view.string)
        }

        func observeUndoChanges(for view: NSTextView) {
            if undoObserver == nil {
                undoObserver = TaskTextUndoObserver(textView: view) { [weak self] text in self?.onChange(text) }
            }
            undoObserver?.refresh()
        }

        func cancelUndoObservation() {
            undoObserver?.cancel()
            undoObserver = nil
        }
    }
}

final class TaskSelectionTextView: NSTextView {
    var onAIAction: ((String, String, NSRange, @escaping (String) -> Bool) -> Void)?
    var isAIEnabled = false
    var isWikiEnabled = false
    private(set) var isAIBusy = false
    private var contextualSelection: (text: String, range: NSRange)?
    private var busySelectionRange: NSRange?
    private var busyIndicator: AIBusyIndicatorView?

    var hasBusyIndicator: Bool { busyIndicator != nil }

    func setAIBusy(_ busy: Bool, selectionRange: NSRange?, sourceText: String?, reduceMotion: Bool) {
        guard busy, sourceText == string, let selectionRange,
              selectionRange.location >= 0, selectionRange.length > 0,
              NSMaxRange(selectionRange) <= (string as NSString).length else {
            clearAIBusyPresentation()
            return
        }

        isAIBusy = true
        if busySelectionRange != selectionRange {
            clearBusyRangeAttributes()
            busySelectionRange = selectionRange
            layoutManager?.addTemporaryAttribute(
                .foregroundColor,
                value: NSColor.secondaryLabelColor,
                forCharacterRange: selectionRange
            )
            let collapsedRange = NSRange(location: NSMaxRange(selectionRange), length: 0)
            setSelectedRange(collapsedRange)
        }
        positionBusyIndicator(for: selectionRange, reduceMotion: reduceMotion)
    }

    private func clearAIBusyPresentation() {
        isAIBusy = false
        clearBusyRangeAttributes()
        busyIndicator?.removeFromSuperview()
        busyIndicator = nil
    }

    private func clearBusyRangeAttributes() {
        let contentLength = (string as NSString).length
        if contentLength > 0 {
            layoutManager?.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: contentLength))
        }
        busySelectionRange = nil
    }

    private func positionBusyIndicator(for range: NSRange, reduceMotion: Bool) {
        guard let layoutManager, let textContainer else { return }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let glyphBounds = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        let center = NSPoint(
            x: glyphBounds.midX + textContainerOrigin.x,
            y: glyphBounds.midY + textContainerOrigin.y
        )
        let size: CGFloat = 24
        let indicator = busyIndicator ?? AIBusyIndicatorView(frame: .zero)
        indicator.reduceMotion = reduceMotion
        indicator.frame = NSRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
        if indicator.superview == nil { addSubview(indicator) }
        busyIndicator = indicator
    }

    override func didChangeText() {
        if isAIBusy { clearAIBusyPresentation() }
        super.didChangeText()
    }

    override func layout() {
        super.layout()
        if let busySelectionRange,
           busySelectionRange.location >= 0,
           busySelectionRange.length > 0,
           NSMaxRange(busySelectionRange) <= (string as NSString).length {
            positionBusyIndicator(for: busySelectionRange, reduceMotion: busyIndicator?.reduceMotion ?? true)
        } else if busySelectionRange != nil {
            clearAIBusyPresentation()
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu(title: "")
        let range = selectedRange()
        let selected = range.length > 0 && NSMaxRange(range) <= (string as NSString).length
            ? (string as NSString).substring(with: range) : ""
        contextualSelection = selected.isEmpty ? nil : (selected, range)
        if isWikiEnabled {
            let wiki = NSMenuItem(title: L10n.text("action.wiki"), action: #selector(createWikiFromSelection), keyEquivalent: "")
            wiki.target = self
            wiki.isEnabled = !selected.isEmpty && !isAIBusy && isAIEnabled
            menu.addItem(wiki)
        }
        let optimize = NSMenuItem(title: L10n.text("action.optimize"), action: #selector(optimizeSelection), keyEquivalent: "")
        optimize.target = self
        optimize.isEnabled = !selected.isEmpty && !isAIBusy && isAIEnabled
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
        guard !isAIBusy, isAIEnabled, action != "wiki" || isWikiEnabled else { return }
        let selectionValue = contextualSelection ?? {
            let range = selectedRange()
            guard range.length > 0, NSMaxRange(range) <= (string as NSString).length else { return nil }
            return ((string as NSString).substring(with: range), range)
        }()
        contextualSelection = nil
        guard let selectionValue else { return }
        let selection = TaskTextSelectionSnapshot(text: selectionValue.text, range: selectionValue.range)
        guard selection.matches(string) else { return }
        onAIAction?(action, selection.text, selection.range) { [weak self] replacement in
            self?.replace(replacement, for: selection) ?? false
        }
    }

    @discardableResult
    func replace(_ replacement: String, for selection: TaskTextSelectionSnapshot) -> Bool {
        guard selection.matches(string),
              performValidatedReplacement(
                in: selection.range,
                with: NSAttributedString(string: replacement)
              ) else { return false }
        let caret = selection.range.location + (replacement as NSString).length
        let caretRange = NSRange(location: caret, length: 0)
        setSelectedRange(caretRange)
        window?.makeFirstResponder(self)
        scrollRangeToVisible(caretRange)
        return true
    }
}

private final class AIBusyIndicatorView: NSView {
    private let surface = CAShapeLayer()
    private let ring = CAShapeLayer()
    private let core = CAShapeLayer()
    var reduceMotion = false { didSet { if oldValue != reduceMotion { updateMotion() } } }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel(L10n.text("action.aiBusy"))
        setAccessibilityValue(L10n.text("action.aiBusy"))
        layer?.addSublayer(surface)
        layer?.addSublayer(ring)
        layer?.addSublayer(core)
        surface.fillColor = NSColor.windowBackgroundColor.withAlphaComponent(0.88).cgColor
        surface.shadowColor = NSColor.black.withAlphaComponent(0.16).cgColor
        surface.shadowOpacity = 1
        surface.shadowRadius = 2
        surface.shadowOffset = .zero
        ring.fillColor = NSColor.clear.cgColor
        ring.strokeColor = NSColor.controlAccentColor.cgColor
        ring.lineWidth = 2.2
        ring.lineCap = .round
        ring.strokeEnd = 0.72
        core.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.30).cgColor
        updateMotion()
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let surfaceRect = bounds.insetBy(dx: 0.6, dy: 0.6)
        surface.frame = bounds
        surface.path = CGPath(ellipseIn: surfaceRect, transform: nil)
        ring.frame = bounds
        ring.path = CGPath(ellipseIn: bounds.insetBy(dx: 3.1, dy: 3.1), transform: nil)
        core.frame = bounds
        core.path = CGPath(ellipseIn: NSRect(x: bounds.midX - 2.1, y: bounds.midY - 2.1, width: 4.2, height: 4.2), transform: nil)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func updateMotion() {
        ring.removeAnimation(forKey: "turn")
        core.removeAnimation(forKey: "pulse")
        guard !reduceMotion else { return }

        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        turn.toValue = Double.pi * 2
        turn.duration = 1.25
        turn.repeatCount = .infinity
        turn.timingFunction = CAMediaTimingFunction(name: .linear)
        ring.add(turn, forKey: "turn")

        let pulse = CABasicAnimation(keyPath: "transform.scale")
        pulse.fromValue = 0.82
        pulse.toValue = 1.12
        pulse.duration = 0.68
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        core.add(pulse, forKey: "pulse")
    }
}
