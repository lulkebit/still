import AppKit
import SwiftUI
import WebKit
import Observation

struct WikiLinkRequest: Equatable {
    let id: UUID
    let target: String
    let from: Int
    let to: Int
    let original: String

    var range: NSRange { NSRange(location: from, length: to - from) }
}

struct EditorLinkDocument: Equatable {
    let id: String
    let title: String
    let section: String
    let folders: [String]
    let target: String

    init(note: Note) {
        id = note.id.uuidString
        title = note.title
        section = note.section.rawValue
        folders = note.folders
        target = NoteLinks.target(for: note)
    }

    var payload: [String: Any] {
        ["id": id, "title": title, "section": section, "folders": folders, "target": target]
    }
}

enum EditorLinkRequestPolicy {
    static func wikiLinkRequest(body: [String: Any], currentDocumentID: UUID?, markdown: String) -> WikiLinkRequest? {
        guard body["type"] as? String == "openWikiLink",
              let idText = body["id"] as? String, let id = UUID(uuidString: idText),
              id == currentDocumentID,
              let target = body["target"] as? String,
              let from = body["from"] as? Int, let to = body["to"] as? Int,
              let original = body["original"] as? String else { return nil }
        let request = WikiLinkRequest(id: id, target: target, from: from, to: to, original: original)
        return isCurrent(request, currentDocumentID: currentDocumentID, markdown: markdown) ? request : nil
    }

    static func isCurrent(_ request: WikiLinkRequest, currentDocumentID: UUID?, markdown: String) -> Bool {
        let source = markdown as NSString
        guard request.id == currentDocumentID,
              request.from >= 0, request.to > request.from, request.to <= source.length,
              source.substring(with: request.range) == request.original else { return false }
        return NoteLinks.links(in: markdown).contains {
            $0.range == request.range && $0.target == request.target
        }
    }

    static func externalURL(body: [String: Any], currentDocumentID: UUID?) -> URL? {
        guard body["type"] as? String == "openExternalLink",
              let idText = body["id"] as? String, let id = UUID(uuidString: idText),
              id == currentDocumentID,
              let rawURL = body["url"] as? String,
              !rawURL.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let components = URLComponents(string: rawURL),
              let scheme = components.scheme?.lowercased(), let url = components.url else { return nil }
        switch scheme {
        case "http", "https":
            guard let host = components.host, !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  components.user == nil, components.password == nil else { return nil }
        case "mailto":
            guard components.host == nil,
                  !components.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        default:
            return nil
        }
        return url
    }
}

struct EditorCommand: Identifiable {
    enum Kind {
        case insertMarkdown(String, documentID: UUID)
        case insertImage(url: String, alt: String, documentID: UUID)
    }

    var id = UUID()
    var kind: Kind

    var documentID: UUID {
        switch kind {
        case .insertMarkdown(_, let documentID), .insertImage(_, _, let documentID): documentID
        }
    }

    func isTargeted(at documentID: UUID) -> Bool { self.documentID == documentID }
}

@MainActor
@Observable
final class EditorCommandBus {
    var pending: EditorCommand?
    private(set) var editorFocused = false
    private var undoHandler: (() -> Void)?
    private var redoHandler: (() -> Void)?
    private var commandHandler: ((EditorCommand) -> Bool)?

    func send(_ kind: EditorCommand.Kind) {
        let command = EditorCommand(kind: kind)
        guard commandHandler?(command) != true else { return }
        pending = command
    }

    func consume(_ id: UUID) { if pending?.id == id { pending = nil } }

    func setCommandHandler(_ handler: @escaping (EditorCommand) -> Bool) {
        commandHandler = handler
    }

    func dispatchPending() {
        guard let pending, commandHandler?(pending) == true else { return }
        consume(pending.id)
    }

    func clearCommandHandler() {
        commandHandler = nil
        pending = nil
    }

    func setEditorFocused(_ focused: Bool) { editorFocused = focused }

    func setHistoryHandlers(undo: @escaping () -> Void, redo: @escaping () -> Void) {
        undoHandler = undo
        redoHandler = redo
    }

