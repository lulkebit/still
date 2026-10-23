import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum FolderAction {
    case rename(Folder)
    case move(Folder, [String])
    case trash(Folder)
}

private enum SheetRoute: Identifiable {
    case createFolder(NoteSection, [String])
    case renameFolder(Folder)
    case renameNote(Note)

    var id: String {
        switch self {
        case .createFolder(let section, let path): "new:\(section.rawValue):\(path.joined(separator: "/"))"
        case .renameFolder(let folder): "folder:\(folder.id)"
        case .renameNote(let note): "note:\(note.id.uuidString)"
        }
    }
}

struct ContentView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var activeSection: WorkspaceSection = .notes
    @State private var folderPath: [String] = []
    @State private var selectedNoteID: UUID?
    @State private var selectedTaskID: UUID?
    @State private var selectedTrashID: UUID?
    @State private var folderDisclosureState = FolderDisclosureState()
    @State private var query = ""
    @State private var showTrash = false
    @State private var showSettings = false
    @State private var isSidebarVisible = true
    @State private var focusSearchWhenVisible = false
    @State private var lastSidebarShortcutTime: TimeInterval = 0
    @State private var sheetRoute: SheetRoute?
    @State private var folderToTrash: Folder?
    @State private var noteToTrash: UUID?
    @State private var showFolderTrashConfirmation = false
    @State private var showNoteTrashConfirmation = false
    @State private var pendingWikiLink: WikiLinkRequest?
    @State private var showingMissingWikiLink = false
    let appModel: StillAppModel
    let commandBus: EditorCommandBus
    let noteNavigation: NoteNavigationHistory

    private var store: StillStore { appModel.store }
    private var selectedNote: Note? { store.notes.first(where: { $0.id == selectedNoteID }) }
    private var currentNoteSection: NoteSection { activeSection == .wiki ? .wiki : .notes }

    var body: some View {
        ZStack {
            windowBackground
            if !reduceTransparency {
                // Tint the blurred result, keeping text contrast stable in both appearances.
                (colorScheme == .dark ? Color.black : Color.white)
                    .opacity(0.07)
                    .ignoresSafeArea()
            }
            workspaceColumns.padding(.top, 12)
        }
        .background(WindowConfigurator(reduceTransparency: reduceTransparency).frame(width: 0, height: 0))
        .frame(minWidth: 960, minHeight: 640)
        .overlay(alignment: .top) { statusBanner }
        .onAppear {
            noteNavigation.updateNotes(store.notes)
            restoreLastNote()
        }
        .onReceive(NotificationCenter.default.publisher(for: .stillNavigateBack)) { _ in navigateBack() }
        .onReceive(NotificationCenter.default.publisher(for: .stillToggleSidebar)) { _ in
            toggleSidebarFromShortcut()
        }
        .onReceive(NotificationCenter.default.publisher(for: .stillFocusSearch)) { _ in
            guard !isSidebarVisible else {
                focusSearchWhenVisible = true
                return
            }
            withAnimation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.94)) {
                isSidebarVisible = true
            }
            focusSearchWhenVisible = true
        }
        .onChange(of: selectedNoteID) { _, id in store.setLastOpenedNote(id) }
        .onChange(of: folderPath) { _, path in
            guard !showTrash, activeSection != .tasks else { return }
            if let selectedNote, selectedNote.section == currentNoteSection, selectedNote.folders == path { return }
            let nextID = store.notes(in: currentNoteSection, folderPath: path).first?.id
            noteNavigation.record(from: selectedNoteID, to: nextID)
            selectedNoteID = nextID
        }
        .onChange(of: store.notes) { _, newNotes in
            noteNavigation.updateNotes(newNotes)
            repairSelection(after: newNotes)
        }
        .onChange(of: showTrash) { _, isTrash in
            if isTrash { selectedTrashID = store.trash.first?.id }
        }
        .sheet(isPresented: $showSettings) { AISettingsView(appModel: appModel) }
        .sheet(item: $sheetRoute, content: sheetContent)
        .confirmationDialog(
            L10n.text("dialog.deleteFolderTitle"),
            isPresented: $showFolderTrashConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.text("list.deleteFolder"), role: .destructive) { trashFolder() }.pointerStyle(.link)
            Button(L10n.text("action.cancel"), role: .cancel) { folderToTrash = nil }.pointerStyle(.link)
        } message: {
            folderDeleteMessage
        }
        .confirmationDialog(
            L10n.text("dialog.deleteNoteTitle"),
            isPresented: $showNoteTrashConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.text("list.delete"), role: .destructive) { trashNote() }.pointerStyle(.link)
            Button(L10n.text("action.cancel"), role: .cancel) { noteToTrash = nil }.pointerStyle(.link)
        } message: {
            noteDeleteMessage
        }
        .confirmationDialog(
            L10n.text("dialog.createLinkedNoteTitle"),
            isPresented: $showingMissingWikiLink,
            titleVisibility: .visible
        ) {
            Button(L10n.text("dialog.createLinkedNoteAction")) { createMissingWikiLink() }.pointerStyle(.link)
            Button(L10n.text("action.cancel"), role: .cancel) { pendingWikiLink = nil }.pointerStyle(.link)
        } message: {
            Text(verbatim: missingWikiLinkDetails)
        }
    }

    @ViewBuilder
    private var windowBackground: some View {
        if reduceTransparency { Color(nsColor: .windowBackgroundColor).ignoresSafeArea() }
        else { VisualEffectBackground().ignoresSafeArea() }
    }

    private var workspaceColumns: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                if isSidebarVisible {
                    NavigationSidebar(
                        activeSection: $activeSection,
                        folderPath: $folderPath,
                        showTrash: $showTrash,
                        selectedNoteID: $selectedNoteID,
                        selectedTrashID: $selectedTrashID,
                        folderDisclosureState: $folderDisclosureState,
                        query: $query,
                        focusSearchWhenVisible: $focusSearchWhenVisible,
                        store: store,
                        onToggleSidebar: toggleSidebarFromButton,
                        onSelectSection: selectSection,
                        onOpenNote: openNote,
                        onOpenTrashItem: { selectedTrashID = $0.id },
                        onRestoreTrash: restoreTrashItem,
                        onCreateNote: createNote,
                        onCreateFolder: { sheetRoute = .createFolder(currentNoteSection, folderPath) },
                        onRenameNote: { sheetRoute = .renameNote($0) },
                        onMoveNote: moveNote,
                        onTrashNote: { noteToTrash = $0; showNoteTrashConfirmation = true },
                        onOpenSettings: { showSettings = true },
                        onFolderAction: handleFolderAction
                    )
                    .transition(.move(edge: .leading).combined(with: .opacity))
                }
                workspaceContent
            }
            if !isSidebarVisible {
                sidebarToggleButton
                    .padding(.leading, 12)
                    .padding(.top, 12)
                    .transition(.opacity)
                    .zIndex(2)
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.94), value: isSidebarVisible)
    }

    private var sidebarToggleButton: some View {
        Button(action: toggleSidebarFromButton) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(CalmButtonStyle()).pointerStyle(.link).calmHover(cornerRadius: 7)
        .help(L10n.text("sidebar.show"))
        .accessibilityLabel(L10n.text("sidebar.show"))
        .accessibilityIdentifier("show-sidebar")
    }

    @ViewBuilder
    private var workspaceContent: some View {
        if !showTrash && !query.isEmpty {
            GlobalSearchBoard(
                store: store,
                query: query,
                onOpenNote: openNote,
                onOpenTask: openTask,
                onOpenEmbeddedTask: { openNote(id: $0.noteID) }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if activeSection == .tasks && !showTrash {
            TaskBoardView(appModel: appModel, query: query, selectedTaskID: $selectedTaskID, onOpenNote: openNote)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            documentDetail
        }
    }

    @ViewBuilder
    private var documentDetail: some View {
        if showTrash {
            TrashDetailView(entry: store.trash.first(where: { $0.id == selectedTrashID }), onRestore: restoreTrashItem)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            MainDocumentView(note: selectedNote, breadcrumb: breadcrumb, appModel: appModel,
                             commands: commandBus, reduceMotion: reduceMotion,
                             canNavigateBack: noteNavigation.canGoBack,
                             onNavigateBack: navigateBack,
                             onOpenNote: { openNote(id: $0) },
                             onWikiCreated: { openNote(id: $0.id) },
                             onOpenWikiLink: openWikiLink,
                             onOpenExternalLink: openExternalLink)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var breadcrumb: String {
        let root = L10n.text(activeSection == .wiki ? "nav.wiki" : "nav.notes")
        return ([root] + folderPath).joined(separator: "  /  ")
    }

    private var folderDeleteMessage: some View { Text(verbatim: L10n.text("dialog.deleteFolderBody")) }
    private var noteDeleteMessage: some View { Text(verbatim: L10n.text("dialog.deleteNoteBody")) }

    @ViewBuilder
    private var statusBanner: some View {
        let message = store.loadError ?? store.errorMessage ?? appModel.aiError ?? appModel.feedback
        if let message {
            HStack(spacing: 8) {
                Image(systemName: store.loadError != nil || store.errorMessage != nil || appModel.aiError != nil ? "exclamationmark.circle" : "checkmark.circle")
                Text(message).font(.system(size: 12)).lineLimit(2)
                Spacer(minLength: 10)
                if store.loadError == nil {
                    Button {
                        store.clearError()
                        appModel.aiError = nil
                        appModel.feedback = nil
                    } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                    .buttonStyle(CalmButtonStyle()).pointerStyle(.link).calmHover(cornerRadius: 6)
                    .accessibilityLabel(L10n.text("action.dismiss"))
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
            .padding(.top, 14)
            .frame(maxWidth: 620)
            .transition(.move(edge: .top).combined(with: .opacity))
            .zIndex(3)
        }
    }

    @ViewBuilder
    private func sheetContent(for route: SheetRoute) -> some View {
        switch route {
        case .createFolder(let section, let parent):
            NameEntrySheet(title: L10n.text("dialog.newFolder"), initialValue: "") { name in
                do { _ = try store.createFolder(section: section, parentPath: parent, name: name) }
                catch { store.report(error) }
            }
        case .renameFolder(let folder):
            NameEntrySheet(title: L10n.text("dialog.renameFolder"), initialValue: folder.name) { name in
                do {
                    try store.renameFolder(folder, name: name)
                    let target = Array(folder.path.dropLast()) + [try PathSafety.folderComponent(name)]
                    if folderPath.starts(with: folder.path) { folderPath = target + folderPath.dropFirst(folder.path.count) }
                } catch { store.report(error) }
            }
        case .renameNote(let note):
            NameEntrySheet(title: L10n.text("dialog.renameNote"), initialValue: note.title) { name in
                do { try store.renameNote(id: note.id, title: name) }
                catch { store.report(error) }
            }
        }
    }

    private func restoreLastNote() {
        guard store.loadError == nil else { return }
        let note = store.notes.first(where: { $0.id == store.lastOpenedNoteID }) ?? store.notes.sorted { $0.updatedAt > $1.updatedAt }.first
        if let note {
            activeSection = note.section == .wiki ? .wiki : .notes
            folderPath = note.folders
            selectedNoteID = note.id
            folderDisclosureState.expandAncestors(section: note.section, path: note.folders)
        }
    }

    private func repairSelection(after newNotes: [Note]) {
        guard let selectedID = selectedNoteID else { return }
        let stillExists = newNotes.contains { note in note.id == selectedID }
        guard !stillExists else { return }
        selectedNoteID = store.notes(in: currentNoteSection, folderPath: folderPath).first?.id
    }

    private func selectSection(_ section: WorkspaceSection) {
        withAnimation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.94)) {
            showTrash = false
            activeSection = section
            folderPath = []
            if section != .tasks {
                let noteSection: NoteSection = section == .wiki ? .wiki : .notes
                let note = store.notes(in: noteSection).first
                noteNavigation.record(from: selectedNoteID, to: note?.id)
                selectedNoteID = note?.id
            }
        }
    }

    private func toggleSidebarFromButton() {
        withAnimation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.94)) {
            isSidebarVisible.toggle()
        }
    }

    private func toggleSidebarFromShortcut() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastSidebarShortcutTime > 0.18 else { return }
        lastSidebarShortcutTime = now
        toggleSidebarFromButton()
    }

    private func createNote() {
        do {
            let note = try store.createNote(section: currentNoteSection, folders: folderPath)
            openNote(id: note.id)
        } catch { store.report(error) }
    }

    private func openNote(id: UUID) {
        guard let note = store.notes.first(where: { $0.id == id }) else { return }
        noteNavigation.record(from: selectedNoteID, to: note.id)
        openNoteWithoutRecording(note)
    }

    private func openNoteWithoutRecording(_ note: Note) {
        showTrash = false
        query = ""
        activeSection = note.section == .wiki ? .wiki : .notes
        folderPath = note.folders
        selectedNoteID = note.id
        folderDisclosureState.expandAncestors(section: note.section, path: note.folders)
    }

    private func navigateBack() {
        guard let id = noteNavigation.popPrevious(),
              let note = store.notes.first(where: { $0.id == id }) else { return }
        openNoteWithoutRecording(note)
    }

    private func openWikiLink(_ request: WikiLinkRequest) {
        guard selectedNoteID == request.id,
              let source = store.notes.first(where: { $0.id == request.id }),
              EditorLinkRequestPolicy.isCurrent(request, currentDocumentID: selectedNoteID, markdown: source.markdown) else { return }
        switch NoteLinks.resolution(target: request.target, from: source, notes: store.notes) {
        case let .resolved(note):
            openNote(id: note.id)
        case .missing:
            pendingWikiLink = request
            showingMissingWikiLink = true
        case .ambiguous:
            store.report(StoreError.ambiguousWikiLink)
        case .invalid:
            store.report(StoreError.invalidWikiLink)
        }
    }

    private func createMissingWikiLink() {
        defer { pendingWikiLink = nil }
        guard let request = pendingWikiLink,
              selectedNoteID == request.id,
              let source = store.notes.first(where: { $0.id == request.id }),
              EditorLinkRequestPolicy.isCurrent(request, currentDocumentID: selectedNoteID, markdown: source.markdown) else { return }
        switch NoteLinks.resolution(target: request.target, from: source, notes: store.notes) {
        case let .resolved(note):
            openNote(id: note.id)
        case .missing:
            do { openNote(id: try store.createLinkedNote(target: request.target, from: source).id) }
            catch { store.report(error) }
        case .ambiguous:
            store.report(StoreError.ambiguousWikiLink)
        case .invalid:
            store.report(StoreError.invalidWikiLink)
        }
    }

    private var missingWikiLinkDetails: String {
        guard let request = pendingWikiLink,
              let source = store.notes.first(where: { $0.id == request.id }),
              let destination = NoteLinks.destination(for: request.target, from: source) else {
            return pendingWikiLink?.target ?? ""
        }
        let section = L10n.text(destination.section == .wiki ? "editor.linkSectionWiki" : "editor.linkSectionNotes")
        let location = ([section] + destination.folders).joined(separator: " / ")
        return String(format: L10n.text("dialog.createLinkedNoteBody"), destination.title, location)
    }

    private func openExternalLink(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    private func openTask(id: UUID) {
        showTrash = false
        query = ""
        activeSection = .tasks
        selectedTaskID = id
    }

    private func moveNote(id: UUID, section: NoteSection, path: [String]) {
        do {
            try store.moveNote(id: id, section: section, folders: path)
            if selectedNoteID == id {
                activeSection = section == .wiki ? .wiki : .notes
                folderPath = path
                folderDisclosureState.expandAncestors(section: section, path: path)
            }
        } catch { store.report(error) }
    }

    private func moveFolder(_ folder: Folder, to path: [String]) {
        do {
            try store.moveFolder(folder, into: path)
            if folderPath.starts(with: folder.path) {
                folderPath = path + folder.path.suffix(1) + folderPath.dropFirst(folder.path.count)
            }
        } catch { store.report(error) }
    }

    private func handleFolderAction(_ action: FolderAction) {
        switch action {
        case .rename(let folder): sheetRoute = .renameFolder(folder)
        case .move(let folder, let path): moveFolder(folder, to: path)
        case .trash(let folder): folderToTrash = folder; showFolderTrashConfirmation = true
        }
    }

    private func trashFolder() {
        guard let folder = folderToTrash else { return }
        do {
            try store.trashFolder(folder)
            if folderPath.starts(with: folder.path) { folderPath = Array(folder.path.dropLast()) }
            showTrash = true
            selectedTrashID = store.trash.first?.id
        } catch { store.report(error) }
        folderToTrash = nil
    }

    private func trashNote() {
        guard let id = noteToTrash else { return }
        do {
            try store.trashNote(id: id)
            if selectedNoteID == id { selectedNoteID = store.notes(in: currentNoteSection, folderPath: folderPath).first?.id }
        } catch { store.report(error) }
        noteToTrash = nil
    }

    private func restoreTrashItem(_ entry: TrashEntry) {
        do {
            try store.restoreTrashItem(id: entry.id)
            if let restored = store.notes.first(where: { $0.id == entry.id }) {
                openNote(id: restored.id)
            }
        } catch { store.report(error) }
    }
}

private struct NavigationSidebar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var activeSection: WorkspaceSection
    @Binding var folderPath: [String]
    @Binding var showTrash: Bool
    @Binding var selectedNoteID: UUID?
    @Binding var selectedTrashID: UUID?
    @Binding var folderDisclosureState: FolderDisclosureState
    @Binding var query: String
    @Binding var focusSearchWhenVisible: Bool
    let store: StillStore
    let onToggleSidebar: () -> Void
    let onSelectSection: (WorkspaceSection) -> Void
    let onOpenNote: (UUID) -> Void
    let onOpenTrashItem: (TrashEntry) -> Void
    let onRestoreTrash: (TrashEntry) -> Void
    let onCreateNote: () -> Void
    let onCreateFolder: () -> Void
    let onRenameNote: (Note) -> Void
    let onMoveNote: (UUID, NoteSection, [String]) -> Void
    let onTrashNote: (UUID) -> Void
    let onOpenSettings: () -> Void
    let onFolderAction: (FolderAction) -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(L10n.text("app.name"))
                    .font(.system(size: 25, weight: .semibold, design: .rounded))
                    .tracking(-0.8)
                    .accessibilityIdentifier("brand-title")
                Spacer(minLength: 0)
                Button(action: onToggleSidebar) {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 27, height: 27)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(CalmButtonStyle()).pointerStyle(.link).calmHover()
                .help(L10n.text("sidebar.hide"))
                .accessibilityLabel(L10n.text("sidebar.hide"))
                .accessibilityIdentifier("hide-sidebar")
            }
            .padding(.leading, 7)
            .padding(.top, 38)
            .padding(.bottom, 23)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
                TextField(L10n.text("sidebar.searchPlaceholder"), text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($searchFocused)
                    .accessibilityLabel(L10n.text("sidebar.searchAccessible"))
                    .accessibilityIdentifier("global-search")
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(.tertiary) }
                        .buttonStyle(CalmButtonStyle()).pointerStyle(.link).calmHover(cornerRadius: 6)
                        .accessibilityLabel(L10n.text("action.clearSearch"))
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.045), lineWidth: 0.5))
            .padding(.bottom, 20)

            VStack(spacing: 3) {
                ForEach(WorkspaceSection.allCases) { section in
                    Button { onSelectSection(section) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: icon(for: section)).font(.system(size: 14, weight: .regular)).frame(width: 17)
                            Text(L10n.text(section.localizationKey)).font(.system(size: 13, weight: activeSection == section && !showTrash ? .medium : .regular))
                            Spacer()
                        }
                        .foregroundStyle(activeSection == section && !showTrash ? Color.primary : Color.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(activeSection == section && !showTrash ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(CalmButtonStyle()).pointerStyle(.link).calmHover(cornerRadius: 7)
                    .accessibilityIdentifier("nav-\(section.rawValue)")
                }
            }

            if showTrash {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        if store.trash.isEmpty { EmptyListLabel(text: L10n.text("list.empty")) }
                        ForEach(store.trash) { entry in
                            TrashRow(entry: entry, isSelected: selectedTrashID == entry.id,
                                     onSelect: { onOpenTrashItem(entry) },
                                     onRestore: { onRestoreTrash(entry) })
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .padding(.top, 20)
            } else if activeSection != .tasks {
                HStack(alignment: .firstTextBaseline) {
                    Text(L10n.text("sidebar.folders").uppercased())
                        .font(.system(size: 10, weight: .medium))
                        .tracking(0.8)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 10)
                    Spacer()
                    Button(action: onCreateNote) {
                        Image(systemName: "plus").font(.system(size: 11, weight: .medium)).frame(width: 22, height: 22)
                    }
                    .buttonStyle(CalmButtonStyle()).pointerStyle(.link).calmHover(cornerRadius: 6)
                    .help(L10n.text("list.newNote"))
                    .accessibilityLabel(L10n.text("list.newNote"))
                    .accessibilityIdentifier("new-note")
                    Button(action: onCreateFolder) {
                        Image(systemName: "folder.badge.plus").font(.system(size: 11)).frame(width: 22, height: 22)
                    }
                    .buttonStyle(CalmButtonStyle()).pointerStyle(.link).calmHover(cornerRadius: 6)
                    .help(L10n.text("list.newFolder"))
                    .accessibilityLabel(L10n.text("list.newFolder"))
                    .accessibilityIdentifier("new-folder")
                }
                .foregroundStyle(.secondary)
                .padding(.top, 22).padding(.bottom, 7).padding(.trailing, 4)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        rootFolderNode
                    }
                    .padding(.bottom, 8)
                }
            }

            Spacer(minLength: 10)
            VStack(spacing: 3) {
                Button {
                    showTrash.toggle()
                    if showTrash { query = "" }
                } label: {
                    Label(L10n.text("nav.trash"), systemImage: "trash")
                        .font(.system(size: 12)).foregroundStyle(showTrash ? Color.primary : Color.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(showTrash ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(CalmButtonStyle()).pointerStyle(.link).calmHover(cornerRadius: 7)
                .accessibilityIdentifier("nav-trash")
                Button(action: onOpenSettings) {
                    Label(L10n.text("nav.settings"), systemImage: "gearshape")
                        .font(.system(size: 12)).foregroundStyle(Color.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(CalmButtonStyle()).pointerStyle(.link).calmHover(cornerRadius: 7)
                .accessibilityIdentifier("open-settings")
            }
            .padding(.bottom, 20)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(width: 208)
        .overlay(alignment: .trailing) { Rectangle().fill(Color.primary.opacity(0.045)).frame(width: 1) }
        .onChange(of: focusSearchWhenVisible) { _, shouldFocus in
            guard shouldFocus else { return }
            searchFocused = true
            focusSearchWhenVisible = false
        }
        .onAppear {
            if focusSearchWhenVisible {
                searchFocused = true
                focusSearchWhenVisible = false
            }
        }
    }

    private var activeNoteSection: NoteSection { activeSection == .wiki ? .wiki : .notes }
    private var rootFolderNode: some View {
        let rootID = FolderDisclosureState.rootID(for: activeNoteSection)
        let isExpanded = folderDisclosureState.isExpanded(rootID)
        return VStack(alignment: .leading, spacing: 2) {
            Button {
                withAnimation(disclosureAnimation) {
                    if !isExpanded { folderPath = [] }
                    folderDisclosureState.toggle(rootID)
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 14, height: 26)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Image(systemName: "tray.full").font(.system(size: 12)).frame(width: 15)
                    Text(L10n.text(activeSection == .wiki ? "nav.wiki" : "nav.notes"))
                        .font(.system(size: 12, weight: folderPath.isEmpty ? .medium : .regular))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(folderPath.isEmpty ? Color.primary : Color.secondary)
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(folderPath.isEmpty ? Color.primary.opacity(0.055) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
            }
            .buttonStyle(CalmButtonStyle()).pointerStyle(.link).calmHover(cornerRadius: 6)
            .accessibilityValue(L10n.text(isExpanded ? "action.collapse" : "action.expand"))
            .accessibilityIdentifier("folder-root-\(activeSection.rawValue)")
            if isExpanded {
                ForEach(store.notes(in: activeNoteSection, folderPath: [])) { note in
                    SidebarNoteRow(note: note, isSelected: selectedNoteID == note.id, store: store,
                                   onOpen: { onOpenNote(note.id) }, onRename: { onRenameNote(note) },
                                   onMove: onMoveNote, onTrash: onTrashNote)
                        .padding(.leading, 16)
                }
                ForEach(store.childFolders(in: activeNoteSection, parentPath: [])) { folder in
                    FolderTreeNode(
                        folder: folder, store: store,
                        selectedPath: $folderPath,
                        selectedNoteID: $selectedNoteID,
                        folderDisclosureState: $folderDisclosureState,
                        onOpenNote: onOpenNote,
                        onRenameNote: onRenameNote,
                        onMoveNote: onMoveNote,
                        onTrashNote: onTrashNote,
                        onAction: onFolderAction,
                        depth: 0
                    )
                }
            }
        }
        .animation(disclosureAnimation, value: isExpanded)
    }

    private var disclosureAnimation: Animation? {
        reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.78)
    }

    private func icon(for section: WorkspaceSection) -> String {
        switch section { case .notes: "note.text"; case .tasks: "checklist"; case .wiki: "books.vertical" }
    }
}

private struct FolderTreeNode: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let folder: Folder
    let store: StillStore
    @Binding var selectedPath: [String]
    @Binding var selectedNoteID: UUID?
    @Binding var folderDisclosureState: FolderDisclosureState
    let onOpenNote: (UUID) -> Void
    let onRenameNote: (Note) -> Void
    let onMoveNote: (UUID, NoteSection, [String]) -> Void
    let onTrashNote: (UUID) -> Void
    let onAction: (FolderAction) -> Void
    let depth: Int

    private var children: [Folder] { store.childFolders(in: folder.section, parentPath: folder.path) }
    private var notes: [Note] { store.notes(in: folder.section, folderPath: folder.path) }
    private var isExpanded: Bool { folderDisclosureState.isExpanded(folder.id) }
    private var isSelected: Bool { selectedPath == folder.path }
    private var hasContents: Bool { !children.isEmpty || !notes.isEmpty }
    private var moveTargets: [[String]] {
        [[]] + store.folders.filter { $0.section == folder.section && !$0.path.starts(with: folder.path) }
            .map(\.path).sorted { $0.joined(separator: "/").localizedStandardCompare($1.joined(separator: "/")) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 2) {
                Button {
                    withAnimation(disclosureAnimation) {
                        if isExpanded {
                            folderDisclosureState.toggle(folder.id)
                        } else {
                            selectedPath = folder.path
                            if hasContents { folderDisclosureState.toggle(folder.id) }
                        }
                    }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: hasContents ? "chevron.right" : "circle.fill")
                            .font(.system(size: hasContents ? 9 : 3, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .frame(width: 14, height: 26)
                            .rotationEffect(.degrees(isExpanded && hasContents ? 90 : 0))
                        Image(systemName: "folder").font(.system(size: 12)).frame(width: 14)
                        Text(folder.name).font(.system(size: 12)).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    .padding(.vertical, 5).padding(.trailing, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(CalmButtonStyle()).pointerStyle(.link).calmHover(cornerRadius: 6)
                .accessibilityLabel(folder.name)
                .accessibilityValue(hasContents ? L10n.text(isExpanded ? "action.collapse" : "action.expand") : "")
                Menu {
                    Button(L10n.text("list.renameFolder"), systemImage: "pencil") { onAction(.rename(folder)) }
                    Menu(L10n.text("list.moveFolder"), systemImage: "folder") {
                        ForEach(moveTargets, id: \.self) { target in
                            Button(folderDestinationName(target)) { onAction(.move(folder, target)) }
                        }
                    }
                    Divider()
                    Button(L10n.text("list.deleteFolder"), systemImage: "trash", role: .destructive) { onAction(.trash(folder)) }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 11)).foregroundStyle(.tertiary).frame(width: 22, height: 24)
                }
                .menuStyle(.borderlessButton)
                .pointerStyle(.link).calmHover(cornerRadius: 6)
                .accessibilityLabel(L10n.text("list.more"))
            }
            .padding(.leading, CGFloat(depth) * 13)
            .background(isSelected ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contextMenu {
                Button(L10n.text("list.renameFolder"), systemImage: "pencil") { onAction(.rename(folder)) }
                Menu(L10n.text("list.moveFolder"), systemImage: "folder") {
                    ForEach(moveTargets, id: \.self) { target in Button(folderDestinationName(target)) { onAction(.move(folder, target)) } }
                }
                Button(L10n.text("list.deleteFolder"), systemImage: "trash", role: .destructive) { onAction(.trash(folder)) }
            }
            if isExpanded {
                ForEach(notes) { note in
                    SidebarNoteRow(note: note, isSelected: selectedNoteID == note.id, store: store,
                                   onOpen: { onOpenNote(note.id) }, onRename: { onRenameNote(note) },
                                   onMove: onMoveNote, onTrash: onTrashNote)
                        .padding(.leading, CGFloat(depth + 1) * 13)
                }
                ForEach(children) { child in
                    FolderTreeNode(folder: child, store: store, selectedPath: $selectedPath,
                                   selectedNoteID: $selectedNoteID,
                                   folderDisclosureState: $folderDisclosureState,
                                   onOpenNote: onOpenNote, onRenameNote: onRenameNote,
                                   onMoveNote: onMoveNote, onTrashNote: onTrashNote,
                                   onAction: onAction, depth: depth + 1)
                }
            }
        }
        .accessibilityIdentifier("folder-\(folder.id)")
        .animation(disclosureAnimation, value: isExpanded)
    }

    private func folderDestinationName(_ path: [String]) -> String {
        path.isEmpty ? L10n.text("list.rootFolder") : path.joined(separator: " / ")
    }

    private var disclosureAnimation: Animation? {
        reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.78)
    }
}

private struct SidebarNoteRow: View {
    let note: Note
    let isSelected: Bool
    let store: StillStore
    let onOpen: () -> Void
    let onRename: () -> Void
    let onMove: (UUID, NoteSection, [String]) -> Void
    let onTrash: (UUID) -> Void

    private var moveTargets: [(NoteSection, [String])] {
        [(NoteSection.notes, []), (NoteSection.wiki, [])] + store.folders.map { ($0.section, $0.path) }
    }

    var body: some View {
        HStack(spacing: 3) {
            Button(action: onOpen) {
                HStack(spacing: 7) {
                    Image(systemName: "doc.text").font(.system(size: 10)).foregroundStyle(.tertiary).frame(width: 12)
                    Text(note.title).font(.system(size: 11, weight: isSelected ? .medium : .regular))
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 7).padding(.vertical, 5)
                .background(isSelected ? Color.primary.opacity(0.055) : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
            }
            .buttonStyle(CalmButtonStyle()).pointerStyle(.link).calmHover(cornerRadius: 5)
            .accessibilityIdentifier("sidebar-note-\(note.id.uuidString)")
            Menu {
                Button(L10n.text("list.rename"), systemImage: "pencil", action: onRename)
                Menu(L10n.text("list.move"), systemImage: "folder") {
                    ForEach(Array(moveTargets.enumerated()), id: \.offset) { _, target in
                        let (section, path) = target
                        Button(moveDestination(section, path)) { onMove(note.id, section, path) }
                    }
                }
                Divider()
                Button(L10n.text("list.delete"), systemImage: "trash", role: .destructive) { onTrash(note.id) }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 10)).foregroundStyle(.tertiary)
                    .frame(width: 21, height: 23).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).pointerStyle(.link).calmHover(cornerRadius: 6)
            .accessibilityLabel(L10n.text("list.more"))
        }
        .contextMenu {
            Button(L10n.text("list.rename"), systemImage: "pencil", action: onRename)
            Menu(L10n.text("list.move"), systemImage: "folder") {
                ForEach(Array(moveTargets.enumerated()), id: \.offset) { _, target in
                    let (section, path) = target
                    Button(moveDestination(section, path)) { onMove(note.id, section, path) }
                }
            }
            Button(L10n.text("list.delete"), systemImage: "trash", role: .destructive) { onTrash(note.id) }
        }
    }

    private func moveDestination(_ section: NoteSection, _ path: [String]) -> String {
        let sectionTitle = L10n.text(section == .wiki ? "nav.wiki" : "nav.notes")
        return path.isEmpty ? sectionTitle : "\(sectionTitle)  /  \(path.joined(separator: " / "))"
    }
}

private struct TrashRow: View {
    let entry: TrashEntry
    let isSelected: Bool
    let onSelect: () -> Void
    let onRestore: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onSelect) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.title).font(.system(size: 12, weight: .medium)).lineLimit(1).foregroundStyle(.primary)
                    Text(entry.deletedAt, style: .relative).font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 9).padding(.vertical, 9)
            }
            .buttonStyle(CalmButtonStyle()).pointerStyle(.link).calmHover(cornerRadius: 7)
            Button(action: onRestore) {
                Image(systemName: "arrow.uturn.backward").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 28, height: 28)
            }
            .buttonStyle(CalmButtonStyle()).pointerStyle(.link).calmHover(cornerRadius: 6)
            .help(L10n.text("list.restore"))
        }
        .padding(.horizontal, 2)
        .background(isSelected ? Color.primary.opacity(0.075) : .clear, in: RoundedRectangle(cornerRadius: 7))
    }
}

