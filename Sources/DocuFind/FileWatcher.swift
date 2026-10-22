import CoreServices
import Foundation

/// Watches folders with FSEvents and reports the changed paths in batches,
/// once things have been quiet for a moment.
final class FileWatcher {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "DocuFind file watcher")
    private var pending = Set<String>()
    private var flush: DispatchWorkItem?
    private var firstPendingAt: Date?
    private let ignoredPrefixes: [String]
    private let quiet: TimeInterval
    private let onChange: @Sendable ([String]) -> Void
    private let onReported: @Sendable (FSEventStreamEventId) -> Void
    private var latestEventId: FSEventStreamEventId = 0

    /// - Parameters:
    ///   - quiet: How long to wait after the last change before reporting.
    ///   - ignoring: Folders whose changes never matter, such as the index's own folder.
    ///   - since: Replays changes made after this event, such as while the app was closed. Nil starts from now.
    ///   - onReported: Called with the last event reported to `onChange`, to save as the next `since`.
    init(paths: [String], quiet: TimeInterval, ignoring: [String], since: FSEventStreamEventId? = nil,
         onChange: @escaping @Sendable ([String]) -> Void, onReported: @escaping @Sendable (FSEventStreamEventId) -> Void = { _ in }) {
        self.quiet = quiet
        self.onChange = onChange
        self.onReported = onReported
        ignoredPrefixes = ignoring.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        guard !paths.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, ids in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            let latest = (0..<count).map { ids[$0] }.max() ?? 0
            watcher.received(Array(list.prefix(count)), latest: latest)
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                                             | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagIgnoreSelf)
        stream = FSEventStreamCreate(nil, callback, &context, paths as CFArray,
                                     since ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, flags)
        if let stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
        }
    }

    deinit { stop() }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        queue.sync { flush?.cancel() }
    }

    /// Runs on the watcher's queue.
    private func received(_ paths: [String], latest: FSEventStreamEventId) {
        latestEventId = max(latestEventId, latest)
        let relevant = paths.filter { path in
            !ignoredPrefixes.contains { path.hasPrefix($0) || path + "/" == $0 }
                && !path.split(separator: "/").contains { $0.hasPrefix(".") }
        }
        guard !relevant.isEmpty else { return }
        pending.formUnion(relevant)
        if firstPendingAt == nil { firstPendingAt = Date() }
        flush?.cancel()
        // Wait for quiet, but don't hold changes back for ever while something keeps writing.
        let waited = Date().timeIntervalSince(firstPendingAt ?? Date())
        let delay = waited > quiet * 6 ? 0 : quiet
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.pending.isEmpty else { return }
            let batch = Self.collapse(Array(self.pending))
            self.pending.removeAll()
            self.firstPendingAt = nil
            self.onChange(batch)
            self.onReported(self.latestEventId)
        }
        flush = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Drops paths inside another reported folder, and caps the batch: a huge change
    /// becomes its common parent folders.
    static func collapse(_ paths: [String]) -> [String] {
        let sorted = Set(paths).sorted()
        var kept: [String] = []
        for path in sorted where !kept.contains(where: { path.hasPrefix($0 + "/") }) { kept.append(path) }
        guard kept.count > 500 else { return kept }
        return Array(Set(kept.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path })).sorted()
    }
}
