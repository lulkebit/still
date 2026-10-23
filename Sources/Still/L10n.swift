import Foundation

enum L10n {
    static func text(_ key: String) -> String {
        Bundle.module.localizedString(forKey: key, value: key, table: nil)
    }

    static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return text("error.operationFailed")
    }

    static var editorStrings: [String: String] {
        let keys = [
            "editor.bold", "editor.italic", "editor.strikethrough", "editor.heading1",
            "editor.heading2", "editor.quote", "editor.code", "editor.link",
            "editor.wikiAction", "editor.optimizeAction", "editor.emptyTitle", "editor.emptyBody",
            "editor.selectTextHint", "editor.imageAlt", "editor.editSource", "editor.importImage",
            "editor.selectionToolbar", "editor.busy", "editor.openLink", "editor.table",
            "editor.linkOpenNote", "editor.linkOpenWiki", "editor.linkCreateMissing",
            "editor.linkAmbiguous", "editor.linkExternal", "editor.linkSectionNotes",
            "editor.linkSectionWiki"
        ]
        return Dictionary(uniqueKeysWithValues: keys.map { ($0, text($0)) })
    }
}