private struct EmptyListLabel: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 12)).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 18)
    }
}

private struct TrashDetailView: View {
    let entry: TrashEntry?
    let onRestore: (TrashEntry) -> Void

    var body: some View {
        VStack(spacing: 12) {
            if let entry {
                Image(systemName: "trash").font(.system(size: 24)).foregroundStyle(.secondary)
                Text(entry.title).font(.system(size: 22, weight: .medium)).multilineTextAlignment(.center)
                Text(entry.deletedAt, style: .relative).font(.system(size: 12)).foregroundStyle(.secondary)
                Button(L10n.text("list.restore")) { onRestore(entry) }
                    .buttonStyle(.bordered).pointerStyle(.link).calmHover()
            } else {
                Image(systemName: "trash").font(.system(size: 24)).foregroundStyle(.tertiary)
                Text(L10n.text("list.empty")).font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MainDocumentView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @FocusState private var titleFocused: Bool
    @State private var titleText = ""
    @State private var isImportingImage = false
    @State private var imageImportDocumentID: UUID?

    let note: Note?
    let breadcrumb: String
    let appModel: StillAppModel
    let commands: EditorCommandBus
    let reduceMotion: Bool
    let canNavigateBack: Bool
    let onNavigateBack: () -> Void
    let onOpenNote: (UUID) -> Void
    let onWikiCreated: (Note) -> Void
    let onOpenWikiLink: (WikiLinkRequest) -> Void
    let onOpenExternalLink: (URL) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let note {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .center) {
                        Button(action: onNavigateBack) {
                            Image(systemName: "arrow.left")
                                .font(.system(size: 12, weight: .medium))
                                .frame(width: 25, height: 25)
                        }
                        .buttonStyle(CalmButtonStyle()).pointerStyle(canNavigateBack ? .link : nil).calmHover(isEnabled: canNavigateBack)
                        .disabled(!canNavigateBack)
                        .help(L10n.text("nav.back"))
                        .accessibilityLabel(L10n.text("nav.back"))
                        .accessibilityIdentifier("note-navigation-back")
                        Text(breadcrumb).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 12)
                        Menu {
                            Button(L10n.text("action.insertTable"), systemImage: "tablecells") {
                                commands.send(.insertMarkdown("\n| \(L10n.text("editor.tableColumn1")) | \(L10n.text("editor.tableColumn2")) |\n| --- | --- |\n|  |  |\n", documentID: note.id))
                            }
                            Button(L10n.text("action.insertDetails"), systemImage: "text.alignleft") {
                                commands.send(.insertMarkdown("\n<details>\n<summary>\(L10n.text("editor.detailsSummary"))</summary>\n\n\n</details>\n", documentID: note.id))
                            }
                            Button(L10n.text("action.insertImage"), systemImage: "photo") { openImagePanel(for: note) }
                        } label: {
                            Image(systemName: "plus").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).frame(width: 26, height: 26)
                        }
                        .menuStyle(.borderlessButton).pointerStyle(.link).calmHover(cornerRadius: 6)
                        .accessibilityLabel(L10n.text("action.insert"))
                        .accessibilityIdentifier("editor-insert-menu")
                    }
                    TextField(L10n.text("note.titlePlaceholder"), text: $titleText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 30, weight: .medium, design: .serif))
                        .tracking(-0.5)
                        .lineLimit(1)
                        .focused($titleFocused)
                        .onSubmit(commitTitle)
                        .onChange(of: titleFocused) { _, focused in if !focused { commitTitle() } }
                        .onChange(of: note.title) { _, value in if !titleFocused { titleText = value } }
                        .accessibilityIdentifier("document-title")
                }
                .padding(.horizontal, 54)
                .padding(.top, 42).padding(.bottom, 19)

                VStack(spacing: 0) {
                    MarkdownEditor(note: note, appModel: appModel, colorScheme: colorScheme, reduceMotion: reduceMotion,
                                   onWikiCreated: onWikiCreated, onOpenWikiLink: onOpenWikiLink,
                                   onOpenExternalLink: onOpenExternalLink, commands: commands)
                        .accessibilityIdentifier("markdown-editor")
                        .frame(maxWidth: 760, maxHeight: .infinity)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityElement(children: .contain)
                    let backlinkNotes = appModel.store.backlinks(to: note).sorted(by: backlinkOrder)
                    if !backlinkNotes.isEmpty {
                        backlinksSection(backlinkNotes)
                    }
                }
                .frame(maxWidth: 760, maxHeight: .infinity)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "note.text").font(.system(size: 26)).foregroundStyle(.tertiary)
                    Text(L10n.text("note.noSelectionTitle")).font(.system(size: 20, weight: .medium, design: .serif))
                    Text(L10n.text("note.noSelectionBody")).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 340)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.bottom, 22)
        .frame(maxWidth: 760, maxHeight: .infinity)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: note?.id) { _, _ in titleText = note?.title ?? "" }
        .onAppear { titleText = note?.title ?? "" }
        .fileImporter(
            isPresented: $isImportingImage,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false,
            onCompletion: handleImageImport
        )
    }

    private func commitTitle() {
        guard let note else { return }
        let trimmed = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { titleText = note.title; return }
        guard trimmed != note.title else { return }
        do { try appModel.store.renameNote(id: note.id, title: trimmed) }
        catch { appModel.store.report(error); titleText = note.title }
    }

    private func backlinksSection(_ notes: [Note]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(L10n.text("editor.backlinks")) · \(notes.count)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .tracking(0.5)
                .padding(.leading, 7)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(notes) { source in
                        Button { onOpenNote(source.id) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(source.title)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                Text(([L10n.text(source.section == .wiki ? "editor.linkSectionWiki" : "editor.linkSectionNotes")] + source.folders).joined(separator: " / "))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(CalmButtonStyle())
                        .pointerStyle(.link)
                        .calmHover(cornerRadius: 5)
                        .accessibilityIdentifier("backlink-\(source.id.uuidString)")
                    }
                }
            }
            .frame(maxHeight: 74)
        }
        // The row's 7pt inset aligns its text with the 54pt document title inset.
        .padding(.horizontal, 47)
        .padding(.top, 8)
        .padding(.bottom, 2)
        .frame(maxWidth: 760, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 0.5) }
    }

    private func backlinkOrder(_ lhs: Note, _ rhs: Note) -> Bool {
        let titleOrder = lhs.title.localizedStandardCompare(rhs.title)
        if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
        let lhsLocation = ([lhs.section.rawValue] + lhs.folders).joined(separator: "/")
        let rhsLocation = ([rhs.section.rawValue] + rhs.folders).joined(separator: "/")
        let locationOrder = lhsLocation.localizedStandardCompare(rhsLocation)
        if locationOrder != .orderedSame { return locationOrder == .orderedAscending }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func openImagePanel(for note: Note) {
        imageImportDocumentID = note.id
        isImportingImage = true
    }

    private func handleImageImport(_ result: Result<[URL], Error>) {
        let targetDocumentID = imageImportDocumentID
        imageImportDocumentID = nil
        guard let targetDocumentID, note?.id == targetDocumentID else { return }

        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let hasSecurityScope = url.startAccessingSecurityScopedResource()
            defer { if hasSecurityScope { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let filename = try appModel.store.addImage(data: data, filename: url.lastPathComponent,
                                                          mimeType: mimeType(for: url.pathExtension))
                commands.send(.insertImage(
                    url: "attachments/\(filename)",
                    alt: url.deletingPathExtension().lastPathComponent,
                    documentID: targetDocumentID
                ))
            } catch { appModel.store.report(error) }
        case .failure(let error):
            if (error as? CocoaError)?.code != .userCancelled { appModel.store.report(error) }
        }
    }

    private func mimeType(for extensionName: String) -> String {
        switch extensionName.lowercased() {
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        default: "application/octet-stream"
        }
    }
}

private struct NameEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    @State private var name: String
    let title: String
    let onSave: (String) -> Void

    init(title: String, initialValue: String, onSave: @escaping (String) -> Void) {
        self.title = title
        self.onSave = onSave
        _name = State(initialValue: initialValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.system(size: 17, weight: .semibold))
            TextField(L10n.text("dialog.namePlaceholder"), text: $name)
                .textFieldStyle(.roundedBorder).focused($focused).onSubmit(save)
            HStack {
                Spacer()
                Button(L10n.text("action.cancel")) { dismiss() }
                    .pointerStyle(.link).calmHover().keyboardShortcut(.cancelAction)
                Button(L10n.text("action.save")) { save() }
                    .pointerStyle(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : .link)
                    .calmHover(isEnabled: !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22).frame(width: 360)
        .onAppear { focused = true }
    }

    private func save() {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        onSave(value)
        dismiss()
    }
}
