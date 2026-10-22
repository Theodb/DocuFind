import Darwin
import Foundation

// Runs the real command server against a stand-in app model, and the real docufind
// tool against that server. Usage: command-line-tests <path to docufind>

struct BackendFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
final class StubClient {
    var requests: [(String, [String: Any])] = []
    var reply: (String, [String: Any]) throws -> [String: Any] = { _, _ in [:] }

    func request(_ action: String, _ arguments: [String: Any] = [:]) async throws -> [String: Any] {
        requests.append((action, arguments))
        var result = try reply(action, arguments)
        result["id"] = "worker-id"
        result["event"] = "result"
        return result
    }
}

@MainActor
final class AppModel {
    static let shared = AppModel()
    let client = StubClient()
    var connected = false
    var dependenciesReady = true
    var indexing = false
    var benchmarking = false
    var installing = false
    var error: String?
    var message = ""
    var connectCalls = 0
    var indexCalls = 0

    func connect() async {
        connectCalls += 1
        connected = true
    }

    func index() async {
        indexCalls += 1
        error = nil
        message = "Your index is up to date."
    }

    func refinedRows(_ rows: [[String: Any]], query: String) async -> [[String: Any]] { rows }

    var indexedPaths: [String] = []
    func indexPaths(_ paths: [String]) async throws -> [String: Any] {
        indexedPaths = paths
        return ["processed": paths.count, "deletedPaths": [String]()]
    }
}

struct Run { let status: Int32; let output: String; let errors: String }

func run(_ tool: String, _ arguments: [String], data: URL, in directory: URL? = nil) async -> Run {
    await Task.detached {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["DOCUFIND_DATA_DIR"] = data.path
        process.environment = environment
        if let directory { process.currentDirectoryURL = directory }
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try! process.run()
        let out = output.fileHandleForReading.readDataToEndOfFile()
        let err = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(status: process.terminationStatus, output: String(decoding: out, as: UTF8.self), errors: String(decoding: err, as: UTF8.self))
    }.value
}

/// Sends a raw line, as another program might, and returns the reply.
func rawRequest(_ line: String, socket path: String) async -> String {
    await Task.detached {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8 + [0]) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        precondition(connected == 0, "could not connect to the test socket")
        _ = line.withCString { write(descriptor, $0, strlen($0)) }
        var reply = [UInt8](repeating: 0, count: 4096)
        let count = read(descriptor, &reply, reply.count)
        close(descriptor)
        return String(decoding: reply.prefix(max(0, count)), as: UTF8.self)
    }.value
}

func check(_ condition: Bool, _ message: String, _ run: Run? = nil) {
    guard !condition else { return }
    if let run { print("status \(run.status)\nstdout:\n\(run.output)\nstderr:\n\(run.errors)") }
    fatalError(message)
}

