import Foundation

@main
struct ProgressTests {
    static func main() {
        // Setup output: lines split across reads come out whole, and an unfinished line waits for the rest.
        let lines = LineBuffer()
        precondition(lines.append(Data("::docufind runtime 0.1 Fin".utf8)).isEmpty)
        precondition(lines.append(Data("ding Python…\n::docufind model 5 10\npart".utf8)) == ["::docufind runtime 0.1 Finding Python…", "::docufind model 5 10"])
        precondition(lines.append(Data("ial\n".utf8)) == ["partial"])

        // The model download: no time estimate until a few seconds in, then one from the speed so far.
        let start = Date(timeIntervalSince1970: 0)
        var download = ModelDownload(total: 4_900_000_000, firstBytes: 0, startedAt: start)
        download.update(received: 100_000_000)
        precondition(download.detail(now: start.addingTimeInterval(2)) == "0.1 of 4.9 GB")
        // 100 MB in 10 s leaves 4.8 GB at 10 MB/s: 480 s, so 8 minutes.
        precondition(download.detail(now: start.addingTimeInterval(10)) == "0.1 of 4.9 GB · about 8 min left")
        download.update(received: 50)  // Never goes backwards.
        precondition(download.received == 100_000_000 && abs(download.fraction - 100.0 / 4900) < 1e-9)
        download.update(received: 4_890_000_000)
        precondition(download.detail(now: start.addingTimeInterval(489)) == "4.9 of 4.9 GB · less than a minute left")
        download.update(received: 9_000_000_000)  // Capped at the total.
        precondition(download.finished && download.fraction == 1 && download.detail(now: start.addingTimeInterval(500)) == "4.9 of 4.9 GB")
        // Resuming: the bytes already there don't count toward the speed.
        var resumed = ModelDownload(total: 4_900_000_000, firstBytes: 4_000_000_000, startedAt: start)
        resumed.update(received: 4_090_000_000)
        precondition(resumed.detail(now: start.addingTimeInterval(9)) == "4.1 of 4.9 GB · about 2 min left")

        var progress = IndexingProgress()
        progress.update(["processed": 3, "unchanged": 7, "scanned": 11, "failed": 1], elapsed: 30)
        precondition(progress.completedFiles == 3 && progress.unchangedFiles == 7 && progress.failedFiles == 1)
        precondition(progress.summary.contains("saved this run") && progress.summary.contains("files/min"))
        // A file that failed is reported as unreadable, not as deliberately skipped.
        precondition(progress.summary.contains("1 couldn’t be read") && !progress.summary.contains("skipped"))
        progress.update(["processed": 0, "indexMetrics": ["completedFiles": 4, "embeddedChunks": 60, "elapsedSeconds": 60.0] as [String: Any]], elapsed: 50)
        precondition(progress.completedFiles == 4 && progress.embeddedChunks == 60 && progress.elapsedSeconds == 60)
        precondition(progress.summary.contains("60 passages") && progress.summary.contains("passages/min"))
        precondition(!progress.summary.contains("remaining") && !progress.summary.contains("%"))
        progress.update(["processed": -1, "indexMetrics": ["embeddedChunks": -2, "elapsedSeconds": Double.nan] as [String: Any]], elapsed: .infinity)
        precondition(progress.completedFiles == 4 && progress.embeddedChunks == 60 && progress.elapsedSeconds == 60)
        var beginning = IndexingProgress()
        beginning.update(["processed": 1], elapsed: 0.001)
        precondition(!beginning.summary.contains("/min"))

        var planned = IndexingProgress()
        planned.update(["stage": "plan", "totalFiles": 400, "filesToProcess": 100], elapsed: 2)
        precondition(planned.fraction == 0 && planned.summary.contains("0 of 100 files") && planned.summary.contains("estimating"))
        planned.update(["processed": 1], elapsed: 10)
        planned.update(["processed": 11], elapsed: 30)
        precondition(planned.fraction == 0.11 && planned.summary.contains("11 of 100 files"))
        // 10 files took 20 s after the first, so 89 left take about 178 s, or 3 min.
        precondition(planned.remainingSeconds.map { abs($0 - 178) < 0.5 } == true && planned.summary.contains("about 3 min left"))
        var upToDate = IndexingProgress()
        upToDate.update(["stage": "plan", "totalFiles": 50, "filesToProcess": 0], elapsed: 1)
        precondition(upToDate.fraction == nil && upToDate.summary.contains("All 50 files are up to date"))

        // Preparation: a step starting at 20% with a 10% share, at a pace of 500 s for the whole, expects 50 s.
        let begun = Date(timeIntervalSince1970: 1000)
        let step = PreparationProgress(start: 0.2, share: 0.1, pace: 500, since: begun)
        precondition(step.fraction(at: begun) == 0.2)
        precondition(abs(step.fraction(at: begun.addingTimeInterval(25)) - 0.25) < 1e-9)       // halfway through the step
        precondition(abs(step.fraction(at: begun.addingTimeInterval(500)) - 0.295) < 1e-9)     // a slow Mac: holds short of 0.3
        let next = PreparationProgress(start: 0.3, share: 0.1, pace: 600, since: begun.addingTimeInterval(500))
        precondition(next.fraction(at: begun.addingTimeInterval(500)) >= step.fraction(at: begun.addingTimeInterval(500)))
        precondition(PreparationProgress(start: 1, share: 0, pace: 500, since: begun).fraction(at: begun) == 1)
        print("Progress checks passed.")
    }
}
