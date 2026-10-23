import Foundation

struct WikiLink: Equatable {
    /// The UTF-16 range of the complete `[[...]]` token.
    let range: NSRange
    /// The UTF-16 range of the target text, excluding an optional alias.
    let targetRange: NSRange
    let target: String
    let label: String
}

enum NoteLinks {
    private static let foldingLocale = Locale(identifier: "en_US_POSIX")
    private static let sectionNames = Set(NoteSection.allCases.map { folded($0.rawValue) })

    /// Finds wiki links in Markdown, excluding fenced and inline code, indented code,
    /// HTML comments, and escaped openers. Ranges use Foundation's UTF-16 offsets.
    static func links(in markdown: String) -> [WikiLink] {
        let source = markdown as NSString
        let length = source.length
        guard length >= 4 else { return [] }
        var ignored = codeAndCommentMask(in: source)
        maskInlineCode(in: source, ignored: &ignored)
        maskImageAltText(in: source, ignored: &ignored)

        var result: [WikiLink] = []
        var location = 0
        while location + 1 < length {
            if ignored[location] || ignored[location + 1] || source.character(at: location) != 91 || source.character(at: location + 1) != 91 {
                location += 1
                continue
            }
            // A wiki-looking token inside an image's alt text is display content,
            // not a navigable wiki link.
            if location > 0, source.character(at: location - 1) == 33, location + 2 < length,
               source.character(at: location + 2) == 91 {
                location += 2
                continue
            }
            if isEscaped(at: location, in: source) {
                location += 2
                continue
            }

            let contentStart = location + 2
            var cursor = contentStart
            var separator: Int?
            var close: Int?
            var nestedOpener: Int?
            while cursor + 1 < length {
                if ignored[cursor] {
                    cursor += 1
                    continue
                }
                let current = source.character(at: cursor)
                let next = source.character(at: cursor + 1)
                if current == 91, next == 91 {
                    nestedOpener = cursor
                    break
                }
                if current == 93, next == 93 {
                    close = cursor
                    break
                }
                if current == 124, separator == nil { separator = cursor }
                cursor += 1
            }

            guard let close, nestedOpener == nil else {
                location = (nestedOpener ?? (close.map { $0 + 2 } ?? length))
                continue
            }
            let contentRange = NSRange(location: contentStart, length: close - contentStart)
            let content = source.substring(with: contentRange)
            guard !content.contains("\n"), !content.contains("\r") else {
                location = close + 2
                continue
            }
            let targetEnd = separator ?? close
            let rawTargetRange = NSRange(location: contentStart, length: targetEnd - contentStart)
            let rawTarget = source.substring(with: rawTargetRange)
            let target = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !target.isEmpty, !target.contains("\n"), !target.contains("\r") else {
                location = close + 2
                continue
            }
            let targetTrimOffset = (rawTarget as NSString).range(of: target).location
            let targetRange = NSRange(location: rawTargetRange.location + targetTrimOffset, length: (target as NSString).length)

            let rawLabel: String
            if let separator {
                rawLabel = source.substring(with: NSRange(location: separator + 1, length: close - separator - 1))
            } else {
                rawLabel = target
            }
            let label = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(WikiLink(range: NSRange(location: location, length: close + 2 - location),
                                   targetRange: targetRange, target: target, label: label.isEmpty ? target : label))
            location = close + 2
        }
        return result
    }

    /// Returns the stable full target for a note: section, folders, and title.
    /// Each component percent-encodes `/`, `|`, `[`, `]`, and `%` as UTF-8 bytes.
    static func target(for note: Note) -> String {
        ([note.section.rawValue] + note.folders + [note.title]).map(encodeComponent).joined(separator: "/")
    }

