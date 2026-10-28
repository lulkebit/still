import Foundation

enum AIContextChoice: String, CaseIterable, Identifiable, Sendable {
    case currentNote
    case currentFolder
    case selectedSources
    case none

    var id: String { rawValue }
    var localizationKey: String { "ai.context.\(rawValue)" }
}

struct AIContextSelection: Equatable, Sendable {
    var choice: AIContextChoice = .currentNote
    var selectedSourceIDs: Set<UUID> = []
}

enum AIContextPolicy {
    static func notes(
        for selection: AIContextSelection,
        anchorNoteID: UUID?,
        visibleNotes: [Note]
    ) -> [Note] {
        switch selection.choice {
        case .none:
            return []
        case .currentNote:
            guard let anchorNoteID,
                  let note = visibleNotes.first(where: { $0.id == anchorNoteID }) else { return [] }
            return [note]
        case .currentFolder:
            guard let anchorNoteID,
                  let anchor = visibleNotes.first(where: { $0.id == anchorNoteID }) else { return [] }
            return visibleNotes.filter { $0.section == anchor.section && $0.folders == anchor.folders }
                .sorted(by: noteOrder)
        case .selectedSources:
            guard !selection.selectedSourceIDs.isEmpty else { return [] }
            return visibleNotes.filter { selection.selectedSourceIDs.contains($0.id) }
                .sorted(by: noteOrder)
        }
    }

    static func makeContext(
        for selection: AIContextSelection,
        anchorNoteID: UUID?,
        visibleNotes: [Note],
        visibleFolders: [Folder],
        limit: Int = 18_000
    ) -> String {
        guard limit > 0 else { return "" }
        let selectedNotes = notes(for: selection, anchorNoteID: anchorNoteID, visibleNotes: visibleNotes)
        guard !selectedNotes.isEmpty else { return "" }

        var context = ""
        let representedFolders = Set(selectedNotes.map { "\($0.section.rawValue)/\($0.folders.joined(separator: "/"))" })
        for folder in visibleFolders.sorted(by: folderOrder) {
            let key = "\(folder.section.rawValue)/\(folder.path.joined(separator: "/"))"
            guard representedFolders.contains(key) else { continue }
            let line = "\n[folder] \(folder.path.joined(separator: " / "))"
            context += String(line.prefix(max(0, limit - context.count)))
            guard context.count < limit else { return context }
        }

        for note in selectedNotes {
            guard context.count < limit else { break }
            let path = note.folders.isEmpty ? "" : " — \(note.folders.joined(separator: " / "))"
            let block = "\n\n[\(note.section.rawValue)] \(note.title)\(path)\n\(note.markdown)"
            context += String(block.prefix(limit - context.count))
        }
        return context
    }

    private static func noteOrder(_ lhs: Note, _ rhs: Note) -> Bool {
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        let titleOrder = lhs.title.localizedStandardCompare(rhs.title)
        if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func folderOrder(_ lhs: Folder, _ rhs: Folder) -> Bool {
        let left = "\(lhs.section.rawValue)/\(lhs.path.joined(separator: "/"))"
        let right = "\(rhs.section.rawValue)/\(rhs.path.joined(separator: "/"))"
        return left.localizedStandardCompare(right) == .orderedAscending
    }
}

enum ChatLocalContextScope: String, CaseIterable, Identifiable, Sendable {
    case allLocal
    case currentNote
    case currentFolder
    case none

    var id: String { rawValue }
    var localizationKey: String { "chat.context.\(rawValue)" }
}

struct ChatRequestContext: Equatable, Sendable {
    var localScope: ChatLocalContextScope
    var anchorNoteID: UUID?
    var includeConfluence: Bool

    static let none = ChatRequestContext(localScope: .none, anchorNoteID: nil, includeConfluence: false)

    var instruction: String {
        let local = switch localScope {
        case .allLocal: "All local notes visible when this request started"
        case .currentNote: "Only the current note selected when this request started"
        case .currentFolder: "Only notes in the current folder selected when this request started"
        case .none: "No local notes"
        }
        let confluence = includeConfluence ? "Confluence tools are enabled for this request if configured." : "Confluence tools are disabled for this request."
        return "Request source scope: \(local). \(confluence) Older conversation messages may already contain source content; changing this setting does not remove that history."
    }
}

enum ChatContextPolicy {
    static func allowedLocalNoteIDs(
        for context: ChatRequestContext,
        visibleNotes: [Note]
    ) -> Set<UUID> {
        switch context.localScope {
        case .none:
            return []
        case .allLocal:
            return Set(visibleNotes.map(\.id))
        case .currentNote:
            guard let anchorNoteID = context.anchorNoteID,
                  visibleNotes.contains(where: { $0.id == anchorNoteID }) else { return [] }
            return [anchorNoteID]
        case .currentFolder:
            guard let anchorNoteID = context.anchorNoteID,
                  let anchor = visibleNotes.first(where: { $0.id == anchorNoteID }) else { return [] }
            return Set(visibleNotes.filter { $0.section == anchor.section && $0.folders == anchor.folders }.map(\.id))
        }
    }

    static func localCatalog(visibleNotes: [Note], allowedIDs: Set<UUID>, limit: Int = 4_000) -> String {
        guard limit > 0, !allowedIDs.isEmpty else { return "" }
        var result = ""
        for note in visibleNotes.filter({ allowedIDs.contains($0.id) }).sorted(by: {
            let titleOrder = $0.title.localizedStandardCompare($1.title)
            if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
            return $0.id.uuidString < $1.id.uuidString
        }) {
            guard result.count < limit else { break }
            let section = note.section == .wiki ? "wiki" : "notes"
            let path = note.folders.isEmpty ? "" : " | \(note.folders.joined(separator: " / "))"
            let line = "\n\(note.id.uuidString) | [\(section)] \(note.title)\(path)"
            guard line.count <= limit - result.count else { break }
            result += line
        }
        return result
    }
}