    func clearHistoryHandlers() {
        editorFocused = false
        undoHandler = nil
        redoHandler = nil
    }

    @discardableResult
    func undoIfEditorFocused() -> Bool {
        guard editorFocused, let undoHandler else { return false }
        undoHandler()
        return true
    }

    @discardableResult
    func redoIfEditorFocused() -> Bool {
        guard editorFocused, let redoHandler else { return false }
        redoHandler()
        return true
    }
}

struct MarkdownEditor: NSViewRepresentable {
    var note: Note?
    var appModel: StillAppModel
    var colorScheme: ColorScheme
    var reduceMotion: Bool
    var onWikiCreated: (Note) -> Void
    var onOpenWikiLink: (WikiLinkRequest) -> Void
    var onOpenExternalLink: (URL) -> Void
    var commands: EditorCommandBus

    func makeCoordinator() -> Coordinator {
        Coordinator(appModel: appModel, onWikiCreated: onWikiCreated,
                    onOpenWikiLink: onOpenWikiLink, onOpenExternalLink: onOpenExternalLink)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(StillAssetSchemeHandler(store: appModel.store), forURLScheme: "still-asset")
        configuration.userContentController.add(context.coordinator, name: "still")
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        webView.allowsBackForwardNavigationGestures = false
        context.coordinator.webView = webView
        context.coordinator.editorHTMLURL = Self.editorHTMLURL
        context.coordinator.editorDirectoryURL = Self.editorDirectoryURL
        if let url = Self.editorHTMLURL, let directory = Self.editorDirectoryURL {
            webView.loadFileURL(url, allowingReadAccessTo: directory)
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onWikiCreated = onWikiCreated
        context.coordinator.onOpenWikiLink = onOpenWikiLink
        context.coordinator.onOpenExternalLink = onOpenExternalLink
        context.coordinator.apply(note: note, colorScheme: colorScheme, reduceMotion: reduceMotion, commands: commands)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.detach()
    }

    static var editorHTMLURL: URL? {
        Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "Editor")
    }