@main
struct CommandLineTests {
    @MainActor
    static func main() async {
        let tool = CommandLine.arguments[1]
        let data = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("docufind-cli-\(getpid())")
        try? FileManager.default.removeItem(at: data)
        defer { try? FileManager.default.removeItem(at: data) }
        let model = AppModel.shared
        let socketPath = data.appendingPathComponent("docufind.sock").path

        // Usage errors never need the app.
        for arguments in [[], ["find"], ["search"], ["search", "x", "--limit", "0"], ["search", "x", "--kind", "video"],
                          ["status", "extra"], ["status", "--limit", "3"], ["similar"], ["similar", "a", "b"], ["search", "--bogus", "x"]] {
            let result = await run(tool, arguments, data: data)
            check(result.status == 2 && result.errors.hasPrefix("docufind: "), "expected a usage error for \(arguments)", result)
        }
        let help = await run(tool, ["--help"], data: data)
        check(help.status == 0 && help.output.contains("Usage: docufind"), "help", help)

        // A stale socket file left by a crash is replaced.
        try! FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let stale = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: socketPath.utf8 + [0]) }
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(stale, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        close(stale)
        check(FileManager.default.fileExists(atPath: socketPath), "stale socket set up")

        CommandServer.shared.start(dataDirectory: data)
        let mode = (try! FileManager.default.attributesOfItem(atPath: socketPath)[.posixPermissions] as! NSNumber).intValue
        check(mode == 0o600, "socket permissions are \(String(mode, radix: 8))")

        let home = NSHomeDirectory()
        model.client.reply = { action, arguments in
            guard action == "search" else { return ["indexedCount": 3] }
            if arguments["text"] as? String == "nothing" { return ["items": []] }
            if arguments["text"] as? String == "broken" { throw BackendFailure(message: "The model is out of memory.") }
            return ["items": [
                ["id": "1", "path": home + "/Documents/report.pdf", "title": "report.pdf", "kind": "text", "snippet": "…", "score": 0.91234, "location": "page 3", "page": 3, "exact": true],
                ["id": "2", "path": "/Volumes/Archive/song.wav", "title": "song.wav", "kind": "audio", "snippet": "", "score": 0.5, "location": ""]
            ]]
        }

        let search = await run(tool, ["search", "the", "plumber", "invoice", "--kind=text", "--limit", "5"], data: data)
        check(search.status == 0, "search", search)
        check(search.output == "0.912  ~/Documents/report.pdf  page 3\n0.500  /Volumes/Archive/song.wav\n", "search output", search)
        check(model.connectCalls == 1, "the server connects the model before the first request")
        let sent = model.client.requests.last!
        check(sent.0 == "search" && sent.1["text"] as? String == "the plumber invoice" && sent.1["kind"] as? String == "text" && sent.1["limit"] as? Int == 5, "search arguments \(sent.1)")

        let json = await run(tool, ["search", "\"INV-2024\" invoice", "--json"], data: data)
        let items = try! JSONSerialization.jsonObject(with: Data(json.output.utf8)) as! [[String: Any]]
        check(json.status == 0 && items.count == 2 && items[0]["page"] as? Int == 3 && items[0]["exact"] as? Bool == true, "JSON keeps unknown fields", json)
        check(model.client.requests.last!.1["text"] as? String == "\"INV-2024\" invoice", "quoted words pass through")

        let sample = data.appendingPathComponent("clip.wav")
        FileManager.default.createFile(atPath: sample.path, contents: Data())
        let similar = await run(tool, ["similar", "clip.wav", "--limit", "2"], data: data, in: data)
        check(similar.status == 0, "similar", similar)
        let similarArguments = model.client.requests.last!.1
        check(similarArguments["path"] as? String == sample.standardizedFileURL.path && similarArguments["text"] == nil, "similar sends an absolute path: \(similarArguments)")
        let missing = await run(tool, ["similar", "no-such-file.wav"], data: data, in: data)
        check(missing.status == 1 && missing.errors.contains("No such file"), "missing file", missing)

        let none = await run(tool, ["search", "nothing"], data: data)
        check(none.status == 1 && none.output.isEmpty && none.errors.contains("No matches."), "no results", none)
        let broken = await run(tool, ["search", "broken"], data: data)
        check(broken.status == 1 && broken.errors == "docufind: The model is out of memory.\n", "worker errors", broken)

        let status = await run(tool, ["status", "--json"], data: data)
        let statusObject = try! JSONSerialization.jsonObject(with: Data(status.output.utf8)) as! [String: Any]
        check(status.status == 0 && statusObject["indexedCount"] as? Int == 3 && statusObject["id"] == nil && statusObject["event"] == nil, "status", status)
        let readable = await run(tool, ["status"], data: data)
        check(readable.status == 0 && readable.output.hasPrefix("3 files indexed"), "status text", readable)

        let index = await run(tool, ["index"], data: data)
        check(index.status == 0 && model.indexCalls == 1 && index.output.contains("Your index is up to date."), "index", index)
        let folder = FileManager.default.temporaryDirectory.path
        let some = await run(tool, ["index", folder], data: data)
        check(some.status == 0 && model.indexCalls == 1 && model.indexedPaths == [URL(fileURLWithPath: folder).standardizedFileURL.path]
              && some.output.contains("Updated 1 files"), "index a folder", some)
        let missingFolder = await run(tool, ["index", "/no/such/folder"], data: data)
        check(missingFolder.status == 1 && missingFolder.errors.contains("No such file or folder"), "index a missing folder", missingFolder)
        model.indexing = true
        let busy = await run(tool, ["search", "beach"], data: data)
        check(busy.status == 1 && busy.errors.contains("Indexing is running"), "search while indexing", busy)
        model.indexing = false

        let refused = await rawRequest(#"{"action": "benchmark"}"# + "\n", socket: socketPath)
        check(refused.contains("Unsupported request: benchmark"), "actions outside the allowlist are refused: \(refused)")
        let garbage = await rawRequest("not json\n", socket: socketPath)
        check(garbage.contains("\"error\""), "malformed requests get an error: \(garbage)")

        model.connected = false
        model.dependenciesReady = false
        let notReady = await run(tool, ["search", "beach"], data: data)
        check(notReady.status == 1 && notReady.errors.contains("isn't installed"), "model not installed", notReady)

        CommandServer.shared.stop()
        check(!FileManager.default.fileExists(atPath: socketPath), "the socket is removed on stop")
        print("Command-line checks passed.")
    }
}
