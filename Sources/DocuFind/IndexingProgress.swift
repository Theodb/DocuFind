import Foundation

/// Content-free counters. Once the backend's quick pre-count arrives, progress is
/// "done of planned" with a time estimate from the observed pace; before that, plain counters.
struct IndexingProgress {
    private(set) var completedFiles = 0
    private(set) var unchangedFiles = 0
    private(set) var failedFiles = 0
    private(set) var scannedFiles = 0
    private(set) var embeddedChunks = 0
    private(set) var elapsedSeconds: Double = 0
    /// Supported files found by the pre-count, and how many of them are new or changed.
    private(set) var totalFiles: Int?
    private(set) var filesToProcess: Int?
    /// When the first file finished; the pace is measured from there, after model loading.
    private var firstDoneAt: Double?

    mutating func update(_ event: [String: Any], elapsed: Double) {
        let metrics = event["indexMetrics"] as? [String: Any] ?? [:]
        completedFiles = max(completedFiles, integer(metrics["completedFiles"] ?? event["processed"]))
        unchangedFiles = max(unchangedFiles, integer(metrics["unchangedFiles"] ?? event["unchanged"]))
        failedFiles = max(failedFiles, integer(metrics["failedFiles"] ?? event["failed"]))
        scannedFiles = max(scannedFiles, integer(event["scanned"]))
        embeddedChunks = max(embeddedChunks, integer(metrics["embeddedChunks"]))
        let reported = metrics["elapsedSeconds"] as? Double ?? 0
        elapsedSeconds = max(elapsedSeconds, max(elapsed.isFinite ? max(0, elapsed) : 0,
                                                reported.isFinite ? max(0, reported) : 0))
        if let total = (event["totalFiles"] ?? metrics["totalFiles"]) as? Int, total >= 0 { totalFiles = total }
        if let planned = (event["filesToProcess"] ?? metrics["filesToProcess"]) as? Int, planned >= 0 { filesToProcess = planned }
        if firstDoneAt == nil, doneFiles > 0 { firstDoneAt = elapsedSeconds }
    }

    private var doneFiles: Int { completedFiles + failedFiles }

    /// Share of the planned work that is done, once the pre-count is known.
    var fraction: Double? {
        guard let planned = filesToProcess, planned > 0 else { return nil }
        return min(1, Double(doneFiles) / Double(planned))
    }

    /// Seconds left at the pace observed since the first file finished; nil until that pace is meaningful.
    var remainingSeconds: Double? {
        guard let planned = filesToProcess, let start = firstDoneAt, doneFiles >= 3 else { return nil }
        let span = elapsedSeconds - start
        guard span >= 15 else { return nil }
        let perFile = span / Double(doneFiles - 1)
        return max(0, Double(planned - doneFiles)) * perFile
    }

    var summary: String {
        if let planned = filesToProcess, let total = totalFiles {
            if planned == 0 { return "All \(total.formatted()) files are up to date · \(duration) elapsed" }
            var parts = ["\(min(doneFiles, planned).formatted()) of \(planned.formatted()) files"]
            if failedFiles > 0 { parts.append("\(failedFiles.formatted()) couldn’t be read") }
            if let remaining = remainingSeconds { parts.append(Self.estimate(remaining)) }
            else if doneFiles < planned { parts.append("estimating time…") }
            parts.append("\(duration) elapsed")
            return parts.joined(separator: " · ")
        }
        var parts = ["\(completedFiles.formatted()) saved this run"]
        if unchangedFiles > 0 { parts.append("\(unchangedFiles.formatted()) unchanged") }
        if failedFiles > 0 { parts.append("\(failedFiles.formatted()) couldn’t be read") }
        if embeddedChunks > 0 {
            parts.append("\(embeddedChunks.formatted()) passages")
            if elapsedSeconds >= 5 { parts.append("\(rate(embeddedChunks)) passages/min") }
        } else if completedFiles > 0, elapsedSeconds >= 5 {
            parts.append("\(rate(completedFiles)) files/min")
        } else if scannedFiles > completedFiles + unchangedFiles + failedFiles {
            parts.append("\(scannedFiles.formatted()) checked")
        }
        parts.append("\(duration) elapsed")
        return parts.joined(separator: " · ")
    }

    private static func estimate(_ seconds: Double) -> String {
        if seconds < 60 { return "less than a minute left" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "about \(minutes) min left" }
        return "about \(minutes / 60) h \(minutes % 60) min left"
    }

    private func integer(_ value: Any?) -> Int {
        guard let value = value as? Int, value >= 0 else { return 0 }
        return value
    }

    private func rate(_ count: Int) -> String {
        (Double(count) * 60 / max(1, elapsedSeconds)).formatted(.number.precision(.fractionLength(0...1)))
    }

    private var duration: String {
        let seconds = Int(min(elapsedSeconds, Double(Int.max / 2)))
        if seconds >= 3600 { return "\(seconds / 3600)h \((seconds / 60) % 60)m" }
        if seconds >= 60 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds)s"
    }
}