    static var editorDirectoryURL: URL? {
        editorHTMLURL?.deletingLastPathComponent()
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let appModel: StillAppModel
        var onWikiCreated: (Note) -> Void
        var onOpenWikiLink: (WikiLinkRequest) -> Void
        var onOpenExternalLink: (URL) -> Void
        weak var webView: WKWebView?
        weak var commandBus: EditorCommandBus?
        var editorHTMLURL: URL?
        var editorDirectoryURL: URL?
        private var currentDocumentID: UUID?
        private var pushedMarkdown: String?
        private var currentTheme = "light"
        private var currentReduceMotion = false
        private var currentAIAvailable = false
        private var isReady = false
        private var isEditorFocused = false
        private var lastLinkDocumentsSourceID: UUID?
        private var lastLinkDocuments: [EditorLinkDocument]?
        private var lastLinkCatalogRevision: UInt64?
        private var lastAIState: (busy: Bool, label: String?)?

        init(appModel: StillAppModel, onWikiCreated: @escaping (Note) -> Void,
             onOpenWikiLink: @escaping (WikiLinkRequest) -> Void,
             onOpenExternalLink: @escaping (URL) -> Void) {
            self.appModel = appModel
            self.onWikiCreated = onWikiCreated
            self.onOpenWikiLink = onOpenWikiLink
            self.onOpenExternalLink = onOpenExternalLink
        }

        func apply(note: Note?, colorScheme: ColorScheme, reduceMotion: Bool, commands: EditorCommandBus) {
            if commandBus !== commands {
                commandBus?.clearHistoryHandlers()
                commandBus?.clearCommandHandler()
                commands.setHistoryHandlers(
                    undo: { [weak self] in self?.invoke("undo", payload: [:]) },
                    redo: { [weak self] in self?.invoke("redo", payload: [:]) }
                )
                commands.setCommandHandler { [weak self] command in self?.dispatch(command) ?? false }
            }
            commandBus = commands
            guard let note, webView != nil else { return }
            if currentDocumentID != note.id {
                isEditorFocused = false
                commands.setEditorFocused(false)
            }
            let theme = colorScheme == .dark ? "dark" : "light"
            let aiAvailable = appModel.store.settings.enabled
            let documentChanged = currentDocumentID != note.id || pushedMarkdown != note.markdown
            let appearanceChanged = currentTheme != theme || currentReduceMotion != reduceMotion
            let availabilityChanged = currentAIAvailable != aiAvailable
            currentDocumentID = note.id
            if lastLinkCatalogRevision != appModel.store.linkCatalogRevision {
                lastLinkDocuments = appModel.store.notes.map(EditorLinkDocument.init(note:))
                lastLinkCatalogRevision = appModel.store.linkCatalogRevision
                lastLinkDocumentsSourceID = nil
            }
            let linkDocuments = lastLinkDocuments ?? []
            if isReady && lastLinkDocumentsSourceID != note.id {
                invoke("setLinkDocuments", payload: [
                    "id": note.id.uuidString,
                    "documents": linkDocuments.map(\.payload)
                ])
                lastLinkDocumentsSourceID = note.id
            }
            if documentChanged || availabilityChanged {
                pushedMarkdown = note.markdown
                currentAIAvailable = aiAvailable
                currentTheme = theme
                currentReduceMotion = reduceMotion
                guard isReady else { return }
                lastAIState = nil
                invoke("setDocument", payload: [
                    "id": note.id.uuidString,
                    "markdown": note.markdown,
                    "strings": L10n.editorStrings,
                    "theme": theme,
                    "reduceMotion": reduceMotion,
                    "aiAvailable": aiAvailable
                ])
            } else if appearanceChanged {
                currentTheme = theme
                currentReduceMotion = reduceMotion
                invoke("setAppearance", payload: ["theme": theme, "reduceMotion": reduceMotion])
            }
            if appModel.aiBusy { setAIState(busy: true, label: L10n.text("editor.busy")) }
            else { setAIState(busy: false, label: nil) }
            commands.dispatchPending()
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "ready":
                isReady = true
                lastAIState = nil
                lastLinkDocumentsSourceID = nil
                if let note = appModel.store.notes.first(where: { $0.id == currentDocumentID }) {
                    pushedMarkdown = nil
                    apply(note: note, colorScheme: currentTheme == "dark" ? .dark : .light,
                          reduceMotion: currentReduceMotion, commands: commandBus ?? EditorCommandBus())
                }
            case "change":
                guard let idString = body["id"] as? String, let id = UUID(uuidString: idString),
                      id == currentDocumentID, let markdown = body["markdown"] as? String else { return }
                pushedMarkdown = markdown
                appModel.store.updateMarkdown(id: id, markdown: markdown)
            case "focus":
                guard let idString = body["id"] as? String, let id = UUID(uuidString: idString),
                      id == currentDocumentID, let focused = body["focused"] as? Bool else { return }
                isEditorFocused = focused
                commandBus?.setEditorFocused(focused)
            case "action":
                guard let action = body["action"] as? String,
                      let idString = body["id"] as? String, let id = UUID(uuidString: idString),
                      id == currentDocumentID, let text = body["text"] as? String else { return }
                let from = body["from"] as? Int ?? 0
                let to = body["to"] as? Int ?? from
                Task { await perform(action: action, id: id, text: text, from: from, to: to) }
            case "openWikiLink":
                guard let id = currentDocumentID,
                      let source = appModel.store.notes.first(where: { $0.id == id }),
                      let request = EditorLinkRequestPolicy.wikiLinkRequest(body: body, currentDocumentID: id,
                                                                            markdown: source.markdown) else { return }
                onOpenWikiLink(request)
            case "openExternalLink":
                guard let url = EditorLinkRequestPolicy.externalURL(body: body, currentDocumentID: currentDocumentID) else { return }
                onOpenExternalLink(url)
            case "importImage":
                importImage(body)
            case "toggleSidebar":
                NotificationCenter.default.post(name: .stillToggleSidebar, object: nil)
            default:
                break
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url,
                  let expected = editorHTMLURL?.standardizedFileURL,
                  url.isFileURL, url.standardizedFileURL == expected else {
                return .cancel
            }
            return .allow
        }

        func detach() {
            appModel.store.flushPendingWrites()
            isEditorFocused = false
            commandBus?.clearHistoryHandlers()
            commandBus?.clearCommandHandler()
            commandBus = nil
            webView = nil
        }

        private func dispatch(_ command: EditorCommand) -> Bool {
            guard isReady, webView != nil else { return false }
            guard let currentDocumentID, command.isTargeted(at: currentDocumentID) else { return true }

            switch command.kind {
            case .insertMarkdown(let markdown, _):
                invoke("insertMarkdown", value: markdown)
            case .insertImage(let url, let alt, let documentID):
                invoke("insertImage", payload: ["url": url, "alt": alt, "id": documentID.uuidString]) { [weak self] value, _ in
                    let inserted = (value as? NSNumber)?.boolValue == true
                    guard !inserted else { return }
                    Task { @MainActor [weak self] in self?.appModel.store.report(StoreError.imageInsertFailed) }
                }
            }
            return true
        }

        private func perform(action: String, id: UUID, text: String, from: Int, to: Int) async {
            setAIState(busy: true, label: L10n.text("editor.busy"))
            do {
                let result = try await appModel.performAIAction(action, noteID: id, selectedText: text)
                switch result {
                case .optimized(let replacement):
                    let payload: [String: Any] = [
                        "id": id.uuidString, "from": from, "to": to,
                        "original": text, "replacement": replacement
                    ]
                    invoke("replaceSelection", payload: payload) { [weak self] value, _ in
                        let replaced = (value as? NSNumber)?.boolValue == true
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            if !replaced { self.appModel.aiError = L10n.text("error.aiSelectionChanged") }
                            self.setAIState(busy: false, label: nil)
                        }
                    }
                    return
                case .wiki(let notes):
                    if let first = notes.first { onWikiCreated(first) }
                }
            } catch {
                appModel.aiError = L10n.message(for: error)
            }
            setAIState(busy: false, label: nil)
        }

