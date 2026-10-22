import Combine
import SwiftUI
#if canImport(Sparkle)
import Sparkle
#endif

/// Automatic updates through Sparkle. Release builds carry an update feed address
/// and a public signing key in Info.plist (SUFeedURL, SUPublicEDKey); builds without
/// them never start the updater, and the update commands and settings stay hidden.
@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()
    /// True when this build was given a feed and a key, so updates can be checked.
    let isConfigured: Bool
    @Published private(set) var canCheckForUpdates = false
    #if canImport(Sparkle)
    private let controller: SPUStandardUpdaterController?
    private var observation: AnyCancellable?
    #endif

    private init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let feed = (info["SUFeedURL"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let key = (info["SUPublicEDKey"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        #if canImport(Sparkle)
        isConfigured = URL(string: feed)?.scheme == "https" && !key.isEmpty
        controller = isConfigured
            ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
            : nil
        observation = controller?.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.canCheckForUpdates = value }
        #else
        isConfigured = false
        #endif
    }

    /// Whether Sparkle checks the feed in the background (about once a day).
    var checksAutomatically: Bool {
        get {
            #if canImport(Sparkle)
            return controller?.updater.automaticallyChecksForUpdates ?? false
            #else
            return false
            #endif
        }
        set {
            objectWillChange.send()
            #if canImport(Sparkle)
            controller?.updater.automaticallyChecksForUpdates = newValue
            #endif
        }
    }

    func checkForUpdates() {
        #if canImport(Sparkle)
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
        #endif
    }
}

/// "Check for Updates…", for the app menu and the menu bar menu. Hidden when the
/// build has no update feed.
struct CheckForUpdatesButton: View {
    @ObservedObject private var updater = AppUpdater.shared

    var body: some View {
        if updater.isConfigured {
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
        }
    }
}

/// The Updates section of Settings. Hidden when the build has no update feed.
struct UpdateSettingsSection: View {
    @ObservedObject private var updater = AppUpdater.shared

    var body: some View {
        if updater.isConfigured {
            SettingsSection("Updates") {
                SettingsSurface {
                    SettingsRow("Check for updates automatically",
                                detail: "DocuFind asks before installing. A check downloads the list of releases; nothing about your files is sent.",
                                isOn: Binding(get: { updater.checksAutomatically }, set: { updater.checksAutomatically = $0 }))
                    SettingsDivider()
                    SettingsRow("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")") {
                        Button("Check Now") { updater.checkForUpdates() }.disabled(!updater.canCheckForUpdates)
                    }
                }
            }
        }
    }
}
