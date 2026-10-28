import AppKit
import SwiftUI

@main
struct StillApp: App {
    @NSApplicationDelegateAdaptor(StillAppDelegate.self) private var appDelegate
    @State private var appModel = StillAppModel()
    @State private var editorCommands = EditorCommandBus()
    @State private var noteNavigation = NoteNavigationHistory()

    var body: some Scene {
        Window(L10n.text("app.name"), id: "main") {
            ContentView(appModel: appModel, commandBus: editorCommands, noteNavigation: noteNavigation)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                    appModel.store.flushPendingWrites()
                    appModel.chatStore.flushPendingWrites()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    appModel.store.flushPendingWrites()
                    appModel.chatStore.flushPendingWrites()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1220, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L10n.text("list.newNote")) {
                    NotificationCenter.default.post(name: .stillCreateNote, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(replacing: .undoRedo) {
                Button(L10n.text("action.undo")) {
                    if !editorCommands.undoIfEditorFocused() {
                        NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
                    }
                }
                .keyboardShortcut("z", modifiers: .command)

                Button(L10n.text("action.redo")) {
                    if !editorCommands.redoIfEditorFocused() {
                        NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
                    }
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandGroup(after: .textEditing) {
                Button(L10n.text("quickOpen.title")) {
                    NotificationCenter.default.post(name: .stillQuickOpen, object: nil)
                }
                .keyboardShortcut("k", modifiers: .command)

                Button(L10n.text("editor.find")) {
                    NotificationCenter.default.post(name: .stillShowFind, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(appModel.editorDocumentID == nil)

                Button(L10n.text("nav.search")) {
                    NotificationCenter.default.post(name: .stillFocusSearch, object: NSApp.keyWindow ?? NSApp.mainWindow)
                }
                .keyboardShortcut("f", modifiers: [.command, .option])

                Button(L10n.text("nav.back")) {
                    NotificationCenter.default.post(name: .stillNavigateBack, object: nil)
                }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!noteNavigation.canGoBack)
            }
            CommandGroup(replacing: .sidebar) {
                Button(L10n.text("sidebar.toggle")) {
                    NotificationCenter.default.post(name: .stillToggleSidebar, object: nil)
                }
                .keyboardShortcut("b", modifiers: .command)
            }
        }
    }
}

@MainActor
final class StillAppDelegate: NSObject, NSApplicationDelegate {
    private var searchShortcutMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        searchShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let handled = MainActor.assumeIsolated { GlobalSearchShortcut.handle(event) }
            return handled ? nil : event
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let searchShortcutMonitor { NSEvent.removeMonitor(searchShortcutMonitor) }
        searchShortcutMonitor = nil
    }
}

@MainActor
enum GlobalSearchShortcut {
    static let mainWindowFrameAutosaveName = "StillMainWindow"

    static func handle(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard event.type == .keyDown, modifiers == [.command, .option],
              event.charactersIgnoringModifiers?.lowercased() == "f",
              let window = event.window ?? NSApp.keyWindow ?? NSApp.mainWindow,
              window.frameAutosaveName == mainWindowFrameAutosaveName,
              window.attachedSheet == nil, NSApp.modalWindow == nil else { return false }
        // SwiftUI menu actions can arrive after the next key. Route this shortcut
        // while AppKit is still dispatching its original key-down event.
        NotificationCenter.default.post(name: .stillFocusSearch, object: window)
        return true
    }
}

extension Notification.Name {
    static let stillFocusSearch = Notification.Name("still.focusSearch")
    static let stillToggleSidebar = Notification.Name("still.toggleSidebar")
    static let stillNavigateBack = Notification.Name("still.navigateBack")
    static let stillQuickOpen = Notification.Name("still.quickOpen")
    static let stillShowFind = Notification.Name("still.showFind")
    static let stillCreateNote = Notification.Name("still.createNote")
}

struct WindowConfigurator: NSViewRepresentable {
    var reduceTransparency: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(nsView.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.title = L10n.text("app.name")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.styleMask.insert(.fullSizeContentView)
        window.isOpaque = reduceTransparency
        window.backgroundColor = reduceTransparency ? .windowBackgroundColor : .clear
        window.isMovableByWindowBackground = false
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 960, height: 640)
        window.setFrameAutosaveName(GlobalSearchShortcut.mainWindowFrameAutosaveName)
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        // A single behind-window material keeps other windows in the native blur source.
        view.material = .menu
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = .menu
        nsView.blendingMode = .behindWindow
        nsView.state = .active
    }
}
