import Foundation

/// Splits a process's output into whole lines; a line can arrive across several reads.
final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()

    func append(_ data: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        pending.append(data)
        guard let end = pending.lastIndex(of: 10) else { return [] }
        let complete = pending[..<end]
        pending = Data(pending[pending.index(after: end)...])
        return String(decoding: complete, as: UTF8.self).components(separatedBy: "\n")
    }
}

/// The model's one-time preparation for this Mac, as the backend reports it step by step: where the step starts,
/// its share of the bar, and the pace so far (seconds for the whole preparation). The share fills over the time
/// that pace gives it, holding just short of the step's end until the next step arrives, so the bar keeps moving
/// through each minute-long step instead of jumping from one to the next.
struct PreparationProgress: Equatable {
    let start: Double
    let share: Double
    let pace: Double
    let since: Date

    func fraction(at date: Date = Date()) -> Double {
        guard share > 0, pace > 0 else { return min(start, 1) }
        let filled = min(max(date.timeIntervalSince(since) / (share * pace), 0), 0.95)
        return min(start + share * filled, 1)
    }
}

/// The search model's download: bytes so far, and the time left at the speed seen since it started.
struct ModelDownload: Equatable {
    let total: Int64
    private(set) var received: Int64
    private let firstBytes: Int64
    private let startedAt: Date

    init(total: Int64, firstBytes: Int64, startedAt: Date = Date()) {
        self.total = total
        self.received = firstBytes
        self.firstBytes = firstBytes
        self.startedAt = startedAt
    }

    mutating func update(received: Int64) { self.received = max(self.received, min(received, total)) }

    var fraction: Double { total > 0 ? Double(received) / Double(total) : 0 }
    var finished: Bool { received >= total }

    func detail(now: Date = Date()) -> String {
        let amount = String(format: "%.1f of %.1f GB", Double(received) / 1e9, Double(total) / 1e9)
        if finished { return amount }
        let elapsed = now.timeIntervalSince(startedAt)
        let speed = Double(received - firstBytes) / max(elapsed, 0.001)
        // A few seconds in, the speed means something.
        guard elapsed >= 4, speed > 0 else { return amount }
        let left = Double(total - received) / speed
        let time = left < 60 ? "less than a minute left" : "about \(Int((left / 60).rounded(.up))) min left"
        return "\(amount) · \(time)"
    }
}
