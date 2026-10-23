import Foundation
import Observation

@MainActor
@Observable
final class StillStore {
    private(set) var notes: [Note] = []
    private(set) var folders: [Folder] = []
    private(set) var tasks: [TaskItem] = []
    private(set) var trash: [TrashEntry] = []
    private(set) var settings: AISettings = .empty
    private(set) var lastOpenedNoteID: UUID?
    private(set) var dirtyNoteIDs: Set<UUID> = []
    private(set) var loadError: String?
    var errorMessage: String?

    let rootURL: URL
    private var canWrite = false
    private(set) var linkCatalogRevision: UInt64 = 0
    @ObservationIgnored private var backlinkTargets: [UUID: Set<UUID>] = [:]
    @ObservationIgnored private let writeQueue = DispatchQueue(label: "still.autosave", qos: .utility)
    @ObservationIgnored private var autosaveTask: Task<Void, Never>?
    @ObservationIgnored private var pendingSaveStartedAt: ContinuousClock.Instant?
    @ObservationIgnored private var dirtyVersions: [UUID: UInt64] = [:]
    @ObservationIgnored private var editVersion: UInt64 = 0
    @ObservationIgnored private var saveSequence: UInt64 = 0
    @ObservationIgnored private var appliedSaveSequence: UInt64 = 0

