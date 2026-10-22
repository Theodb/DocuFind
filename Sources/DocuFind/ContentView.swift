import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    static let omniFocusSearch = Notification.Name("DocuFind.focusSearch")
}

enum Destination: String, CaseIterable, Identifiable {
    case search = "Search", library = "Library", settings = "Settings", about = "About"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .search: "magnifyingglass"
        case .library: "folder"
        case .settings: "gearshape"
        case .about: "info.circle"
        }
    }
}

struct DocuFindView: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var destination: Destination?
    @State private var columns = NavigationSplitViewVisibility.all
    @FocusState private var searchFocused: Bool
    @State private var runtimeExpanded = false
    @State private var loginItemOn = false
    @ObservedObject private var shortcut = GlobalShortcut.shared
    @AppStorage(QuickSearchLayout.storageKey) private var quickLayout = QuickSearchLayout.carousel.rawValue

    init(model: AppModel, destination: Destination = .search) {
        self.model = model
        _destination = State(initialValue: destination)
    }

    private var working: Bool { model.connecting || model.indexing || model.searching || model.installing || model.downloadingModel || model.modelLoading }
    /// macOS can drop its Neural Engine copy of the model (cache pressure, a system update); rebuilding it takes
    /// minutes, so a load that reports progress shows how far it has got.
    private func statusLine(at date: Date) -> String {
        guard working else { return status }
        if model.modelLoading, let preparation = model.modelPreparation, preparation.start < 1 {
            return "\(model.message) \(Int(preparation.fraction(at: date) * 100))%"
        }
        return model.message
    }

    private var status: String {
        if model.installing { return "Installing" }
        if model.downloadingModel { return "Downloading the search model" }
        if model.indexing { return "Indexing" }
        if model.searching { return "Searching" }
        if model.connecting { return "Connecting" }
        if model.modelLoading { return "Loading the search model" }
        if !model.connected || !model.dependenciesReady { return "Setup required" }
        return "On-device search"
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            MagniSidebar(model: model, destination: $destination)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 280)
        } detail: {
            VStack(spacing: 0) {
                Group {
                    switch destination ?? .search {
                    case .search: searchPage
                    case .library: libraryPage
                    case .settings: settingsPage
                    case .about: AboutPage()
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                if let error = model.error { errorNotice(error) }
                statusBar
            }
            .background(Color(nsColor: .windowBackgroundColor).opacity(reduceTransparency || destination == .search ? 1 : 0.24))
            .navigationTitle(destination?.rawValue ?? "Search")
            .toolbarBackground(.hidden, for: .windowToolbar)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if destination == .library {
                        Button { model.addFolder() } label: { Image(systemName: "folder.badge.plus") }
                            .disabled(model.indexing).help("Add a search location")
                            .accessibilityLabel("Add search location")
                    }
                }
            }
        }
        .background(MagniGlassSurface(radius: 0, material: .underWindowBackground).ignoresSafeArea())
        .background(MagniWindowBackdrop())
        .tint(.accentColor)
        .overlay {
            // The animated logo is reserved for launch: connecting, then loading the model.
            if model.launching {
                ModelLoadingOverlay(title: model.modelLoading ? "Loading the search model" : "Starting DocuFind")
                    .transition(.opacity)
            } else if model.showOnboarding {
                // Until setup is done, the guide is the whole window: the app behind it isn't usable yet.
                OnboardingScreen(model: model).transition(.opacity)
            }
        }
        // Only the logo or the guide while they show, but the window keeps its close, minimise and zoom buttons.
        .toolbar(removing: model.launching || model.showOnboarding ? .sidebarToggle : nil)
        .toolbar(model.launching || model.showOnboarding ? .hidden : .automatic, for: .windowToolbar)
        .animation(.easeInOut(duration: 0.45), value: model.launching)
        .animation(.easeInOut(duration: 0.35), value: model.showOnboarding)
        .onChange(of: model.launching) { _, launching in if !launching { model.offerShortcutTutorial() } }
        .onReceive(NotificationCenter.default.publisher(for: .omniFocusSearch)) { _ in
            destination = .search
            searchFocused = true
        }
        .onChange(of: destination) { _, value in
            if value == .settings && !model.dependenciesReady { runtimeExpanded = true }
        }
    }

    private var searchPage: some View {
        SearchExperience(model: model, focus: $searchFocused, onSetUpLibrary: { destination = .library })
    }

    private var libraryPage: some View {
        SettingsPage(title: "Your library", subtitle: "Choose where DocuFind looks for your files.") {
            libraryOverview
            SettingsSection("Search Locations", accessory: {
                Button("Add Folder…") { model.addFolder() }.disabled(model.indexing)
            }) {
                SettingsSurface {
                    if model.roots.isEmpty {
                        SettingsRow("No folders yet", detail: "Add a folder to start building your library.", symbol: "folder.badge.plus") { EmptyView() }
                    }
                    ForEach(Array(model.roots.enumerated()), id: \.element) { index, root in
                        if index > 0 { SettingsDivider(symbol: true) }
                        SettingsRow(root == NSHomeDirectory() ? "Home Folder" : URL(fileURLWithPath: root).lastPathComponent,
                                    detail: root.replacingOccurrences(of: NSHomeDirectory(), with: "~"),
                                    symbol: root == NSHomeDirectory() ? "house.fill" : "folder.fill", symbolColor: .blue,
                                    truncatesDetail: true) {
                            removeButton("Remove \(root)", help: "Remove search location") { await model.removeRoot(root) }
                        }
                    }
                }
                SettingsSurface {
                    SettingsRow("Keep the index up to date",
                                detail: "New and changed files become searchable a few seconds after they're saved. Deleted files leave the index.",
                                isOn: $model.liveUpdates)
                }
                SettingsNote(model.liveUpdates ? "Add external drives separately. Choose Update Index after adding a location."
                                               : "Add external drives separately. Index again after files or locations change.")
            }
            fileTypesSection
            skippedFoldersSection
            IndexingOptionsSection(model: model)
            SettingsSection("File Access") {
                SettingsSurface {
                    SettingsRow("Allow access to your files",
                                detail: "macOS may request access to Documents, Desktop, and Downloads. Enable Full Disk Access to include more protected locations.",
                                symbol: "lock.open", alignment: .top, control: { EmptyView() }) {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 10) { fileAccessButtons }
                            VStack(alignment: .leading, spacing: 8) { fileAccessButtons }
                        }
                        .padding(.top, 6)
                    }
                }
                SettingsNote("System folders, Library, hidden folders, app databases, and cloud-only files are excluded. Export content from Photos or Mail before indexing it.")
            }
            if !model.dependenciesReady {
                SettingsSurface {
                    SettingsRow("Set up the local model before indexing.", symbol: "info.circle") {
                        Button("Open Settings") { destination = .settings }
                    }
                }
            }
            SettingsNote("The search model (about 3.3 GB) downloads once, during setup. Indexing a large library can take time; completed files are reused. Your file content stays on your Mac.")
        }
    }

    /// The indexed count with the main action. The action moves under the text when the page is narrow.
    private var libraryOverview: some View {
        SettingsSurface {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    libraryOverviewText
                    Spacer(minLength: 12)
                    libraryActions
                }
                VStack(alignment: .leading, spacing: 14) {
                    libraryOverviewText
                    HStack(spacing: 10) { libraryActions }
                        .padding(.leading, 62)
                }
            }
            .padding(SettingsLayout.rowPadding)
        }
    }

    private var libraryOverviewText: some View {
        HStack(spacing: 14) {
            Image(systemName: "internaldrive").font(.system(size: 25, weight: .light)).foregroundStyle(.blue)
                .frame(width: 48, height: 48).background(.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 5) {
                Text(model.indexing ? "Indexing your library" : "\(model.indexedCount.formatted()) files indexed").font(.system(size: 17, weight: .semibold))
                Text(model.indexing ? model.indexingSummary
                     : model.liveUpdating ? "Updating the files that changed…"
                     : "Documents, images, and audio. Stored on this Mac.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var libraryActions: some View {
        if model.indexing {
            if let fraction = model.indexingFraction {
                ProgressView(value: fraction).frame(width: 140)
                    .accessibilityLabel("Indexing progress")
            } else {
                ProgressView().controlSize(.small)
            }
            Button("Stop") { Task { await model.cancel() } }
        } else {
            Button(model.indexedCount == 0 ? "Start Indexing" : "Update Index") { Task { await model.index() } }
                .buttonStyle(.borderedProminent)
                .disabled(!model.connected || !model.dependenciesReady || model.roots.isEmpty || model.installing)
        }
    }

    @ViewBuilder private var fileAccessButtons: some View {
        Button("Open Privacy Settings…") {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
        }
        Button("Show Setup Guide…") { model.showOnboarding = true }
        if DiskAccess.hasFullDiskAccess() {
            Label("Full Disk Access is on", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                .font(.system(size: 12))
        }
    }

    private func removeButton(_ label: String, help: String, action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: { Image(systemName: "minus.circle").font(.system(size: 14)) }
            .buttonStyle(.plain).foregroundStyle(.secondary).disabled(model.indexing)
            .accessibilityLabel(label).help(help)
    }

    private func fileTypeRow(_ title: String, detail: String, isOn: Bool, change: @escaping (Bool) async -> Void) -> some View {
        SettingsRow(title, detail: detail, isOn: Binding(get: { isOn }, set: { value in Task { await change(value) } }))
            .disabled(model.indexing || !model.connected)
    }

    private var fileTypesSection: some View {
        SettingsSection("File Types") {
            SettingsSurface {
                fileTypeRow("Source code", detail: "Python, Swift, JavaScript and other code, plus configuration files (YAML, TOML, XML).", isOn: model.indexCode) { await model.setFileType(code: $0) }
                SettingsDivider()
                fileTypeRow("Spreadsheet data", detail: "CSV, TSV and log files. Tables and logs rarely match a description, and they are slow to read.", isOn: model.indexData) { await model.setFileType(data: $0) }
            }
            SettingsNote("Documents, PDFs, notes, photos and recordings are always read. Turning a type off removes its files from the index; turning it on adds them at the next update.")
        }
    }

    /// Large folders worth skipping, and the folders already skipped.
    private var skippedFoldersSection: some View {
        SettingsSection("Skipped Folders", accessory: {
            Button("Skip a Folder…") { model.chooseFolderToSkip() }.disabled(!model.connected)
        }) {
            if !model.suggestedSkips.isEmpty {
                SettingsSurface {
                    SettingsRow("Most of your files are in a few folders",
                                detail: "Datasets, exports and generated files make indexing slow and rarely need finding by meaning. Skipping a folder leaves its files untouched.",
                                symbol: "chart.bar.doc.horizontal") { EmptyView() }
                    ForEach(model.suggestedSkips) { folder in
                        SettingsDivider(symbol: true)
                        SettingsRow(URL(fileURLWithPath: folder.path).lastPathComponent,
                                    detail: folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"),
                                    symbol: "folder", truncatesDetail: true) {
                            HStack(spacing: 12) {
                                Text("\(folder.files.formatted()) files").font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                                Button("Skip") { Task { await model.skipFolder(folder.path) } }
                            }
                        }
                    }
                }
            }
            if !model.skippedFolders.isEmpty {
                SettingsSurface {
                    ForEach(Array(model.skippedFolders.enumerated()), id: \.element) { index, folder in
                        if index > 0 { SettingsDivider(symbol: true) }
                        SettingsRow(URL(fileURLWithPath: folder).lastPathComponent,
                                    detail: folder.replacingOccurrences(of: NSHomeDirectory(), with: "~"),
                                    symbol: "eye.slash", truncatesDetail: true) {
                            removeButton("Read \(folder) again", help: "Read this folder again") { await model.unskipFolder(folder) }
                        }
                    }
                }
            }
            SettingsNote("Hidden folders, Library, app bundles, dependency folders and JSON files are always skipped.")
        }
    }

    private var settingsPage: some View {
        SettingsPage(title: "Settings", subtitle: "Everything you need for private, on-device search.") {
            SettingsSection("Search Engine") {
                SettingsSurface {
                    SettingsRow("BidirLM Omni", detail: "Text, photos and recordings, processed on this Mac's Neural Engine.", symbol: "cpu", symbolColor: .blue) {
                        if model.dependenciesReady {
                            Label("Installed", systemImage: "checkmark.circle.fill")
                                .font(.system(size: 11, weight: .medium)).foregroundStyle(.green)
                        } else {
                            Button("Set Up…") { runtimeExpanded = true }
                        }
                    }
                }
                if model.staleIndexCount > 0 {
                    SettingsNote("\(model.staleIndexCount) previously indexed files were read with an earlier version of the search model. Update your library to search them again.")
                }
            }
            SettingsSection("Quick Search") {
                SettingsSurface {
                    SettingsRow("Floating search bar", detail: "Search from any app with a keyboard shortcut, even with this window closed.",
                                isOn: Binding(get: { shortcut.isEnabled }, set: { shortcut.setEnabled($0) }))
                    if shortcut.isEnabled {
                        SettingsDivider()
                        SettingsRow("Shortcut",
                                    detail: shortcut.isRegistered ? "Click, then press a new combination." : "Another app already uses this shortcut. Choose a different one.",
                                    detailColor: shortcut.isRegistered ? .secondary : .orange) {
                            ShortcutRecorder()
                        }
                    }
                    SettingsDivider()
                    SettingsRow("Results", detail: "Carousel shows one match at a time, with its player and details. List stacks several matches.") {
                        Picker("Results", selection: $quickLayout) {
                            ForEach(QuickSearchLayout.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                        }
                        .labelsHidden().pickerStyle(.segmented).frame(width: SettingsLayout.pickerWidth)
                    }
                    SettingsDivider()
                    SettingsRow("Open at login", detail: "Keeps DocuFind in the menu bar with the search model loaded, so results are instant.",
                                isOn: Binding(get: { loginItemOn }, set: { value in
                                    do { try LoginItem.set(value); loginItemOn = LoginItem.isEnabled }
                                    catch { model.error = "Open at login couldn't be changed: \(error.localizedDescription)" }
                                }))
                }
                .onAppear { loginItemOn = LoginItem.isEnabled }
            }
            UpdateSettingsSection()
            SettingsSection("Advanced") {
                SettingsSurface {
                    DisclosureGroup("Local Runtime", isExpanded: $runtimeExpanded) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Install Runtime sets everything up, downloading a private Python 3.12 if needed. To use your own, choose Python 3.11–3.13 or an existing DocuFind environment.")
                                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 8) {
                                TextField("Python executable", text: $model.python).textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced))
                                    .accessibilityLabel("Python executable")
                                Button("Choose…") { model.choosePython() }
                            }
                            if model.installing || model.downloadingModel {
                                SetupProgressView(model: model)
                            }
                            HStack(spacing: 8) {
                                Button(model.installing ? "Installing…" : "Install Runtime") { Task { await model.setUp() } }.disabled(model.installing || model.downloadingModel || model.indexing)
                                if model.dependenciesReady && (!model.modelDownloaded || !model.modelPrepared) {
                                    Button(model.downloadingModel ? "Preparing…" : model.modelDownloaded ? "Prepare Model" : "Download Model") { Task { await model.downloadModel() } }
                                        .disabled(!model.connected || model.installing || model.downloadingModel || model.indexing)
                                }
                                Button("Reconnect") { Task { await model.connect() } }.disabled(working)
                            }
                            Text("Setup downloads software and model files. Search does not use a hosted service.")
                                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }.padding(.top, 10)
                    }
                    .font(.system(size: 13))
                    .padding(.horizontal, SettingsLayout.rowPadding).padding(.vertical, SettingsLayout.rowVerticalPadding)
                    .frame(minHeight: 52)
                    SettingsDivider()
                    DisclosureGroup("Model & Diagnostics") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("BidirLM/BidirLM-Omni-2.5B-Embedding\n447a6e31be61b84443144afda21374339ce408e6")
                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                            ScrollView {
                                Text(model.logs.isEmpty ? "No diagnostic messages." : model.logs)
                                    .font(.system(size: 10, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }.frame(maxHeight: 180).padding(10).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                        }.padding(.top, 10)
                    }
                    .font(.system(size: 13))
                    .padding(.horizontal, SettingsLayout.rowPadding).padding(.vertical, SettingsLayout.rowVerticalPadding)
                    .frame(minHeight: 52)
                }
            }
            HStack(spacing: 7) {
                Image(systemName: "lock.shield")
                Text("Your content and search queries stay on this Mac.")
            }
            .font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 4)
        }
    }

    private var statusBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 7) {
                if working { ProgressView().controlSize(.mini).scaleEffect(0.8) }
                else { Circle().fill(model.connected && model.dependenciesReady ? Color.green : Color.secondary.opacity(0.5)).frame(width: 5, height: 5) }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(statusLine(at: context.date)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if model.indexing {
                    Button("Stop") { Task { await model.cancel() } }.controlSize(.mini)
                } else {
                    Text("\(model.indexedCount.formatted()) files").font(.system(size: 10)).foregroundStyle(.tertiary).monospacedDigit()
                }
            }.padding(.horizontal, 20).frame(height: 31)
        }
    }

    private func errorNotice(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.system(size: 12))
            Text(error).font(.system(size: 11)).textSelection(.enabled).lineLimit(4).frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 8)
            Button { model.error = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Dismiss error")
        }.padding(14).background(.orange.opacity(0.07))
    }
}

/// Photo thumbnails, decoded off the main thread and kept decoded. Decodes run in parallel (they used to queue
/// one behind another inside an actor), and small ones use the photo's embedded preview when it has one.
final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()
    private let cache: NSCache<NSString, CGImage> = { let cache = NSCache<NSString, CGImage>(); cache.totalCostLimit = 96 * 1024 * 1024; return cache }()

    func image(path: String, maxPixels: Int) async -> CGImage? {
        let key = "\(path):\(maxPixels)" as NSString
        if let image = cache.object(forKey: key) { return image }
        let decoded = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
            // Small sizes (icons, dots) are served by the embedded preview in about a millisecond; large covers
            // decode the photo itself, since embedded previews are often too small for them.
            let fromImage = maxPixels <= 160 ? kCGImageSourceCreateThumbnailFromImageIfAbsent : kCGImageSourceCreateThumbnailFromImageAlways
            return CGImageSourceCreateThumbnailAtIndex(source, 0, [fromImage: true, kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                                                                   kCGImageSourceCreateThumbnailWithTransform: true,
                                                                   kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }.value
        if let decoded { cache.setObject(decoded, forKey: key, cost: decoded.bytesPerRow * decoded.height) }
        return decoded
    }
}
