import Foundation

enum WorkspaceSection: String, CaseIterable, Identifiable {
    case notes
    case tasks
    case wiki

    var id: String { rawValue }
    var localizationKey: String { "nav.\(rawValue)" }
}

enum NoteSection: String, Codable, CaseIterable, Identifiable {
    case notes
    case wiki

    var id: String { rawValue }
}

struct Note: Identifiable, Equatable {
    var id: UUID
    var title: String
    var section: NoteSection
    var folders: [String]
    var markdown: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        section: NoteSection = .notes,
        folders: [String] = [],
        markdown: String = "",
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.section = section
        self.folders = folders
        self.markdown = markdown
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct Folder: Codable, Hashable, Identifiable {
    var section: NoteSection
    var path: [String]

    var id: String { "\(section.rawValue):\(path.joined(separator: "/"))" }
    var name: String { path.last ?? "" }
}

enum TaskStatus: String, Codable, CaseIterable, Identifiable {
    case open
    case waiting
    case done

    var id: String { rawValue }
    var localizationKey: String { "task.status.\(rawValue)" }
}

enum TaskPriority: String, Codable, CaseIterable, Identifiable {
    case low
    case normal
    case high

    var id: String { rawValue }
    var localizationKey: String { "task.priority.\(rawValue)" }
}

struct TaskItem: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var detail: String
    var dueDate: Date?
    var priority: TaskPriority
    var status: TaskStatus
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        detail: String = "",
        dueDate: Date? = nil,
        priority: TaskPriority = .normal,
        status: TaskStatus = .open,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.dueDate = dueDate
        self.priority = priority
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct EmbeddedTask: Identifiable, Equatable {
    var id: String { "\(noteID.uuidString):\(lineIndex)" }
    var noteID: UUID
    var noteTitle: String
    var lineIndex: Int
    var line: String
    var title: String
    var isDone: Bool
}

struct AISettings: Codable, Equatable {
    var baseURL: String
    var model: String
    var enabled: Bool

    static let empty = AISettings(baseURL: "", model: "", enabled: false)
}

struct NoteIndexEntry: Codable, Equatable {
    var id: UUID
    var title: String
    var section: NoteSection
    var folders: [String]
    var createdAt: Date
    var updatedAt: Date

    init(note: Note) {
        id = note.id
        title = note.title
        section = note.section
        folders = note.folders
        createdAt = note.createdAt
        updatedAt = note.updatedAt
    }
}

struct TrashEntry: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var section: NoteSection
    var folders: [String]
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date
}

struct StoreManifest: Codable {
    var formatVersion: Int
    var notes: [NoteIndexEntry]
    var folders: [Folder]
    var tasks: [TaskItem]
    var trash: [TrashEntry]
    var settings: AISettings
    var lastOpenedNoteID: UUID?

    static let empty = StoreManifest(
        formatVersion: 1,
        notes: [],
        folders: [],
        tasks: [],
        trash: [],
        settings: .empty,
        lastOpenedNoteID: nil
    )
}

enum PathSafety {
    static func slug(_ value: String, fallback: String = "untitled") -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        var result = ""
        var needsDash = false
        for scalar in normalized.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if needsDash, !result.isEmpty, !result.hasSuffix("-") { result.append("-") }
                result.unicodeScalars.append(scalar)
                needsDash = false
            } else {
                needsDash = true
            }
        }
        while result.hasSuffix("-") { result.removeLast() }
        return result.isEmpty ? fallback : result
    }

    static func folderComponent(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != "..",
              !trimmed.contains("/"), !trimmed.contains("\\") else {
            throw PathSafetyError.invalidComponent
        }
        guard !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw PathSafetyError.invalidComponent
        }
        return trimmed
    }

    static func normalizeFolderPath(_ components: [String]) throws -> [String] {
        try components.map(folderComponent)
    }

    static func safeRelativeMarkdownPath(section: NoteSection, folders: [String], title: String) -> String {
        return ([section.rawValue] + folders + [slug(title) + ".md"]).joined(separator: "/")
    }
}

enum PathSafetyError: Error {
    case invalidComponent
}

struct GeneratedWikiPage: Decodable, Equatable {
    var title: String
    var folders: [String]
    var markdown: String
}

struct GeneratedWikiResponse: Decodable, Equatable {
    var pages: [GeneratedWikiPage]
}
