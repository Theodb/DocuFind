import AppKit
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    @Published var query = ""
    /// The text of the search whose results are shown; the field may have been edited since.
    @Published private(set) var searchedQuery = ""
    /// Bumped by each search and by clearing, so a reply or refinement that arrives late is dropped.
    private var searchGeneration = 0
    @Published var results: [SearchItem] = []
    @Published var reference: URL?
    @Published var filter = "all"
    @Published var roots: [String]
    /// Folders inside the chosen ones that are never read.
    @Published var skippedFolders: [String]
    /// The few folders holding most of the files, from the last full pass, to suggest skipping.
    @Published var largeFolders: [LargeFolder] = []
    /// Optional file types, off by default: source code and tabular data (CSV/TSV).
    @Published var indexCode: Bool
    /// Which files are read and in what order (see backend/indexing_rules.py); all on by default.
    @Published var indexingOptions: [String: Bool]
    /// Machine-made files the last full update skipped, by reason.
    @Published var autoSkipped: [String: Int] = [:]
    @Published var indexData: Bool
    /// Keep the index current as files change, without pressing Update Index.
    @Published var liveUpdates: Bool { didSet { UserDefaults.standard.set(liveUpdates, forKey: "liveUpdates"); restartWatching() } }
    /// True while changed files are being indexed in the background.
    @Published var liveUpdating = false
    @Published var python: String
    @Published var indexedCount = 0
    @Published var indexingCompletedFiles = 0
    @Published var indexingSummary = "Preparing your library…"
    /// Share of planned indexing work done; nil until the pre-count arrives.
    @Published var indexingFraction: Double?
    @Published var staleIndexCount = 0
    @Published var connected = false
    @Published var connecting = false
    @Published var dependenciesReady = false
    @Published var searching = false
    @Published var indexing = false
    @Published var installing = false
    /// Runtime install progress from setup.sh: share done and the current step. Nil when no install has run.
    @Published var runtimeProgress: Double?
    @Published var runtimeStep = ""
    /// The search model's download, during setup or before the first index.
    @Published var modelDownload: ModelDownload?
    @Published var modelDownloaded = false
    /// Compiled for this Mac and checked, after the first download.
    @Published var modelPrepared = false
    /// How far that preparation has got, and the part being built ("text", "photos"…), while it runs.
    @Published var modelPreparation: PreparationProgress?
    @Published var modelPreparationPart = ""
    @Published var downloadingModel = false
    @Published var hasSearched = false
    /// A note from the last search, such as a quoted phrase no file contains.
    @Published var searchNotice: String?
    @Published var recent: [SearchItem] = []
    /// Indexed files by kind (text, image, audio), for the sidebar's library card.
    @Published var kindCounts: [String: Int] = [:]
    /// True while the worker loads BidirLM (first search, warm-up or indexing).
    @Published var modelLoading = false
    /// True until the first connection attempt finishes, for the launch screen.
    @Published var launching = true
    @Published var showOnboarding = !UserDefaults.standard.bool(forKey: "onboardingComplete") {
        // The guide comes first: the tour waits, unseen, until setup is done.
        didSet { if showOnboarding { tourStep = nil } }
    }
    /// The keyboard tour's current step, while it runs.
    @Published var tourStep: TourStep?
    @Published var onboardingStep = 0
    @Published var message = "Connect your local runtime to get started."
    @Published var error: String?
    @Published var logs = ""
    let client = BackendClient()
    private var connectionTask: Task<Void, Never>?
    private var indexingProgress = IndexingProgress()
    private var indexingStartedAt: Date?
    private var indexingTicker: Task<Void, Never>?
    private var pendingIndexProgress: [String: Any] = [:]
    private var pendingIndexMessage: String?
    private var indexStopRequested = false
    var watcher: FileWatcher?
    var livePending = Set<String>()
    var liveTask: Task<Void, Never>?
    let dataDirectory: URL

    private init() {
        LegacySettings.migrate()
        let env = ProcessInfo.processInfo.environment
        dataDirectory = URL(fileURLWithPath: env["DOCUFIND_DATA_DIR"] ?? LegacySettings.dataDirectory(beside: Bundle.main.bundleURL))
        roots = UserDefaults.standard.stringArray(forKey: "roots") ?? [NSHomeDirectory()]
        skippedFolders = UserDefaults.standard.stringArray(forKey: "skippedFolders") ?? []
        indexCode = UserDefaults.standard.bool(forKey: "indexCode")
        indexingOptions = UserDefaults.standard.dictionary(forKey: "indexingOptions") as? [String: Bool] ?? [:]
        indexData = UserDefaults.standard.bool(forKey: "indexData")
        liveUpdates = UserDefaults.standard.object(forKey: "liveUpdates") as? Bool ?? true
        let candidates = [env["DOCUFIND_PYTHON"], dataDirectory.appendingPathComponent("venv/bin/python").path, UserDefaults.standard.string(forKey: "python"), "/opt/homebrew/bin/python3.13", "/opt/homebrew/bin/python3.12", "/usr/local/bin/python3.12", "/Library/Frameworks/Python.framework/Versions/3.13/bin/python3", "/Library/Frameworks/Python.framework/Versions/3.12/bin/python3", "/opt/homebrew/bin/python3", "/usr/bin/python3"].compactMap { $0 }
        python = candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/python3"
        client.onProgress = { [weak self] event in self?.progress(event) }
        client.onLog = { [weak self] text in
            guard let self else { return }
            self.logs = String((self.logs + text).suffix(16000))
        }
    }

    func connect() async {
        if let connectionTask { await connectionTask.value; return }
        let task = Task { await performConnect() }
        connectionTask = task
        await task.value
        connectionTask = nil
    }

    private func performConnect() async {
        guard !indexing else { return }
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Connect the local search runtime")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        connecting = true
        defer { connecting = false; launching = false }
        connected = false
        message = "Connecting to the local runtime…"
        error = nil
        do {
            try client.start(python: python, dataDirectory: dataDirectory)
            let configuration = try await client.request("configure", configureArguments)
            applyStatus(configuration)
            let status = try await client.request("status")
            applyStatus(status)
            connected = true
            await loadRecent()
            // The page is usable now: the model finishes loading behind it (the status bar says so), and a
            // search typed meanwhile waits for it in the worker's queue.
            launching = false
            UserDefaults.standard.set(python, forKey: "python")
            message = dependenciesReady
                ? (indexedCount > 0 ? "Ready for local search." : "Ready. Start indexing to make files searchable.")
                : "Install the model runtime in Settings."
            restartWatching()
            Task {
                // Setup left unfinished (quit midway, or an update brought a new model): back to its step of the guide.
                if setupNeeded && !showOnboarding {
                    onboardingStep = OnboardingView.setupStep
                    showOnboarding = true
                    await setUp()
                }
                // The model first, so the first search is quick.
                if dependenciesReady && indexedCount > 0 { await warmModel() }
            }
        } catch { self.error = error.localizedDescription }
    }

    /// Loads the model in the background after launch so the first search is quick.
    /// A search typed meanwhile simply waits behind it in the worker's queue.
    func warmModel() async {
        guard connected, dependenciesReady, !indexing, !modelLoading else { return }
        modelLoading = true
        let previous = message
        message = "Loading the search model…"
        defer {
            modelLoading = false
            if message == "Loading the search model…" || message.hasPrefix("Optimizing the search model") { message = previous }
        }
        _ = try? await client.request("search", ["text": "warm up", "kind": "all", "limit": 1])
    }

    var setupNeeded: Bool { !dependenciesReady || !modelDownloaded || !modelPrepared }

    func finishOnboarding() {
        UserDefaults.standard.set(true, forKey: "onboardingComplete")
        showOnboarding = false
        onboardingStep = 0
        offerShortcutTutorial()
    }

    /// The keyboard tour, once: after setup, or at the first launch that follows an update adding it.
    func offerShortcutTutorial() {
        guard tutorialDue else { return }
        // After the guide or the launch screen has faded out, and only if setup is still finished then: a relaunch
        // midway through setup reopens the guide just after the launch screen ends.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.tutorialDue, self.tourStep == nil else { return }
            self.startTour()
        }
    }

    /// Setup is wholly done: the guide finished, the runtime installed, the model downloaded and prepared.
    private var tutorialDue: Bool {
        connected && !launching && !showOnboarding && !setupNeeded
            && UserDefaults.standard.bool(forKey: "onboardingComplete") && !UserDefaults.standard.bool(forKey: TourStep.seenKey)
    }

    func startTour() { tourStep = .search }

    /// Moves the tour on when the user has just done what its current step asks.
    func tourDid(_ step: TourStep) {
        if tourStep == step { advanceTour(from: step) }
    }

    func advanceTour(from step: TourStep) {
        if let next = TourStep(rawValue: step.rawValue + 1) { tourStep = next } else { endTour() }
    }

    func endTour() {
        tourStep = nil
        UserDefaults.standard.set(true, forKey: TourStep.seenKey)
    }

    func index() async {
        guard connected, !indexing else { return }
        // Let a background update finish first; the full pass then covers anything left.
        if let liveTask { await liveTask.value }
        guard !indexing else { return }
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Index files for local search")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        error = nil
        indexing = true
        beginIndexProgress()
        defer {
            finishIndexProgress()
            indexing = false
        }
        do {
            _ = try await client.request("configure", configureArguments)
            let response = try await client.request("index")
            queueIndexProgress(response)
            flushIndexProgress()
            applyStatus(response)
            let status = try await client.request("status")
            applyStatus(status)
            let unreadable = response["failed"] as? Int ?? 0
            message = response["cancelled"] as? Bool == true ? "Indexing paused. Completed files are saved."
                : unreadable > 0 ? "Your index is up to date · \(unreadable.formatted()) \(unreadable == 1 ? "file" : "files") couldn’t be read." : "Your index is up to date."
        } catch { self.error = error.localizedDescription }
        await loadRecent()
        restartWatching()
        runPendingUpdates()
    }

    var configureArguments: [String: Any] { ["roots": roots, "skipped": skippedFolders,
                                         "fileTypes": ["code": indexCode, "data": indexData], "indexingOptions": indexingOptions] }

    func cancel() async {
        if indexing { indexStopRequested = true }
        _ = try? await client.request("cancel")
        message = "Stopping after the current model operation…"
    }

    func search() async {
        guard !searching else { return }
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Find matching local files")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        searching = true
        error = nil
        hasSearched = true
        searchGeneration += 1
        let generation = searchGeneration
        // The words searched, kept: the field may change while the search runs, and the results' marked words must
        // be the ones that found them.
        let searched = query
        do {
            // Fetch every kind at once; the view filters locally so its type counts stay accurate.
            var args: [String: Any] = ["kind": "all", "limit": 40]
            if let reference { args["path"] = reference.path }
            if !searched.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { args["text"] = searched }
            let response = try await client.request("search", args)
            // Cleared or replaced while this one ran: its results no longer belong on screen.
            guard generation == searchGeneration else { searching = false; return }
            results = BackendClient.items(in: response)
            searchedQuery = searched
            if let text = args["text"] as? String {
                let shown = results
                Task { [weak self] in
                    guard let self else { return }
                    let better = await self.refinedSnippets(for: shown, query: text)
                    // Only if the same results are still on screen.
                    guard generation == self.searchGeneration, self.results.map(\.id) == shown.map(\.id) else { return }
                    self.results = self.results.map { item in better[item.id].map { var copy = item; copy.snippet = $0.snippet; copy.location = $0.location; return copy } ?? item }
                }
            }
            searchNotice = response["message"] as? String
            message = "\(results.count) closest files · cosine similarity"
        } catch { self.error = error.localizedDescription }
        searching = false
        modelLoading = false
    }

    /// The part of each top text result's passage closest to the query, shown as its snippet.
    func refinedSnippets(for items: [SearchItem], query: String) async -> [String: (snippet: String, location: String?)] {
        let candidates = items.filter { $0.kind == "text" && $0.exact != "text" && $0.position != nil }.prefix(6)
        guard !candidates.isEmpty,
              let response = try? await client.request("refine", ["text": query, "items": candidates.map { ["id": $0.id, "path": $0.path, "position": $0.position!] }]),
              let rows = response["items"] as? [[String: Any]] else { return [:] }
        var found: [String: (snippet: String, location: String?)] = [:]
        for row in rows {
            if let id = row["id"] as? String, let snippet = row["snippet"] as? String { found[id] = (snippet, row["location"] as? String) }
        }
        return found
    }

    /// The same, for raw result rows (the command line's replies).
    func refinedRows(_ rows: [[String: Any]], query: String) async -> [[String: Any]] {
        let better = await refinedSnippets(for: BackendClient.items(in: ["items": rows]), query: query)
        return rows.map { row in
            guard let id = row["id"] as? String, let refined = better[id] else { return row }
            var copy = row
            copy["snippet"] = refined.snippet
            if let location = refined.location { copy["location"] = location }
            return copy
        }
    }

    func clearSearch() {
        searchGeneration += 1
        searchedQuery = ""
        searchNotice = nil
        query = ""
        reference = nil
        results = []
        filter = "all"
        hasSearched = false
    }

    /// The most recently modified indexed files, for the search home page.
    func loadRecent() async {
        // An emptied index (its folders removed) leaves nothing recent to show.
        if indexedCount == 0 { recent = [] }
        guard connected, indexedCount > 0,
              let response = try? await client.request("items", ["offset": 0, "limit": 2000]) else { return }
        let items = BackendClient.items(in: response)
        recent = await Task.detached(priority: .utility) {
            Array(items.compactMap { item -> (SearchItem, Date)? in
                guard let date = (try? FileManager.default.attributesOfItem(atPath: item.path))?[.modificationDate] as? Date else { return nil }
                return (item, date)
            }.sorted { $0.1 > $1.1 }.prefix(8).map(\.0))
        }.value
    }

    func quickSearch(text: String) async throws -> [SearchItem] {
        let description = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else { throw BackendFailure(message: "Enter a description of the file you want to find.") }
        return try await performQuickSearch(["text": description, "limit": 10, "kind": "all"])
    }

    func quickSearch(similarTo path: String) async throws -> [SearchItem] {
        try await performQuickSearch(["path": path, "limit": 10, "kind": "all"])
    }

    private func performQuickSearch(_ arguments: [String: Any]) async throws -> [SearchItem] {
        do {
            guard !installing else {
                throw BackendFailure(message: "The local runtime is being installed. Wait for setup to finish, then search again.")
            }
            let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Find local files from the floating search bar")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            if let connectionTask { await connectionTask.value }
            if !connected { await connect() }
            guard connected else {
                throw BackendFailure(message: error ?? "Connect the local runtime in DocuFind Settings first.")
            }
            guard dependenciesReady else {
                throw BackendFailure(message: "Install the model runtime in DocuFind Settings before searching.")
            }
            let response = try await client.request("search", arguments)
            guard let rawItems = response["items"] else {
                throw BackendFailure(message: "The local search worker returned an invalid result. Reconnect in DocuFind Settings.")
            }
            let data = try JSONSerialization.data(withJSONObject: rawItems)
            return try JSONDecoder().decode([SearchItem].self, from: data)
        } catch {
            self.error = error.localizedDescription
            throw error
        }
    }

    func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = "Add folders or mounted volumes to your local search index."
        if panel.runModal() == .OK {
            for url in panel.urls where !roots.contains(url.path) { roots.append(url.path) }
            saveSettings()
            restartWatching()
        }
    }

    func removeRoot(_ root: String) async {
        guard !indexing else { return }
        do {
            _ = try await client.request("remove_root", ["path": root])
            roots.removeAll { $0 == root }
            saveSettings()
            restartWatching()
            applyStatus(try await client.request("status"))
        } catch { self.error = error.localizedDescription }
    }

    func chooseReference() {
        let panel = NSOpenPanel()
        panel.message = "Choose a photo, recording or document to find files with a similar meaning."
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { reference = panel.url }
    }

    func choosePython() {
        let panel = NSOpenPanel()
        panel.message = "Choose the Python executable from your DocuFind runtime."
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url { python = url.path }
    }

    func saveSettings() {
        UserDefaults.standard.set(roots, forKey: "roots")
        UserDefaults.standard.set(skippedFolders, forKey: "skippedFolders")
    }

    /// Everything the first index needs: the runtime, then the search model if it is still missing.
    func setUp() async {
        if !dependenciesReady { await installRuntime() }
        if dependenciesReady && (!modelDownloaded || !modelPrepared) { await downloadModel() }
    }

    /// Downloads the search model ahead of the first index, with progress.
    func downloadModel() async {
        guard connected, dependenciesReady, !modelDownloaded || !modelPrepared, !downloadingModel, !indexing else { return }
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Download the search model")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        downloadingModel = true
        error = nil
        do { applyStatus(try await client.request("download_model")) } catch { self.error = error.localizedDescription }
        downloadingModel = false
    }

    func installRuntime() async {
        guard !installing, !indexing, let backend = Bundle.main.resourceURL?.appendingPathComponent("backend") else { return }
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Install the local model runtime")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        installing = true
        error = nil
        message = "Installing the local runtime…"
        runtimeProgress = 0
        runtimeStep = "Starting…"
        let installation = Process()
        installation.executableURL = URL(fileURLWithPath: "/bin/bash")
        installation.arguments = [backend.appendingPathComponent("setup.sh").path]
        var env = ProcessInfo.processInfo.environment
        let venv = dataDirectory.appendingPathComponent("venv").path
        env["DOCUFIND_VENV_DIR"] = venv
        if !python.contains("/venv/") { env["DOCUFIND_PYTHON"] = python }
        env["PIP_CACHE_DIR"] = dataDirectory.appendingPathComponent("pip-cache").path
        // The model downloads alongside the packages, into the cache the worker reads.
        env["DOCUFIND_MODEL_CACHE"] = dataDirectory.appendingPathComponent("models").path
        installation.environment = env
        let output = Pipe()
        installation.standardOutput = output
        installation.standardError = output
        let lines = LineBuffer()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let complete = lines.append(handle.availableData)
            guard !complete.isEmpty else { return }
            Task { @MainActor in self?.setupOutput(complete) }
        }
        do {
            let exitCode: Int32 = try await withCheckedThrowingContinuation { continuation in
                installation.terminationHandler = { child in continuation.resume(returning: child.terminationStatus) }
                do { try installation.run() } catch { continuation.resume(throwing: error) }
            }
            output.fileHandleForReading.readabilityHandler = nil
            if exitCode != 0 {
                let reason = logs.split(separator: "\n").last { $0.contains("free space") || $0.contains("did not complete") }
                throw BackendFailure(message: reason.map(String.init) ?? "Runtime setup failed. Check your internet connection and the details below, then try again.")
            }
            python = venv + "/bin/python"
            await connect()
        } catch { self.error = error.localizedDescription }
        installing = false
    }

    /// Lines from setup.sh: progress markers update the install display, the rest goes to the diagnostics log.
    private func setupOutput(_ lines: [String]) {
        var text = ""
        for line in lines {
            let fields = line.split(separator: " ", maxSplits: 3).map(String.init)
            if fields.count >= 3, fields[0] == "::docufind" {
                if fields[1] == "runtime", let fraction = Double(fields[2]) {
                    runtimeProgress = fraction
                    runtimeStep = fields.count > 3 ? fields[3] : ""
                } else if fields[1] == "model", fields.count == 4, let received = Int64(fields[2]), let total = Int64(fields[3]) {
                    updateDownload(received: received, total: total)
                }
            } else {
                text += line + "\n"
            }
        }
        if !text.isEmpty { logs = String((logs + text).suffix(16000)) }
    }

    private func updateDownload(received: Int64, total: Int64) {
        if modelDownload == nil { modelDownload = ModelDownload(total: total, firstBytes: received) }
        modelDownload?.update(received: received)
        if received >= total { modelDownloaded = true }
    }

    func applyStatus(_ response: [String: Any]) {
        if let count = response["indexedCount"] as? Int { indexedCount = count }
        if let folders = response["largeFolders"] as? [[String: Any]] { largeFolders = LargeFolder.list(folders) }
        if let skipped = response["autoSkipped"] as? [String: Int] { autoSkipped = skipped }
        if let options = response["indexingOptions"] as? [String: Bool] { indexingOptions = options }
        if let kinds = response["kindCounts"] as? [String: Int] { kindCounts = kinds }
        if let count = response["staleIndexCount"] as? Int { staleIndexCount = count }
        if let downloaded = response["modelDownloaded"] as? Bool { modelDownloaded = downloaded }
        if let prepared = response["modelPrepared"] as? Bool { modelPrepared = prepared }
        if let missing = response["missingDependencies"] as? [String] { dependenciesReady = missing.isEmpty }
        if let ready = response["ready"] as? Bool { dependenciesReady = ready }
    }

    private func progress(_ event: [String: Any]) {
        if event["stage"] as? String == "download", let received = event["receivedBytes"] as? Int64 ?? (event["receivedBytes"] as? Int).map(Int64.init),
           let total = event["totalBytes"] as? Int64 ?? (event["totalBytes"] as? Int).map(Int64.init) {
            updateDownload(received: received, total: total)
        }
        if let folders = event["largeFolders"] as? [[String: Any]] { largeFolders = LargeFolder.list(folders) }
        if let skipped = event["autoSkipped"] as? [String: Int] { autoSkipped = skipped }
        if let stage = event["stage"] as? String, stage != "warning" {
            let loading = stage == "model"
            if modelLoading != loading {
                modelLoading = loading
                if loading { modelPreparation = nil }
            }
            if loading, let fraction = (event["progress"] as? NSNumber)?.doubleValue {
                modelPreparation = PreparationProgress(start: fraction, share: (event["share"] as? NSNumber)?.doubleValue ?? 0,
                                                       pace: (event["pace"] as? NSNumber)?.doubleValue ?? 0, since: Date())
                if let part = event["part"] as? String, modelPreparationPart != part { modelPreparationPart = part }
            }
        }
        if indexing { queueIndexProgress(event) }
        else if liveUpdating { return }
        else {
            if let message = event["message"] as? String, self.message != message { self.message = message }
            if let count = event["indexedCount"] as? Int, indexedCount != count { indexedCount = count }
        }
    }

    private func beginIndexProgress() {
        indexingProgress = IndexingProgress()
        indexingStartedAt = Date()
        indexingCompletedFiles = 0
        indexingSummary = "Counting files…"
        indexingFraction = nil
        indexStopRequested = false
        pendingIndexProgress = [:]
        pendingIndexMessage = nil
        indexingTicker?.cancel()
        indexingTicker = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 250_000_000) }
                catch { return }
                guard let self, self.indexing else { return }
                self.flushIndexProgress()
            }
        }
    }

    private func queueIndexProgress(_ event: [String: Any]) {
        for key in ["processed", "unchanged", "failed", "scanned", "indexMetrics", "indexedCount"] {
            if let value = event[key] { pendingIndexProgress[key] = value }
        }
        if let value = event["message"] as? String { pendingIndexMessage = value }
    }

    private func flushIndexProgress() {
        guard let started = indexingStartedAt else { return }
        indexingProgress.update(pendingIndexProgress, elapsed: Date().timeIntervalSince(started))
        if let count = pendingIndexProgress["indexedCount"] as? Int, indexedCount != count { indexedCount = count }
        pendingIndexProgress.removeAll(keepingCapacity: true)
        if let next = pendingIndexMessage, !indexStopRequested, message != next { message = next }
        pendingIndexMessage = nil
        if indexingCompletedFiles != indexingProgress.completedFiles { indexingCompletedFiles = indexingProgress.completedFiles }
        let summary = indexingProgress.summary
        if indexingSummary != summary { indexingSummary = summary }
        if indexingFraction != indexingProgress.fraction { indexingFraction = indexingProgress.fraction }
    }

    private func finishIndexProgress() {
        indexingTicker?.cancel()
        indexingTicker = nil
        flushIndexProgress()
        indexingStartedAt = nil
    }
}