    static func encodeComponent(_ component: String) -> String {
        var result = ""
        for scalar in component.unicodeScalars {
            switch scalar.value {
            case 0x25, 0x2F, 0x5B, 0x5D, 0x7C:
                for byte in String(scalar).utf8 {
                    result += String(format: "%%%02X", byte)
                }
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    /// Decodes percent-escaped UTF-8 exactly once. Invalid or incomplete escapes return nil.
    static func decodeComponent(_ component: String) -> String? {
        let input = Array(component.utf8)
        var output: [UInt8] = []
        var index = 0
        while index < input.count {
            guard input[index] == 0x25 else {
                output.append(input[index])
                index += 1
                continue
            }
            guard index + 2 < input.count,
                  let high = hexValue(input[index + 1]), let low = hexValue(input[index + 2]) else { return nil }
            output.append(high << 4 | low)
            index += 3
        }
        return String(bytes: output, encoding: .utf8)
    }

    /// Resolves a short title by exact title match, preferring the source's folder,
    /// then its section only when that choice is unique. Qualified targets match
    /// their complete canonical path. Ambiguous and missing targets both return nil.
    static func resolve(target: String, from source: Note, notes: [Note]) -> Note? {
        guard case let .resolved(note) = resolution(target: target, from: source, notes: notes) else { return nil }
        return note
    }

    enum Resolution {
        case resolved(Note)
        case missing
        case ambiguous
        case invalid
    }

    struct Destination {
        let section: NoteSection
        let folders: [String]
        let title: String
    }

    static func resolution(target: String, from source: Note, notes: [Note]) -> Resolution {
        guard let parsed = parseTarget(target) else { return .invalid }
        switch parsed {
        case let .qualified(section, components):
            let matches = notes.filter { note in
                note.section == section && canonicalComponents(for: note).map(folded).elementsEqual(components.map(folded))
            }
            return unique(matches)
        case let .short(title):
            let titleMatches = notes.filter { folded($0.title) == folded(title) }
            if titleMatches.count == 1 { return .resolved(titleMatches[0]) }
            if titleMatches.count > 1 {
                let sameFolder = titleMatches.filter { $0.section == source.section && sameFolder($0.folders, source.folders) }
                if sameFolder.count == 1 { return .resolved(sameFolder[0]) }
                if sameFolder.count > 1 { return .ambiguous }
                let sameSection = titleMatches.filter { $0.section == source.section }
                return sameSection.count == 1 ? .resolved(sameSection[0]) : .ambiguous
            }
            return .missing
        }
    }

    static func destination(for target: String, from source: Note) -> Destination? {
        guard let parsed = parseTarget(target) else { return nil }
        switch parsed {
        case let .qualified(section, components):
            guard let title = components.last, !title.isEmpty else { return nil }
            let folders = Array(components.dropLast())
            guard folders.allSatisfy(isSafeFolderComponent) else { return nil }
            return Destination(section: section, folders: folders, title: title)
        case let .short(title):
            return Destination(section: source.section, folders: source.folders, title: title)
        }
    }

    private enum ParsedTarget {
        case qualified(NoteSection, [String])
        case short(String)
    }

    private static func parseTarget(_ target: String) -> ParsedTarget? {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !trimmed.contains("\\") else { return nil }
        let rawComponents = trimmed.components(separatedBy: "/")
        guard rawComponents.allSatisfy({ !$0.isEmpty }) else { return nil }

        if rawComponents.count >= 2,
           let sectionValue = decodeComponent(rawComponents[0]),
           let section = NoteSection(rawValue: folded(sectionValue)), sectionNames.contains(folded(sectionValue)) {
            guard rawComponents.count >= 2,
                  let components = decodeComponents(Array(rawComponents.dropFirst())),
                  let title = components.last, !title.isEmpty,
                  !components.contains(where: isTraversalComponent),
                  isSafeTitle(title),
                  components.dropLast().allSatisfy(isSafeFolderComponent) else { return nil }
            return .qualified(section, components)
        }

        guard rawComponents.count == 1,
              let title = decodeComponent(rawComponents[0]), isSafeTitle(title) else { return nil }
        return .short(title)
    }

    private static func decodeComponents(_ components: [String]) -> [String]? {
        let decoded = components.compactMap(decodeComponent)
        return decoded.count == components.count ? decoded : nil
    }

    private static func isSafeFolderComponent(_ value: String) -> Bool {
        guard !isTraversalComponent(value), !value.contains("/") else { return false }
        guard let normalized = try? PathSafety.folderComponent(value) else { return false }
        return normalized == value
    }

    private static func isSafeTitle(_ value: String) -> Bool {
        guard !value.isEmpty, value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !value.contains("\\") else { return false }
        return !value.split(separator: "/", omittingEmptySubsequences: false).contains(where: { isTraversalComponent(String($0)) })
    }

    private static func isTraversalComponent(_ value: String) -> Bool { value == "." || value == ".." }

    private static func canonicalComponents(for note: Note) -> [String] { note.folders + [note.title] }

    private static func unique(_ notes: [Note]) -> Resolution {
        switch notes.count {
        case 0: .missing
        case 1: .resolved(notes[0])
        default: .ambiguous
        }
    }

    private static func sameFolder(_ lhs: [String], _ rhs: [String]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { pair in folded(pair.0) == folded(pair.1) }
    }

    private static func folded(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: foldingLocale)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: byte - 48
        case 65...70: byte - 55
        case 97...102: byte - 87
        default: nil
        }
    }

    private static func isEscaped(at location: Int, in source: NSString) -> Bool {
        var cursor = location - 1
        var count = 0
        while cursor >= 0, source.character(at: cursor) == 92 {
            count += 1
            cursor -= 1
        }
        return count.isMultiple(of: 2) == false
    }

    private static func codeAndCommentMask(in source: NSString) -> [Bool] {
        let length = source.length
        var ignored = Array(repeating: false, count: length)
        var fence: (character: unichar, length: Int)?
        var offset = 0
        while offset < length {
            let lineRange = source.lineRange(for: NSRange(location: offset, length: 0))
            let contentEnd: Int = {
                var end = NSMaxRange(lineRange)
                while end > offset, source.character(at: end - 1) == 10 || source.character(at: end - 1) == 13 { end -= 1 }
                return end
            }()
            var markerStart = offset
            var indentation = 0
            while markerStart < contentEnd {
                switch source.character(at: markerStart) {
                case 32:
                    indentation += 1
                    markerStart += 1
                case 9:
                    indentation = ((indentation / 4) + 1) * 4
                    markerStart += 1
                default:
                    break
                }
                if markerStart < contentEnd, source.character(at: markerStart) != 32, source.character(at: markerStart) != 9 { break }
                if markerStart == contentEnd { break }
            }

            if let current = fence {
                mark(NSRange(location: offset, length: NSMaxRange(lineRange) - offset), in: &ignored)
                if indentation <= 3, markerStart < contentEnd, source.character(at: markerStart) == current.character {
                    var runEnd = markerStart
                    while runEnd < contentEnd, source.character(at: runEnd) == current.character { runEnd += 1 }
                    let runLength = runEnd - markerStart
                    let remainderIsWhitespace = (runEnd..<contentEnd).allSatisfy {
                        let value = source.character(at: $0)
                        return value == 32 || value == 9
                    }
                    if runLength >= current.length, remainderIsWhitespace { fence = nil }
                }
            } else if indentation >= 4 {
                mark(NSRange(location: offset, length: NSMaxRange(lineRange) - offset), in: &ignored)
            } else if indentation <= 3, markerStart < contentEnd,
                      (source.character(at: markerStart) == 96 || source.character(at: markerStart) == 126) {
                let character = source.character(at: markerStart)
                var runEnd = markerStart
                while runEnd < contentEnd, source.character(at: runEnd) == character { runEnd += 1 }
                let runLength = runEnd - markerStart
                let infoContainsBacktick = character == 96 && (runEnd..<contentEnd).contains { source.character(at: $0) == 96 }
                if runLength >= 3, !infoContainsBacktick {
                    fence = (character, runLength)
                    mark(NSRange(location: offset, length: NSMaxRange(lineRange) - offset), in: &ignored)
                }
            }
            offset = NSMaxRange(lineRange)
        }

        let opener = "<!--" as NSString
        let closer = "-->" as NSString
        var cursor = 0
        while cursor + opener.length <= length {
            if ignored[cursor] || source.character(at: cursor) != 60 {
                cursor += 1
                continue
            }
            let openRange = source.range(of: opener as String, options: [], range: NSRange(location: cursor, length: length - cursor))
            guard openRange.location != NSNotFound else { break }
            if ignored[openRange.location] {
                cursor = NSMaxRange(openRange)
                continue
            }
            let searchStart = NSMaxRange(openRange)
            let closeRange = source.range(of: closer as String, options: [], range: NSRange(location: searchStart, length: length - searchStart))
            let end = closeRange.location == NSNotFound ? length : NSMaxRange(closeRange)
            mark(NSRange(location: openRange.location, length: end - openRange.location), in: &ignored)
            cursor = end
        }
        return ignored
    }

    private static func maskInlineCode(in source: NSString, ignored: inout [Bool]) {
        var index = 0
        while index < source.length {
            if ignored[index] || source.character(at: index) != 96 {
                index += 1
                continue
            }
            var openEnd = index
            while openEnd < source.length, source.character(at: openEnd) == 96 { openEnd += 1 }
            if isEscaped(at: index, in: source) {
                index = openEnd
                continue
            }
            let delimiterLength = openEnd - index
            var cursor = openEnd
            var closeRange: NSRange?
            while cursor < source.length {
                if ignored[cursor] {
                    cursor += 1
                    continue
                }
                guard source.character(at: cursor) == 96 else {
                    cursor += 1
                    continue
                }
                var runEnd = cursor
                while runEnd < source.length, !ignored[runEnd], source.character(at: runEnd) == 96 { runEnd += 1 }
                if runEnd - cursor == delimiterLength {
                    closeRange = NSRange(location: cursor, length: delimiterLength)
                    break
                }
                cursor = runEnd
            }
            if let closeRange {
                mark(NSRange(location: index, length: NSMaxRange(closeRange) - index), in: &ignored)
                index = NSMaxRange(closeRange)
            } else {
                index = openEnd
            }
        }
    }

    private static func mark(_ range: NSRange, in mask: inout [Bool]) {
        guard range.length > 0, range.location >= 0, NSMaxRange(range) <= mask.count else { return }
        for index in range.location..<NSMaxRange(range) { mask[index] = true }
    }

    private static func maskImageAltText(in source: NSString, ignored: inout [Bool]) {
        var index = 0
        while index + 1 < source.length {
            if ignored[index] || source.character(at: index) != 33 || source.character(at: index + 1) != 91 || isEscaped(at: index, in: source) {
                index += 1
                continue
            }
            var depth = 1
            var cursor = index + 2
            var close: Int?
            while cursor < source.length {
                if ignored[cursor] {
                    cursor += 1
                    continue
                }
                let character = source.character(at: cursor)
                if character == 91, !isEscaped(at: cursor, in: source) {
                    depth += 1
                } else if character == 93, !isEscaped(at: cursor, in: source) {
                    depth -= 1
                    if depth == 0 {
                        close = cursor
                        break
                    }
                }
                cursor += 1
            }
            if let close, close + 1 < source.length, source.character(at: close + 1) == 40 {
                mark(NSRange(location: index + 1, length: close - index), in: &ignored)
                index = close + 1
            } else {
                index += 1
            }
        }
    }
}