        private func importImage(_ message: [String: Any]) {
            guard let idText = message["id"] as? String, let id = UUID(uuidString: idText), id == currentDocumentID,
                  let requestID = message["requestId"] as? String,
                  let filename = message["filename"] as? String,
                  let mime = message["mime"] as? String,
                  let base64 = message["base64"] as? String,
                  let data = Data(base64Encoded: base64) else { return }
            do {
                let savedName = try appModel.store.addImage(data: data, filename: filename, mimeType: mime)
                invoke("insertImage", payload: [
                    "url": "attachments/\(savedName)", "alt": URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent,
                    "requestId": requestID, "id": id.uuidString
                ]) { [weak self] value, _ in
                    let inserted = (value as? NSNumber)?.boolValue == true
                    guard !inserted else { return }
                    Task { @MainActor [weak self] in self?.appModel.store.report(StoreError.imageInsertFailed) }
                }
            } catch { appModel.store.report(error) }
        }

        private func setAIState(busy: Bool, label: String?) {
            guard isReady, lastAIState?.busy != busy || lastAIState?.label != label else { return }
            lastAIState = (busy, label)
            var payload: [String: Any] = ["busy": busy]
            if let label { payload["label"] = label }
            invoke("setAIState", payload: payload)
        }

        private func invoke(_ method: String, payload: [String: Any], completion: (@Sendable (Any?, Error?) -> Void)? = nil) {
            guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.fragmentsAllowed]),
                  let json = String(data: data, encoding: .utf8) else { completion?(nil, nil); return }
            webView?.evaluateJavaScript("window.stillEditor && window.stillEditor.\(method)(\(json))", completionHandler: completion)
        }

        private func invoke(_ method: String, value: String) {
            guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
                  let json = String(data: data, encoding: .utf8) else { return }
            webView?.evaluateJavaScript("window.stillEditor && window.stillEditor.\(method)(\(json))")
        }
    }
}

@MainActor
private final class StillAssetSchemeHandler: NSObject, WKURLSchemeHandler {
    private let store: StillStore

    init(store: StillStore) { self.store = store }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              url.host == "image",
              let filename = url.pathComponents.last,
              filename != "/", let (data, mime) = store.attachment(named: filename) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let response = URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil)
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
