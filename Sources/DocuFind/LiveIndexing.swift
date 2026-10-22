import AppKit
import CoreServices
import Foundation

/// Keeping the index current as files change.
extension AppModel {
    /// Seconds of quiet before changed files are indexed.
    static let liveQuiet: TimeInterval = 3
    static let watcherPositionKey = "fileWatcherEventId"

    func restartWatching() {
        watcher?.stop()
        watcher = nil
        guard liveUpdates, connected, dependenciesReady, indexedCount > 0 else { return }
        let folders = roots.filter { FileManager.default.fileExists(atPath: $0) }
        let home = NSHomeDirectory()
        // Resume where the last session stopped, so files moved or deleted while DocuFind was closed are caught.
        let saved = UserDefaults.standard.object(forKey: Self.watcherPositionKey) as? NSNumber
        watcher = FileWatcher(paths: folders, quiet: Self.liveQuiet,
                              ignoring: [dataDirectory.resolvingSymlinksInPath().path, dataDirectory.path, home + "/Library"],
                              since: saved.map { FSEventStreamEventId($0.uint64Value) },
                              onChange: { [weak self] paths in Task { @MainActor in self?.filesChanged(paths) } },
                              onReported: { id in
                                  // Saved once the changes are handed over; a crash before indexing them replays them.
                                  Task { @MainActor in UserDefaults.standard.set(NSNumber(value: id), forKey: AppModel.watcherPositionKey) }
                              })
        if saved == nil {
            UserDefaults.standard.set(NSNumber(value: FSEventsGetCurrentEventId()), forKey: Self.watcherPositionKey)
        }
    }

    private func filesChanged(_ paths: [String]) {
        livePending.formUnion(paths)
        runPendingUpdates()
    }

    /// Indexes the files changed since the last update, unless something else is using the worker.
    func runPendingUpdates() {
        guard !livePending.isEmpty, liveTask == nil, connected, dependenciesReady,
              !indexing, !installing else { return }
        let paths = Array(livePending)
        livePending.removeAll()
        liveTask = Task { [weak self] in
            guard let self else { return }
            self.liveUpdating = true
            defer {
                self.liveUpdating = false
                self.liveTask = nil
                self.runPendingUpdates()
            }
            do {
                let response = try await self.client.request("index_paths", ["paths": paths])
                self.applyStatus(response)
                let changed = (response["processed"] as? Int ?? 0) + ((response["deletedPaths"] as? [Any])?.count ?? 0)
                if changed > 0 { await self.loadRecent() }
            } catch {
                // Busy (a full update started), or the worker failed: try these again, after a pause, so a worker
                // that keeps failing isn't sent the same request in a tight loop.
                self.livePending.formUnion(paths)
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }
}

extension AppModel {
    /// Updates only the given folders or files, like a live update, and waits for it.
    func indexPaths(_ paths: [String]) async throws -> [String: Any] {
        if let liveTask { await liveTask.value }
        guard !indexing else { throw BackendFailure(message: "Indexing is already running in DocuFind.") }
        liveUpdating = true
        defer { liveUpdating = false }
        let response = try await client.request("index_paths", ["paths": paths])
        applyStatus(response)
        await loadRecent()
        return response
    }
}

/// A folder that holds a large share of the files to index.
struct LargeFolder: Identifiable, Hashable {
    let path: String
    let files: Int
    var id: String { path }

    static func list(_ rows: [[String: Any]]) -> [LargeFolder] {
        rows.compactMap { row in
            guard let path = row["path"] as? String, let files = row["files"] as? Int else { return nil }
            return LargeFolder(path: path, files: files)
        }
    }
}

// MARK: - Skipped folders

extension AppModel {
    /// Large folders not skipped yet.
    var suggestedSkips: [LargeFolder] {
        largeFolders.filter { folder in !skippedFolders.contains { folder.path == $0 || folder.path.hasPrefix($0 + "/") } }
    }

    /// Stops reading a folder and removes its files from the index (the files themselves are untouched).
    /// A running update stops first and starts again without it.
    func skipFolder(_ path: String) async {
        // Already covered, by this folder or one around it.
        guard !skippedFolders.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { return }
        // Recorded right away, so a second click while an update stops can't add it twice;
        // folders inside it are folded into it.
        skippedFolders.removeAll { $0.hasPrefix(path + "/") }
        skippedFolders.append(path)
        largeFolders.removeAll { $0.path == path || $0.path.hasPrefix(path + "/") }
        saveSettings()
        let wasIndexing = indexing
        if wasIndexing {
            await cancel()
            while indexing { try? await Task.sleep(nanoseconds: 200_000_000) }
        }
        do { applyStatus(try await client.request("configure", configureArguments)) }
        catch { self.error = error.localizedDescription }
        if wasIndexing { await index() }
    }

    func chooseFolderToSkip() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Skip"
        panel.message = "Choose folders DocuFind should not read."
        guard panel.runModal() == .OK else { return }
        Task { for url in panel.urls { await skipFolder(url.path) } }
    }

    func unskipFolder(_ path: String) async {
        guard !indexing else { return }
        skippedFolders.removeAll { $0 == path }
        saveSettings()
        do { applyStatus(try await client.request("configure", configureArguments)) }
        catch { self.error = error.localizedDescription }
    }
}

// MARK: - File types

extension AppModel {
    /// Turning a type off removes its files from the index now; turning it on adds them at the next update.
    func setFileType(code: Bool? = nil, data: Bool? = nil) async {
        guard !indexing else { return }
        if let code { indexCode = code; UserDefaults.standard.set(code, forKey: "indexCode") }
        if let data { indexData = data; UserDefaults.standard.set(data, forKey: "indexData") }
        do { applyStatus(try await client.request("configure", configureArguments)) }
        catch { self.error = error.localizedDescription }
        await loadRecent()
    }
}