    init(rootURL: URL? = nil, seedIfEmpty: Bool = true) {
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.rootURL = support.appendingPathComponent("still", isDirectory: true)
        }
        do {
            try load(seedIfEmpty: seedIfEmpty)
            canWrite = true
        } catch {
            loadError = L10n.message(for: error)
            canWrite = false
        }
    }

    var attachmentDirectory: URL { rootURL.appendingPathComponent("attachments", isDirectory: true) }

    var embeddedTasks: [EmbeddedTask] {
        notes.flatMap { note in
            Self.taskLines(in: note.markdown).compactMap { index, line in
                guard let match = Self.checkboxRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                      let stateRange = Range(match.range(at: 1), in: line),
                      let titleRange = Range(match.range(at: 2), in: line) else { return nil }
                let state = String(line[stateRange]).lowercased()
                let title = String(line[titleRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return nil }
                return EmbeddedTask(noteID: note.id, noteTitle: note.title, lineIndex: index, line: line,
                                    title: title, isDone: state == "x")
            }
        }
    }

    func notes(in section: NoteSection, folderPath: [String] = []) -> [Note] {
        notes.filter { $0.section == section && $0.folders == folderPath }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func resolveWikiLink(_ target: String, from source: Note) -> Note? {
        NoteLinks.resolve(target: target, from: source, notes: notes)
    }

    func backlinks(to note: Note) -> [Note] {
        notes.filter { source in
            guard source.id != note.id else { return false }
            if backlinkTargets[source.id] == nil {
                backlinkTargets[source.id] = Set(NoteLinks.links(in: source.markdown).compactMap {
                    resolveWikiLink($0.target, from: source)?.id
                })
            }
            return backlinkTargets[source.id]?.contains(note.id) == true
        }
    }

    func childFolders(in section: NoteSection, parentPath: [String]) -> [Folder] {
        folders.filter {
            $0.section == section && $0.path.count == parentPath.count + 1 && $0.path.starts(with: parentPath)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func folderExists(section: NoteSection, path: [String]) -> Bool {
        folders.contains { $0.section == section && Self.sameFolderPath($0.path, path) }
    }

    @discardableResult
    func createNote(section: NoteSection, folders targetFolders: [String] = [], title: String? = nil, markdown: String = "") throws -> Note {
        try ensureWritable()
        let safeFolders = try PathSafety.normalizeFolderPath(targetFolders)
        let previousFolders = folders
        ensureFolders(section: section, path: safeFolders)
        let baseTitle = nonemptyTitle(title ?? L10n.text("note.untitled"))
        let uniqueTitle = uniqueTitle(baseTitle, section: section, folders: safeFolders)
        let note = Note(title: uniqueTitle, section: section, folders: safeFolders, markdown: markdown)
        let nextNotes = notes + [note]
        do {
            try writeMarkdown(markdown, for: note)
            try saveManifest(notes: nextNotes)
        } catch {
            try? removeMarkdown(for: note)
            folders = previousFolders
            throw error
        }
        notes = nextNotes
        invalidateLinkCatalog()
        errorMessage = nil
        return note
    }

    @discardableResult
    func createLinkedNote(target: String, from source: Note) throws -> Note {
        try ensureWritable()
        guard let currentSource = notes.first(where: { $0.id == source.id }) else { throw StoreError.invalidWikiLink }
        switch NoteLinks.resolution(target: target, from: currentSource, notes: notes) {
        case let .resolved(note): return note
        case .ambiguous: throw StoreError.ambiguousWikiLink
        case .invalid: throw StoreError.invalidWikiLink
        case .missing: break
        }
        guard let destination = NoteLinks.destination(for: target, from: currentSource) else {
            throw StoreError.invalidWikiLink
        }
        let safeFolders = try PathSafety.normalizeFolderPath(destination.folders)
        let title = nonemptyTitle(destination.title)
        guard !title.isEmpty,
              uniqueTitle(title, section: destination.section, folders: safeFolders) == title else {
            throw StoreError.invalidWikiLink
        }
        return try createNote(section: destination.section, folders: safeFolders, title: title)
    }

    func updateMarkdown(id: UUID, markdown: String) {
        guard canWrite, let index = notes.firstIndex(where: { $0.id == id }) else { return }
        var next = notes[index]
        guard next.markdown != markdown else { return }
        next.markdown = markdown
        next.updatedAt = .now
        var candidate = notes
        candidate[index] = next
        notes = candidate
        dirtyNoteIDs.insert(id)
        editVersion &+= 1
        dirtyVersions[id] = editVersion
        backlinkTargets.removeValue(forKey: id)
        scheduleAutosave()
    }

    /// Drains background writes and durably saves the latest editor state before returning.
    func flushPendingWrites() {
        do { try flushWrites() }
        catch { errorMessage = L10n.text("error.save") }
    }

    private func scheduleAutosave() {
        let now = ContinuousClock.now
        let started = pendingSaveStartedAt ?? now
        pendingSaveStartedAt = started
        let deadline = min(now.advanced(by: .milliseconds(220)), started.advanced(by: .seconds(1)))
        autosaveTask?.cancel()
        autosaveTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(until: deadline, clock: .continuous) }
            catch { return }
            self?.enqueueAutosave()
        }
    }

    private func enqueueAutosave() {
        autosaveTask = nil
        pendingSaveStartedAt = nil
        guard canWrite, !dirtyNoteIDs.isEmpty else { return }
        let snapshot = pendingWrite()
        writeQueue.async { [weak self] in
            let result = Result { try snapshot.write() }
            Task { @MainActor [weak self] in self?.completeWrite(snapshot, result: result) }
        }
    }

    private func flushWrites() throws {
        autosaveTask?.cancel()
        autosaveTask = nil
        pendingSaveStartedAt = nil
        guard canWrite else { return }
        guard !dirtyNoteIDs.isEmpty else {
            writeQueue.sync {}
            return
        }
        let snapshot = pendingWrite()
        // The serial queue is also a barrier for rename/move/trash and manifest updates.
        let result = writeQueue.sync { Result { try snapshot.write() } }
        completeWrite(snapshot, result: result)
        try result.get()
    }

    private func pendingWrite() -> StoreWriteSnapshot {
        saveSequence &+= 1
        return StoreWriteSnapshot(
            sequence: saveSequence,
            versions: dirtyVersions,
            rootURL: rootURL,
            files: notes.filter { dirtyNoteIDs.contains($0.id) }.map {
                StoreWriteSnapshot.MarkdownFile(url: relativeURL(for: $0), markdown: $0.markdown)
            },
            manifest: manifest()
        )
    }

    private func completeWrite(_ snapshot: StoreWriteSnapshot, result: Result<Void, Error>) {
        guard snapshot.sequence > appliedSaveSequence else { return }
        appliedSaveSequence = snapshot.sequence
        switch result {
        case .success:
            for (id, version) in snapshot.versions where dirtyVersions[id] == version {
                dirtyVersions.removeValue(forKey: id)
                dirtyNoteIDs.remove(id)
            }
            errorMessage = nil
        case .failure:
            errorMessage = L10n.text("error.save")
        }
    }

    private func invalidateLinkCatalog() {
        linkCatalogRevision &+= 1
        backlinkTargets.removeAll(keepingCapacity: true)
    }

    func renameNote(id: UUID, title: String) throws {
        try ensureWritable()
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        let old = notes[index]
        let wanted = nonemptyTitle(title)
        guard !wanted.isEmpty else { throw StoreError.emptyTitle }
        var updated = old
        updated.title = uniqueTitle(wanted, section: old.section, folders: old.folders, excluding: old.id)
        updated.updatedAt = .now
        try relocate([updated], replacing: [old])
    }

    func moveNote(id: UUID, section: NoteSection, folders targetFolders: [String]) throws {
        try ensureWritable()
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        let old = notes[index]
        let safeFolders = try PathSafety.normalizeFolderPath(targetFolders)
        let previousFolders = folders
        ensureFolders(section: section, path: safeFolders)
        var updated = old
        updated.section = section
        updated.folders = safeFolders
        updated.title = uniqueTitle(old.title, section: section, folders: safeFolders, excluding: old.id)
        updated.updatedAt = .now
        do { try relocate([updated], replacing: [old]) }
        catch { folders = previousFolders; throw error }
    }

    func trashNote(id: UUID) throws {
        try ensureWritable()
        guard let note = notes.first(where: { $0.id == id }) else { return }
        try writeTrashMarkdown(note)
        let entry = TrashEntry(
            id: note.id, title: note.title, section: note.section, folders: note.folders,
            createdAt: note.createdAt, updatedAt: note.updatedAt, deletedAt: .now
        )
        var nextTrash = trash
        nextTrash.insert(entry, at: 0)
        let previousLastOpened = lastOpenedNoteID
        if lastOpenedNoteID == id { lastOpenedNoteID = notes.first(where: { $0.id != id })?.id }
        do { try saveManifest(notes: notes.filter { $0.id != id }, trash: nextTrash) }
        catch {
            lastOpenedNoteID = previousLastOpened
            try? removeTrashMarkdown(id: note.id)
            throw error
        }
        try? removeMarkdown(for: note)
        notes.removeAll { $0.id == id }
        invalidateLinkCatalog()
        trash = nextTrash
        errorMessage = nil
    }

    func restoreTrashItem(id: UUID) throws {
        try ensureWritable()
        guard let entry = trash.first(where: { $0.id == id }) else { return }
        let source = Note(id: entry.id, title: entry.title, section: entry.section, folders: entry.folders,
                          markdown: try readTrashMarkdown(for: entry))
        let safeFolders = try PathSafety.normalizeFolderPath(source.folders)
        let previousFolders = folders
        ensureFolders(section: source.section, path: safeFolders)
        var restored = source
        restored.folders = safeFolders
        restored.title = uniqueTitle(source.title, section: source.section, folders: safeFolders)
        let previousTrash = trash
        trash.removeAll { $0.id == id }
        do { try relocate([restored], replacing: []) }
        catch { trash = previousTrash; folders = previousFolders; throw error }
        try? removeTrashMarkdown(id: id)
    }

    func createFolder(section: NoteSection, parentPath: [String], name: String) throws -> Folder {
        try ensureWritable()
        let safeParent = try PathSafety.normalizeFolderPath(parentPath)
        let safeName = try PathSafety.folderComponent(name)
        var candidate = safeName
        var number = 2
        while folderExists(section: section, path: safeParent + [candidate]) {
            candidate = "\(safeName)-\(number)"
            number += 1
        }
        let folder = Folder(section: section, path: safeParent + [candidate])
        folders.append(folder)
        let directory = rootURL.appending(path: ([section.rawValue] + folder.path).joined(separator: "/"))
        let directoryAlreadyExisted = FileManager.default.fileExists(atPath: directory.path)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try saveManifest()
        } catch {
            folders.removeAll { $0 == folder }
            if !directoryAlreadyExisted { try? FileManager.default.removeItem(at: directory) }
            throw error
        }
        errorMessage = nil
        return folder
    }

    func renameFolder(_ folder: Folder, name: String) throws {
        try ensureWritable()
        guard folder.path.last != nil else { return }
        let safeName = try PathSafety.folderComponent(name)
        let parent = Array(folder.path.dropLast())
        let target = parent + [safeName]
        if Self.sameFolderPath(target, folder.path) { return }
        if folderExists(section: folder.section, path: target) { throw StoreError.folderAlreadyExists }
        try moveFolderContents(section: folder.section, source: folder.path, target: target)
    }

    func moveFolder(_ folder: Folder, into parentPath: [String]) throws {
        try ensureWritable()
        let targetParent = try PathSafety.normalizeFolderPath(parentPath)
        guard !targetParent.starts(with: folder.path) else { throw PathSafetyError.invalidComponent }
        let target = targetParent + [folder.name]
        if Self.sameFolderPath(target, folder.path) { return }
        if folderExists(section: folder.section, path: target) { throw StoreError.folderAlreadyExists }
        try moveFolderContents(section: folder.section, source: folder.path, target: target)
    }

    func trashFolder(_ folder: Folder) throws {
        try ensureWritable()
        let descendants = notes.filter { $0.section == folder.section && $0.folders.starts(with: folder.path) }
        var copiedToTrash: [UUID] = []
        do {
            for note in descendants {
                try writeTrashMarkdown(note)
                copiedToTrash.append(note.id)
            }
        } catch {
            for id in copiedToTrash { try? removeTrashMarkdown(id: id) }
            throw error
        }
        var nextTrash = trash
        let deletedAt = Date.now
        nextTrash.insert(contentsOf: descendants.map {
            TrashEntry(id: $0.id, title: $0.title, section: $0.section, folders: $0.folders,
                       createdAt: $0.createdAt, updatedAt: $0.updatedAt, deletedAt: deletedAt)
        }, at: 0)
        let nextNotes = notes.filter { !($0.section == folder.section && $0.folders.starts(with: folder.path)) }
        let nextFolders = folders.filter { !($0.section == folder.section && $0.path.starts(with: folder.path)) }
        let previousLastOpened = lastOpenedNoteID
        if let lastOpenedNoteID, descendants.contains(where: { $0.id == lastOpenedNoteID }) {
            self.lastOpenedNoteID = nextNotes.first?.id
        }
        do { try saveManifest(notes: nextNotes, folders: nextFolders, trash: nextTrash) }
        catch {
            lastOpenedNoteID = previousLastOpened
            for id in copiedToTrash { try? removeTrashMarkdown(id: id) }
            throw error
        }
        for note in descendants { try? removeMarkdown(for: note) }
        notes = nextNotes
        invalidateLinkCatalog()
        folders = nextFolders
        trash = nextTrash
        errorMessage = nil
    }

    func createWikiPages(_ pages: [GeneratedWikiPage]) throws -> [Note] {
        try ensureWritable()
        guard !pages.isEmpty else { throw StoreError.invalidGeneratedPages }
        let previousFolders = folders
        var created: [Note] = []
        var tentativeNotes = notes
        for page in pages {
            guard !page.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw StoreError.invalidGeneratedPages
            }
            guard !page.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw StoreError.invalidGeneratedPages
            }
            let safeFolders = try PathSafety.normalizeFolderPath(page.folders)
            let title = nonemptyTitle(page.title)
            let unique = uniqueTitle(title, section: .wiki, folders: safeFolders, existingNotes: tentativeNotes)
            let note = Note(title: unique, section: .wiki, folders: safeFolders, markdown: page.markdown)
            tentativeNotes.append(note)
            created.append(note)
        }
        guard Set(created.map { PathSafety.safeRelativeMarkdownPath(section: $0.section, folders: $0.folders, title: $0.title) }).count == created.count else {
            throw StoreError.invalidGeneratedPages
        }
        var written: [Note] = []
        do {
            for note in created {
                try writeMarkdown(note.markdown, for: note)
                written.append(note)
            }
            for note in created { ensureFolders(section: note.section, path: note.folders) }
            try saveManifest(notes: tentativeNotes)
        } catch {
            for note in written { try? removeMarkdown(for: note) }
            folders = previousFolders
            throw error
        }
        notes = tentativeNotes
        invalidateLinkCatalog()
        errorMessage = nil
        return created
    }

    func setLastOpenedNote(_ id: UUID?) {
        guard canWrite, lastOpenedNoteID != id else { return }
        let previous = lastOpenedNoteID
        do {
            try flushWrites()
            lastOpenedNoteID = id
            try saveManifest()
        } catch { lastOpenedNoteID = previous; errorMessage = L10n.text("error.save") }
    }

    func toggleEmbeddedTask(_ task: EmbeddedTask) {
        guard let note = notes.first(where: { $0.id == task.noteID }) else { return }
        var lines = note.markdown.components(separatedBy: "\n")
        guard lines.indices.contains(task.lineIndex), lines[task.lineIndex] == task.line,
              let match = Self.checkboxRegex.firstMatch(in: task.line, range: NSRange(task.line.startIndex..., in: task.line)),
              let stateRange = Range(match.range(at: 1), in: task.line) else { return }
        var updatedLine = task.line
        let mark = task.isDone ? " " : "x"
        updatedLine.replaceSubrange(stateRange, with: mark)
        lines[task.lineIndex] = updatedLine
        updateMarkdown(id: task.noteID, markdown: lines.joined(separator: "\n"))
        flushPendingWrites()
    }

    func completeAllEmbeddedTasks() -> [EmbeddedTask] { embeddedTasks }

    func updateSettings(_ settings: AISettings) throws {
        try ensureWritable()
        let old = self.settings
        self.settings = settings
        do { try saveManifest() } catch { self.settings = old; throw error }
    }

    @discardableResult
    func createTask(title: String) throws -> TaskItem {
        try ensureWritable()
        let value = nonemptyTitle(title)
        guard !value.isEmpty else { throw StoreError.emptyTitle }
        let task = TaskItem(title: value)
        tasks.insert(task, at: 0)
        do { try saveManifest() } catch { tasks.removeAll { $0.id == task.id }; throw error }
        return task
    }

    func updateTask(_ task: TaskItem) throws {
        try ensureWritable()
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        var updated = task
        updated.title = nonemptyTitle(task.title)
        guard !updated.title.isEmpty else { throw StoreError.emptyTitle }
        updated.updatedAt = .now
        let previous = tasks[index]
        tasks[index] = updated
        do { try saveManifest() } catch { tasks[index] = previous; throw error }
    }

    func deleteTask(id: UUID) throws {
        try ensureWritable()
        let old = tasks
        tasks.removeAll { $0.id == id }
        do { try saveManifest() } catch { tasks = old; throw error }
    }

    func addImage(data: Data, filename: String, mimeType: String) throws -> String {
        try ensureWritable()
        guard data.count <= 20 * 1_024 * 1_024 else { throw StoreError.imageTooLarge }
        let ext: String
        switch mimeType.lowercased() {
        case "image/png": ext = "png"
        case "image/jpeg", "image/jpg": ext = "jpg"
        case "image/gif": ext = "gif"
        case "image/webp": ext = "webp"
        default:
            switch URL(fileURLWithPath: filename).pathExtension.lowercased() {
            case "png", "jpg", "jpeg", "gif", "webp": ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
            default: throw StoreError.unsupportedImage
            }
        }
        try FileManager.default.createDirectory(at: attachmentDirectory, withIntermediateDirectories: true)
        let safeName = "\(UUID().uuidString.lowercased()).\(ext)"
        try data.write(to: attachmentDirectory.appendingPathComponent(safeName), options: .atomic)
        errorMessage = nil
        return safeName
    }

    func attachment(named filename: String) -> (Data, String)? {
        guard filename == URL(fileURLWithPath: filename).lastPathComponent,
              !filename.contains(".."),
              let ext = filename.split(separator: ".").last?.lowercased(),
              ["png", "jpg", "jpeg", "gif", "webp"].contains(String(ext)),
              let data = try? Data(contentsOf: attachmentDirectory.appendingPathComponent(filename)) else { return nil }
        let mime = switch ext {
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        default: "image/webp"
        }
        return (data, mime)
    }

    func report(_ error: Error) {
        if error is PathSafetyError || error is StoreError {
            errorMessage = L10n.message(for: error)
        } else {
            errorMessage = L10n.text("error.operationFailed")
        }
    }

    func clearError() { errorMessage = nil }

    private func load(seedIfEmpty: Bool) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let manifestURL = rootURL.appendingPathComponent("manifest.json")
        if fm.fileExists(atPath: manifestURL.path) {
            let data = try Data(contentsOf: manifestURL)
            let loaded = try JSONDecoder().decode(StoreManifest.self, from: data)
            guard loaded.formatVersion == 1 else { throw StoreError.unsupportedWorkspaceVersion }
            var loadedNotes: [Note] = []
            for entry in loaded.notes {
                let safeFolders = try PathSafety.normalizeFolderPath(entry.folders)
                let note = Note(id: entry.id, title: entry.title, section: entry.section, folders: safeFolders,
                                markdown: try readMarkdown(for: entry), createdAt: entry.createdAt, updatedAt: entry.updatedAt)
                loadedNotes.append(note)
            }
            notes = loadedNotes
            folders = try loaded.folders.map { Folder(section: $0.section, path: try PathSafety.normalizeFolderPath($0.path)) }
            tasks = loaded.tasks
            trash = loaded.trash
            settings = loaded.settings
            lastOpenedNoteID = loaded.lastOpenedNoteID
        } else if hasExistingMarkdownFiles() {
            throw StoreError.missingManifest
        } else if seedIfEmpty {
            let seed = Self.seedContent()
            notes = seed.notes
            tasks = seed.tasks
            folders = seed.folders
            settings = .empty
            lastOpenedNoteID = notes.first?.id
            for note in notes { try writeMarkdown(note.markdown, for: note) }
            try saveManifest()
        }
    }

    private static let checkboxRegex = try! NSRegularExpression(pattern: "^\\s*[-*+]\\s+\\[([ xX])\\]\\s+(.+?)\\s*$")

    private static func taskLines(in markdown: String) -> [(Int, String)] {
        var fence: (character: Character, length: Int)?
        return markdown.components(separatedBy: "\n").enumerated().compactMap { index, line in
            let leadingSpaces = line.prefix { $0 == " " }.count
            let candidate = leadingSpaces <= 3 ? String(line.dropFirst(leadingSpaces)) : ""
            let marker = candidate.first
            let markerCount = marker.map { character in candidate.prefix { $0 == character }.count } ?? 0

            if let currentFence = fence {
                if leadingSpaces <= 3, marker == currentFence.character, markerCount >= currentFence.length,
                   candidate.dropFirst(markerCount).allSatisfy(\.isWhitespace) {
                    fence = nil
                }
                return nil
            }

            if leadingSpaces <= 3, let marker, (marker == "`" || marker == "~"), markerCount >= 3 {
                let info = candidate.dropFirst(markerCount)
                if marker != "`" || !info.contains("`") { fence = (marker, markerCount) }
                return nil
            }
            return (index, line)
        }
    }

    private static func sameFolderPath(_ lhs: [String], _ rhs: [String]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { left, right in
            left.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")) ==
                right.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        }
    }

    private static func seedContent() -> (notes: [Note], tasks: [TaskItem], folders: [Folder]) {
        let welcome = Note(title: L10n.text("seed.welcome.title"), markdown: L10n.text("seed.welcome.body"))
        let process = Note(title: L10n.text("seed.process.title"), markdown: L10n.text("seed.process.body"))
        let jira = Note(title: L10n.text("seed.jira.title"), section: .wiki, markdown: L10n.text("seed.jira.body"))
        let task1 = TaskItem(title: L10n.text("seed.task1.title"), detail: L10n.text("seed.task1.detail"))
        let task2 = TaskItem(title: L10n.text("seed.task2.title"), detail: L10n.text("seed.task2.detail"), priority: .high)
        return ([welcome, process, jira], [task1, task2], [])
    }

    private func saveManifest(
        notes noteOverride: [Note]? = nil,
        folders folderOverride: [Folder]? = nil,
        trash trashOverride: [TrashEntry]? = nil
    ) throws {
        try ensureWritableUnlessLoading()
        let manifest = manifest(notes: noteOverride, folders: folderOverride, trash: trashOverride)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try data.write(to: rootURL.appendingPathComponent("manifest.json"), options: .atomic)
    }

    private func manifest(notes noteOverride: [Note]? = nil, folders folderOverride: [Folder]? = nil,
                          trash trashOverride: [TrashEntry]? = nil) -> StoreManifest {
        StoreManifest(
            formatVersion: 1,
            notes: (noteOverride ?? notes).map(NoteIndexEntry.init(note:)),
            folders: folderOverride ?? folders,
            tasks: tasks,
            trash: trashOverride ?? trash,
            settings: settings,
            lastOpenedNoteID: lastOpenedNoteID
        )
    }

    private func ensureWritable() throws {
        guard canWrite else { throw StoreError.workspaceReadOnly }
        try flushWrites()
    }

    private func hasExistingMarkdownFiles() -> Bool {
        for directoryName in [NoteSection.notes.rawValue, NoteSection.wiki.rawValue] {
            let directory = rootURL.appendingPathComponent(directoryName, isDirectory: true)
            guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
            for case let url as URL in enumerator where url.pathExtension.lowercased() == "md" { return true }
        }
        return false
    }

    private func ensureWritableUnlessLoading() throws {
        if loadError != nil { throw StoreError.workspaceReadOnly }
    }

    private func nonemptyTitle(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func uniqueTitle(
        _ title: String,
        section: NoteSection,
        folders: [String],
        excluding id: UUID? = nil,
        existingNotes: [Note]? = nil
    ) -> String {
        let items = existingNotes ?? notes
        var candidate = title
        var count = 2
        func isTaken(_ value: String) -> Bool {
            let candidatePath = PathSafety.safeRelativeMarkdownPath(section: section, folders: folders, title: value)
            let indexedCollision = items.contains {
                $0.id != id && PathSafety.safeRelativeMarkdownPath(section: $0.section, folders: $0.folders, title: $0.title) == candidatePath
            }
            let isExcludedPath = items.first(where: { $0.id == id }).map {
                PathSafety.safeRelativeMarkdownPath(section: $0.section, folders: $0.folders, title: $0.title) == candidatePath
            } ?? false
            let orphanOrTrashFile = FileManager.default.fileExists(atPath: rootURL.appending(path: candidatePath).path) && !isExcludedPath
            return indexedCollision || orphanOrTrashFile
        }
        while isTaken(candidate) {
            candidate = "\(title) (\(count))"
            count += 1
        }
        return candidate
    }

    private func ensureFolders(section: NoteSection, path: [String]) {
        for length in 1...max(1, path.count) where length <= path.count {
            let folder = Folder(section: section, path: Array(path.prefix(length)))
            if !folders.contains(folder) {
                folders.append(folder)
                let directory = rootURL.appending(path: ([section.rawValue] + folder.path).joined(separator: "/"))
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
        }
    }

    private func relativeURL(for note: Note) -> URL {
        rootURL.appending(path: PathSafety.safeRelativeMarkdownPath(section: note.section, folders: note.folders, title: note.title))
    }

    private func writeMarkdown(_ markdown: String, for note: Note) throws {
        let url = relativeURL(for: note)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(markdown.utf8).write(to: url, options: .atomic)
    }

    private func removeMarkdown(for note: Note) throws {
        let url = relativeURL(for: note)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    private func readMarkdown(for entry: NoteIndexEntry) throws -> String {
        let url = rootURL.appending(path: PathSafety.safeRelativeMarkdownPath(section: entry.section, folders: entry.folders, title: entry.title))
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func readTrashMarkdown(for entry: TrashEntry) throws -> String {
        let url = trashDirectory.appendingPathComponent("\(entry.id.uuidString.lowercased()).md")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private var trashDirectory: URL { rootURL.appendingPathComponent("trash", isDirectory: true) }

    private func writeTrashMarkdown(_ note: Note) throws {
        try FileManager.default.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
        let url = trashDirectory.appendingPathComponent("\(note.id.uuidString.lowercased()).md")
        try Data(note.markdown.utf8).write(to: url, options: .atomic)
    }

    private func removeTrashMarkdown(id: UUID) throws {
        let url = trashDirectory.appendingPathComponent("\(id.uuidString.lowercased()).md")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    private func relocate(_ updatedNotes: [Note], replacing oldNotes: [Note], folders folderOverride: [Folder]? = nil) throws {
        var nextNotes = notes
        for updated in updatedNotes {
            if let index = nextNotes.firstIndex(where: { $0.id == updated.id }) { nextNotes[index] = updated }
            else { nextNotes.append(updated) }
        }

        // A short link can resolve differently after either its source or its target
        // moves. Resolve it against both snapshots and make only changed links stable.
        // The alias remains byte-for-byte intact because only the target range changes.
        for oldSource in notes {
            guard let sourceIndex = nextNotes.firstIndex(where: { $0.id == oldSource.id }) else { continue }
            let futureSource = nextNotes[sourceIndex]
            var replacements: [(NSRange, String)] = []
            for link in NoteLinks.links(in: oldSource.markdown) {
                guard case let .resolved(oldTarget) = NoteLinks.resolution(target: link.target, from: oldSource, notes: notes),
                      let futureTarget = nextNotes.first(where: { $0.id == oldTarget.id }) else { continue }
                if case let .resolved(nextTarget) = NoteLinks.resolution(target: link.target, from: futureSource, notes: nextNotes),
                   nextTarget.id == oldTarget.id {
                    continue
                }
                replacements.append((link.targetRange, NoteLinks.target(for: futureTarget)))
            }
            guard !replacements.isEmpty else { continue }
            var markdown = futureSource.markdown as NSString
            for (range, replacement) in replacements.sorted(by: { $0.0.location > $1.0.location }) {
                markdown = markdown.replacingCharacters(in: range, with: replacement) as NSString
            }
            nextNotes[sourceIndex].markdown = markdown as String
            nextNotes[sourceIndex].updatedAt = .now
        }

        var orderedWriteIDs = updatedNotes.map(\.id)
        orderedWriteIDs.append(contentsOf: notes.compactMap { old in
            guard let next = nextNotes.first(where: { $0.id == old.id }), next.markdown != old.markdown else { return nil }
            return old.id
        })
        var writtenIDs: Set<UUID> = []
        let writeNotes = orderedWriteIDs.compactMap { id -> Note? in
            guard writtenIDs.insert(id).inserted else { return nil }
            return nextNotes.first(where: { $0.id == id })
        }

        // Keep the exact bytes at every destination path so a failed write or manifest
        // save can restore all sources, including a source file whose path did not move.
        var fileSnapshots: [(url: URL, existed: Bool, data: Data?)] = []
        for note in writeNotes {
            let url = relativeURL(for: note)
            let existed = FileManager.default.fileExists(atPath: url.path)
            let data = existed ? try Data(contentsOf: url) : nil
            fileSnapshots.append((url, existed, data))
        }
        do {
            for updated in writeNotes {
                try writeMarkdown(updated.markdown, for: updated)
            }
            try saveManifest(notes: nextNotes, folders: folderOverride)
        } catch {
            for snapshot in fileSnapshots.reversed() {
                if snapshot.existed, let data = snapshot.data {
                    try? FileManager.default.createDirectory(at: snapshot.url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? data.write(to: snapshot.url, options: .atomic)
                } else if FileManager.default.fileExists(atPath: snapshot.url.path) {
                    try? FileManager.default.removeItem(at: snapshot.url)
                }
            }
            throw error
        }
        notes = nextNotes
        invalidateLinkCatalog()
        if let folderOverride { folders = folderOverride }
        dirtyNoteIDs.subtract(writtenIDs)
        for old in oldNotes where !updatedNotes.contains(where: { relativeURL(for: $0) == relativeURL(for: old) }) {
            try? removeMarkdown(for: old)
        }
        errorMessage = nil
    }

    private func moveFolderContents(section: NoteSection, source: [String], target: [String]) throws {
        guard !target.isEmpty, !target.starts(with: source) || target == source else { throw PathSafetyError.invalidComponent }
        let moving = notes.filter { $0.section == section && $0.folders.starts(with: source) }
        var updated: [Note] = []
        for old in moving {
            var item = old
            item.folders = target + old.folders.dropFirst(source.count)
            item.title = uniqueTitle(old.title, section: section, folders: item.folders, excluding: old.id)
            item.updatedAt = .now
            updated.append(item)
        }
        let movingFolders = folders.filter { $0.section == section && $0.path.starts(with: source) }
        let newFolders = movingFolders.map { folder in
            Folder(section: section, path: target + folder.path.dropFirst(source.count))
        }
        var nextFolders = folders.filter { !($0.section == section && $0.path.starts(with: source)) }
        for folder in newFolders where !nextFolders.contains(folder) { nextFolders.append(folder) }
        for folder in nextFolders {
            let directory = rootURL.appending(path: ([section.rawValue] + folder.path).joined(separator: "/"))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try relocate(updated, replacing: moving, folders: nextFolders)
    }
}

enum StoreError: LocalizedError {
    case workspaceReadOnly
    case unsupportedWorkspaceVersion
    case invalidGeneratedPages
    case emptyTitle
    case imageTooLarge
    case unsupportedImage
    case folderAlreadyExists
    case missingManifest
    case imageInsertFailed
    case invalidWikiLink
    case ambiguousWikiLink

    var errorDescription: String? {
        switch self {
        case .workspaceReadOnly: L10n.text("error.readOnly")
        case .unsupportedWorkspaceVersion: L10n.text("error.workspaceVersion")
        case .invalidGeneratedPages: L10n.text("error.invalidAIResponse")
        case .emptyTitle: L10n.text("error.emptyTitle")
        case .imageTooLarge: L10n.text("error.imageTooLarge")
        case .unsupportedImage: L10n.text("error.unsupportedImage")
        case .folderAlreadyExists: L10n.text("error.folderAlreadyExists")
        case .missingManifest: L10n.text("error.missingManifest")
        case .imageInsertFailed: L10n.text("error.imageInsertFailed")
        case .invalidWikiLink: L10n.text("error.invalidWikiLink")
        case .ambiguousWikiLink: L10n.text("error.ambiguousWikiLink")
        }
    }
}

/// Immutable snapshots keep encoding and atomic filesystem writes off the main actor.
private struct StoreWriteSnapshot: Sendable {
    struct MarkdownFile: Sendable {
        let url: URL
        let markdown: String
    }

    let sequence: UInt64
    let versions: [UUID: UInt64]
    let rootURL: URL
    let files: [MarkdownFile]
    let manifest: StoreManifest

    func write() throws {
        for file in files {
            try FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(file.markdown.utf8).write(to: file.url, options: .atomic)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try data.write(to: rootURL.appendingPathComponent("manifest.json"), options: .atomic)
    }
}
