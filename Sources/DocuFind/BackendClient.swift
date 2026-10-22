import Foundation

struct SearchItem: Codable, Identifiable, Sendable {
    let id: String
    let path: String
    let title: String
    let kind: String
    var snippet: String
    let score: Double
    var location: String?
    /// Which passage of the file matched, so its closest part can be shown.
    var position: Int? = nil
    /// Where the query's words appear as written: "text" (a passage, or text in a picture) or "name".
    var exact: String? = nil
    /// The words matched as written, to mark on a page.
    var matched: String? = nil
    /// Other indexed files with exactly the same content (any name), shown as one result.
    var copies: [String]? = nil
    var copyCount: Int { copies?.count ?? 0 }
    /// The PDF page of the matching passage.
    var page: Int? = nil
    /// Words read from a picture around the exact match.
    var recognizedText: String? = nil
    var isPDF: Bool { path.lowercased().hasSuffix(".pdf") }
}

struct BackendFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
final class BackendClient {
    private var process: Process?
    private var input: FileHandle?
    private var outputBuffer = Data()
    private var pending: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private var deadlines: [String: Task<Void, Never>] = [:]
    private var generation = UUID()
    var onProgress: (([String: Any]) -> Void)?
    var onLog: ((String) -> Void)?

    func start(python: String, dataDirectory: URL) throws {
        onLog?("Preparing the local worker…\n")
        stop()
        onLog?("Previous local worker stopped.\n")
        guard let backend = Bundle.main.resourceURL?.appendingPathComponent("backend/worker.py"),
              FileManager.default.fileExists(atPath: backend.path) else {
            throw BackendFailure(message: "The app's local search worker is missing. Rebuild the app using scripts/build.sh.")
        }
        let workerGeneration = generation
        let child = Process()
        child.executableURL = URL(fileURLWithPath: python)
        // Keep Python caches out of the signed application bundle.
        child.arguments = ["-B", backend.path, "--data-dir", dataDirectory.path]
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        environment["TOKENIZERS_PARALLELISM"] = "false"
        // Reads the text in pictures and scanned PDF pages.
        let recognizer = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/docufind-ocr")
        if FileManager.default.isExecutableFile(atPath: recognizer.path) { environment["DOCUFIND_OCR_HELPER"] = recognizer.path }
        child.environment = environment
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            Task { @MainActor in
                guard let self, self.generation == workerGeneration else { return }
                if data.isEmpty { self.connectionClosed() }
                else { self.receive(data) }
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
            Task { @MainActor in
                guard let self, self.generation == workerGeneration else { return }
                self.onLog?(text)
            }
        }
        child.terminationHandler = { [weak self] child in
            Task { @MainActor in
                guard let self, self.process === child else { return }
                self.failAll("The local search worker stopped. Check the runtime in Settings and reconnect.")
                self.process = nil
                try? self.input?.close()
                self.input = nil
            }
        }
        onLog?("Launching the local worker process…\n")
        try child.run()
        process = child
        input = stdin.fileHandleForWriting
        onLog?("Local worker process launched.\n")
    }

    func request(_ action: String, _ arguments: [String: Any] = [:]) async throws -> [String: Any] {
        let trace = ["configure", "status"].contains(action)
        if trace { onLog?("Preparing \(action) request.\n") }
        guard process?.isRunning == true, let input else {
            throw BackendFailure(message: "Connect the local runtime in Settings first.")
        }
        let id = UUID().uuidString
        var payload = arguments
        payload["id"] = id
        payload["action"] = action
        var bytes = try JSONSerialization.data(withJSONObject: payload)
        bytes.append(10)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            if let seconds = Self.deadlineSeconds(for: action) {
                let workerGeneration = generation
                deadlines[id] = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: seconds * 1_000_000_000) }
                    catch { return }
                    guard !Task.isCancelled, let self, self.generation == workerGeneration else { return }
                    self.expire(id: id, action: action)
                }
            }
            do {
                if trace { onLog?("Writing \(action) request.\n") }
                try input.write(contentsOf: bytes)
                if trace { onLog?("\(action) request sent; waiting for reply.\n") }
            }
            catch { finish(id: id, result: .failure(error)) }
        }
    }

    func stop() {
        let previous = process
        process = nil
        generation = UUID()
        try? input?.close()
        input = nil
        (previous?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (previous?.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        if previous?.isRunning == true { previous?.terminate() }
        outputBuffer = Data()
        failAll("The local runtime was restarted.")
    }

    private func failAll(_ message: String) {
        let timers = Array(deadlines.values)
        deadlines.removeAll()
        for timer in timers { timer.cancel() }
        let continuations = Array(pending.values)
        pending.removeAll()
        for continuation in continuations { continuation.resume(throwing: BackendFailure(message: message)) }
    }

    private static func deadlineSeconds(for action: String) -> UInt64? {
        switch action {
        case "configure", "status": 90
        default: nil
        }
    }

    private func expire(id: String, action: String) {
        onLog?("\(action) request reached its response deadline.\n")
        let message = "The local runtime took too long to respond. Reconnect in Settings and try again."
        finish(id: id, result: .failure(BackendFailure(message: message)))
    }

    private func finish(id: String, result: Result<[String: Any], Error>) {
        deadlines.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(with: result)
    }

    private func connectionClosed() {
        failAll("The local search worker closed its connection. Reconnect in Settings and try again.")
        stop()
    }

    private func receive(_ data: Data) {
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 10) {
            let line = outputBuffer.subdata(in: 0..<newline)
            outputBuffer.removeSubrange(0...newline)
            guard let payload = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = payload["id"] as? String else { continue }
            switch payload["event"] as? String {
            case "progress": onProgress?(payload)
            case "error": finish(id: id, result: .failure(BackendFailure(message: payload["message"] as? String ?? "Local search failed.")))
            case "result": finish(id: id, result: .success(payload))
            default: break
            }
        }
    }

    static func items(in response: [String: Any]) -> [SearchItem] {
        guard let items = response["items"], let data = try? JSONSerialization.data(withJSONObject: items) else { return [] }
        return (try? JSONDecoder().decode([SearchItem].self, from: data)) ?? []
    }
}
