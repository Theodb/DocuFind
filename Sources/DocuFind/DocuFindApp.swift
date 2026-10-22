import AppKit
import CoreSpotlight
import SwiftUI
import UniformTypeIdentifiers

@main
struct DocuFindApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        WindowGroup(id: "main") {
            DocuFindView(model: model)
                .frame(minWidth: 720, minHeight: 520)
                .task { if !model.connected { await model.connect() } }
                // Let the open window handle docufind:// links instead of SwiftUI opening another one.
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                .onOpenURL { url in
                    guard url.scheme == "docufind" else { return }
                    // docufind://quick?q=… opens the floating search bar with a query.
                    if url.host == "quick" {
                        let text = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "q" })?.value ?? ""
                        QuickSearchController.shared.show(query: text)
                        return
                    }
                    // docufind://index updates the index, like Update Index.
                    if url.host == "index" {
                        Task { await model.index() }
                        return
                    }
                    if let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "q" })?.value {
                        model.query = query
                        Task { await model.search() }
                    }
                }
        }
        .defaultSize(width: 900, height: 620)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .appInfo) { AboutButton() }
            CommandGroup(after: .appInfo) { CheckForUpdatesButton() }
            CommandGroup(after: .newItem) {
                SearchFilesButton()
            }
            CommandGroup(replacing: .help) { ShortcutTourButton(model: model) }
        }
        MenuBarExtra("DocuFind", systemImage: "sparkle.magnifyingglass") {
            DocuFindMenu()
        }
        Window("About DocuFind", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
    }
}

/// Help → Keyboard Shortcuts Tour, opening the main window first when it was closed.
private struct ShortcutTourButton: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Keyboard Shortcuts Tour") {
            NSApp.activate(ignoringOtherApps: true)
            if !NSApp.windows.contains(where: { $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible }) { openWindow(id: "main") }
            // The tour runs on the search page, starting at its field.
            NotificationCenter.default.post(name: .omniFocusSearch, object: nil)
            model.startTour()
        }
        .disabled(model.launching || model.showOnboarding)
    }
}

/// Cmd-F: focuses the search field, opening the main window first when it was closed.
private struct SearchFilesButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Search Files") {
            NSApp.activate(ignoringOtherApps: true)
            if NSApp.windows.contains(where: { $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible }) {
                NotificationCenter.default.post(name: .omniFocusSearch, object: nil)
            } else {
                openWindow(id: "main")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NotificationCenter.default.post(name: .omniFocusSearch, object: nil) }
            }
        }
        .keyboardShortcut("f", modifiers: .command)
    }
}

/// The menu bar icon's menu: quick search, the main window, updates, and quitting.
private struct DocuFindMenu: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var shortcut = GlobalShortcut.shared

    var body: some View {
        Button("Quick Search   \(shortcut.shortcut.display)") { QuickSearchController.shared.show() }
        Button("Open DocuFind") {
            NSApp.activate(ignoringOtherApps: true)
            if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true && $0.canBecomeMain }) {
                window.makeKeyAndOrderFront(nil)
            } else {
                openWindow(id: "main")
            }
        }
        CheckForUpdatesButton()
        Divider()
        Button("Quit DocuFind") { NSApp.terminate(nil) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.removeOldSpotlightEntries()
        NestedScrolling.install()
        // The floating search bar, from anywhere: a global hot key plus a login item.
        GlobalShortcut.shared.onPress = {
            QuickSearchController.shared.toggle()
            AppModel.shared.tourDid(.anywhere)
        }
        GlobalShortcut.shared.register()
        LoginItem.enableOnFirstLaunch()
        // The docufind command-line tool talks to this running copy and its loaded model.
        CommandServer.shared.start(dataDirectory: AppModel.shared.dataDirectory)
        _ = AppUpdater.shared
    }

    /// Keep running after the window closes, so the shortcut and the loaded model stay ready.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        CommandServer.shared.stop()
        AppModel.shared.client.stop()
    }

    /// Earlier versions copied indexed files into Spotlight's index. Spotlight already
    /// indexes most of them itself, so that made duplicates; remove those entries once.
    private static func removeOldSpotlightEntries() {
        let key = "spotlightEntriesRemoved"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        // The index name the app used when it was called OmniFind.
        CSSearchableIndex(name: "OmniFind Files").deleteAllSearchableItems { error in
            if error == nil { DispatchQueue.main.async { UserDefaults.standard.set(true, forKey: key) } }
        }
    }
}