/// Settings and data saved under earlier names: the app was called OmniFind (com.bidirlm.OmniFind, then
/// com.theodeschampsberger.OmniFind) and then Magnifind (com.theodeschampsberger.Magnifind).
enum LegacySettings {
    /// Newest first: a setting saved under several names is taken from the latest one.
    static let oldDomains = ["com.theodeschampsberger.Magnifind", "com.theodeschampsberger.OmniFind", "com.bidirlm.OmniFind"]
    /// Folder names, newest first.
    static let folderNames = ["DocuFind", "Magnifind", "OmniFind"]

    /// A "DocuFindLocal" folder beside the app, else Application Support/DocuFind. When those don't
    /// exist yet but ones from an earlier name do, the existing folder is used where it is: it holds the
    /// model, runtime and index, and moving it would break the runtime's paths.
    static func dataDirectory(beside app: URL) -> String {
        let files = FileManager.default
        let folder = app.deletingLastPathComponent()
        let support = NSHomeDirectory() + "/Library/Application Support/"
        for name in folderNames where files.fileExists(atPath: folder.appendingPathComponent(name + "Local").path) {
            return folder.appendingPathComponent(name + "Local").path
        }
        for name in folderNames where files.fileExists(atPath: support + name) { return support + name }
        return support + "DocuFind"
    }

    private static var done = false

    /// Copies them over once. The login item is left out so it registers under the new identifier.
    static func migrate() {
        guard !done else { return }
        done = true
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "legacySettingsMigrated") else { return }
        defaults.set(true, forKey: "legacySettingsMigrated")
        for domain in oldDomains {
            guard let old = defaults.persistentDomain(forName: domain) else { continue }
            for (key, value) in old where key != "loginItemConfigured" && defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }
    }
}
