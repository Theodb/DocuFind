// docufind: search DocuFind's index from the terminal.
//
// The tool never loads the model itself. It sends one JSON line to the running app
// over <data directory>/docufind.sock (see Sources/DocuFind/CommandServer.swift)
// and opens the app in the background first when it isn't running.
import Darwin
import Foundation

let appIdentifier = "com.theodeschampsberger.DocuFind"
let launchTimeout: TimeInterval = 60

let usage = """
Usage: docufind <command> [options]

Search the files DocuFind has indexed, using the DocuFind app on this Mac.

Commands:
  search <description>   Find files that match a description
  similar <file>         Find files similar to an image, audio clip or document
  open <description>     Open the best match
  status                 Show what is indexed and whether the model is ready
  index [<path>…]        Update the index and wait until it finishes; with paths,
                         only those folders or files

Options:
  --kind text|image|audio  Only return files of this kind
  --limit <n>              Number of results, 1 to 100 (default 10)
  --json                   Print results as JSON
  -h, --help               Show this help
  --version                Show the version

DocuFind opens in the background if it isn't running. Exit status is 0 on
success, 1 when nothing matched or something failed, and 2 for usage errors.
"""

struct Failure: Error { let message: String; var code: Int32 = 1 }

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("docufind: \(message)\n".utf8))
    exit(code)
}

func note(_ message: String) {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
}

// MARK: - Arguments

struct Options {
    var command = ""
    var words: [String] = []
    var kind: String?
    var limit: Int?
    var json = false
}

func parse(_ arguments: [String]) throws -> Options {
    var options = Options()
    var index = 0
    var onlyWords = false
    func value(_ name: String, inline: String?) throws -> String {
        if let inline { return inline }
        index += 1
        guard index < arguments.count else { throw Failure(message: "\(name) needs a value.", code: 2) }
        return arguments[index]
    }
    while index < arguments.count {
        let argument = arguments[index]
        if onlyWords || !argument.hasPrefix("-") || argument == "-" {
            if options.command.isEmpty { options.command = argument } else { options.words.append(argument) }
        } else {
            let parts = argument.split(separator: "=", maxSplits: 1).map(String.init)
            let inline = parts.count == 2 ? parts[1] : nil
            switch parts[0] {
            case "--": onlyWords = true
            case "-h", "--help": options.command = "help"; return options
            case "--version": options.command = "version"; return options
            case "--json": options.json = true
            case "--kind":
                let kind = try value("--kind", inline: inline)
                guard ["all", "text", "image", "audio"].contains(kind) else {
                    throw Failure(message: "--kind must be text, image or audio.", code: 2)
                }
                options.kind = kind
            case "--limit":
                guard let limit = Int(try value("--limit", inline: inline)), (1...100).contains(limit) else {
                    throw Failure(message: "--limit must be a number from 1 to 100.", code: 2)
                }
                options.limit = limit
            default: throw Failure(message: "Unknown option \(argument).", code: 2)
            }
        }
        index += 1
    }
    switch options.command {
    case "":
        throw Failure(message: "Choose a command. Run docufind --help for the list.", code: 2)
    case "search", "open":
        guard !options.words.joined().trimmingCharacters(in: .whitespaces).isEmpty else {
            throw Failure(message: "Describe what to find, for example: docufind \(options.command) \"a beach at sunset\"", code: 2)
        }
    case "similar":
        guard options.words.count == 1 else { throw Failure(message: "Give exactly one file: docufind similar <file>", code: 2) }
    case "status", "index":
        guard options.words.isEmpty || options.command == "index" else { throw Failure(message: "\(options.command) takes no arguments.", code: 2) }
        guard options.kind == nil, options.limit == nil else {
            throw Failure(message: "--kind and --limit only apply to search, similar and open.", code: 2)
        }
    case "help", "version": break
    default:
        throw Failure(message: "Unknown command \(options.command). Run docufind --help for the list.", code: 2)
    }
    return options
}

// MARK: - Finding the app

/// This tool's own path with symlinks resolved, since it is usually run through a link in /usr/local/bin.
func executableURL() -> URL {
    var size: UInt32 = 0
    _NSGetExecutablePath(nil, &size)
    var buffer = [CChar](repeating: 0, count: Int(size) + 1)
    guard _NSGetExecutablePath(&buffer, &size) == 0 else { return URL(fileURLWithPath: CommandLine.arguments[0]) }
    return URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath()
}

/// The DocuFind.app this tool ships in, if any.
func appBundle() -> URL? {
    var url = executableURL().deletingLastPathComponent()
    while url.path != "/" {
        if url.pathExtension == "app" { return url }
        url.deleteLastPathComponent()
    }
    return nil
}

/// Same rule as the app: DOCUFIND_DATA_DIR, else DocuFindLocal beside the app, else Application Support,
/// using the folders of the app's earlier names (Magnifind, then OmniFind) when the new ones don't exist yet.
func dataDirectory() -> URL {
    if let custom = ProcessInfo.processInfo.environment["DOCUFIND_DATA_DIR"], !custom.isEmpty {
        return URL(fileURLWithPath: custom)
    }
    let files = FileManager.default
    if let app = appBundle() {
        for name in ["DocuFindLocal", "MagnifindLocal", "OmniFindLocal"] {
            let portable = app.deletingLastPathComponent().appendingPathComponent(name, isDirectory: true)
            if files.fileExists(atPath: portable.path) { return portable }
        }
    }
    let support = NSHomeDirectory() + "/Library/Application Support/"
    for name in ["DocuFind", "Magnifind", "OmniFind"] where files.fileExists(atPath: support + name) {
        return URL(fileURLWithPath: support + name)
    }
    return URL(fileURLWithPath: support + "DocuFind")
}

func version() -> String {
    let embedded = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    if let embedded { return embedded }
    if let app = appBundle(), let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
       let value = info["CFBundleShortVersionString"] as? String { return value }
    return "unknown"
}

// MARK: - Talking to the app

/// Connects to the app's socket. Returns nil when nothing is listening there yet.
func connect(to path: String) throws -> Int32? {
    var address = sockaddr_un()
    guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
        throw Failure(message: "The data folder path is too long for a socket: \(path)")
    }
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        buffer.copyBytes(from: path.utf8)
        buffer[path.utf8.count] = 0
    }
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw Failure(message: "Could not create a socket: \(String(cString: strerror(errno)))") }
    let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    if result == 0 {
        var yes: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        return descriptor
    }
    let reason = errno
    close(descriptor)
    if reason == ENOENT || reason == ECONNREFUSED { return nil }
    throw Failure(message: "Could not reach DocuFind at \(path): \(String(cString: strerror(reason)))")
}

/// Connects, opening DocuFind in the background and waiting for it when needed.
func connectToApp() throws -> Int32 {
    let path = dataDirectory().appendingPathComponent("docufind.sock").path
    if let descriptor = try connect(to: path) { return descriptor }
    note("Starting DocuFind…")
    let opener = Process()
    opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    // Prefer the copy this tool came with, so both use the same data folder.
    opener.arguments = appBundle().map { ["-g", $0.path] } ?? ["-g", "-b", appIdentifier]
    opener.standardOutput = FileHandle.nullDevice
    opener.standardError = FileHandle.nullDevice
    do { try opener.run() } catch { throw Failure(message: "Could not open DocuFind: \(error.localizedDescription)") }
    opener.waitUntilExit()
    guard opener.terminationStatus == 0 else {
        throw Failure(message: "Could not open DocuFind. Install it in Applications and open it once.")
    }
    let deadline = Date().addingTimeInterval(launchTimeout)
    while Date() < deadline {
        usleep(250_000)
        if let descriptor = try connect(to: path) { return descriptor }
    }
    throw Failure(message: "DocuFind did not respond within \(Int(launchTimeout)) seconds. Open it and check that setup is complete.")
}

/// Sends one request and returns the app's reply.
func send(_ request: [String: Any]) throws -> [String: Any] {
    let descriptor = try connectToApp()
    defer { close(descriptor) }
    var line = try JSONSerialization.data(withJSONObject: request)
    line.append(10)
    let sent = line.withUnsafeBytes { bytes -> Bool in
        var offset = 0
        while offset < bytes.count {
            let written = write(descriptor, bytes.baseAddress! + offset, bytes.count - offset)
            if written <= 0 { return false }
            offset += written
        }
        return true
    }
    guard sent else { throw Failure(message: "Could not send the request to DocuFind.") }
    var reply = Data()
    var buffer = [UInt8](repeating: 0, count: 65536)
    while !reply.contains(10) {
        let count = read(descriptor, &buffer, buffer.count)
        if count < 0 && errno == EINTR { continue }
        if count <= 0 { break }
        reply.append(buffer, count: count)
    }
    guard let newline = reply.firstIndex(of: 10),
          let object = try? JSONSerialization.jsonObject(with: reply.prefix(upTo: newline)) as? [String: Any] else {
        throw Failure(message: "DocuFind closed the connection without answering.")
    }
    if let error = object["error"] as? String { throw Failure(message: error) }
    return object
}

// MARK: - Output

func printJSON(_ value: Any) {
    let options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    if let data = try? JSONSerialization.data(withJSONObject: value, options: options) {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

func displayPath(_ path: String) -> String {
    let home = NSHomeDirectory()
    return path == home || path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
}

/// One line per result: score, path, and where in the file it matched.
func printResults(_ items: [[String: Any]]) {
    for item in items {
        let score = (item["score"] as? NSNumber)?.doubleValue ?? 0
        var line = String(format: "%.3f  ", score) + displayPath(item["path"] as? String ?? "")
        if let location = item["location"] as? String, !location.isEmpty { line += "  " + location }
        print(line)
    }
}

func printStatus(_ status: [String: Any]) {
    let count = (status["indexedCount"] as? NSNumber)?.intValue ?? 0
    var summary = "\(count.formatted()) files indexed"
    if let kinds = status["kindCounts"] as? [String: Any], !kinds.isEmpty {
        let parts = kinds.keys.sorted().map { "\((kinds[$0] as? NSNumber)?.intValue ?? 0) \($0)" }
        summary += " (" + parts.joined(separator: ", ") + ")"
    }
    print(summary)
    if let stale = (status["staleIndexCount"] as? NSNumber)?.intValue, stale > 0 {
        print("\(stale) files were indexed with another processing mode")
    }
    if let roots = status["roots"] as? [String], !roots.isEmpty {
        print("Folders: " + roots.map(displayPath).joined(separator: ", "))
    }
    let ready = status["ready"] as? Bool ?? false
    let loaded = status["modelReady"] as? Bool ?? false
    print("Model: " + (!ready ? "not installed" : loaded ? "loaded" : "installed, loads on first search"))
    if let device = status["device"] as? String { print("Processing: \(device)") }
    if status["indexing"] as? Bool == true { print("Indexing: running") }
    if let error = status["error"] as? String, !error.isEmpty { print("Problem: \(error)") }
}

// MARK: - Commands

func items(in reply: [String: Any]) -> [[String: Any]] { reply["items"] as? [[String: Any]] ?? [] }

func run(_ options: Options) throws -> Int32 {
    switch options.command {
    case "help":
        print(usage)
        return 0
    case "version":
        print("docufind \(version())")
        return 0
    case "status":
        let status = try send(["action": "status"])
        if options.json { printJSON(status) } else { printStatus(status) }
        return 0
    case "index":
        var request: [String: Any] = ["action": "index"]
        if !options.words.isEmpty {
            let paths = options.words.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            for path in paths where !FileManager.default.fileExists(atPath: path) { throw Failure(message: "No such file or folder: \(path)") }
            request["paths"] = paths
            note("Updating \(paths.count == 1 ? "1 location" : "\(paths.count) locations")…")
        } else {
            note("Indexing… progress also shows in DocuFind.")
        }
        let status = try send(request)
        if options.json { printJSON(status) } else {
            if let message = status["message"] as? String { print(message) }
            printStatus(status)
        }
        return 0
    default:
        var request: [String: Any] = ["action": "search", "kind": options.kind ?? "all"]
        if options.command == "similar" {
            let file = URL(fileURLWithPath: options.words[0]).standardizedFileURL
            guard FileManager.default.fileExists(atPath: file.path) else { throw Failure(message: "No such file: \(options.words[0])") }
            request["path"] = file.path
        } else {
            request["text"] = options.words.joined(separator: " ")
        }
        request["limit"] = options.command == "open" ? 1 : options.limit ?? 10
        let results = items(in: try send(request))
        if options.json { printJSON(results) }
        guard let best = results.first else {
            if !options.json { note("No matches.") }
            return 1
        }
        if options.command == "open" {
            guard let path = best["path"] as? String else { throw Failure(message: "The best match has no path.") }
            if !options.json { printResults([best]) }
            let opener = Process()
            opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            opener.arguments = [path]
            try opener.run()
            opener.waitUntilExit()
            return opener.terminationStatus == 0 ? 0 : 1
        }
        if !options.json { printResults(results) }
        return 0
    }
}

do {
    exit(try run(try parse(Array(CommandLine.arguments.dropFirst()))))
} catch let failure as Failure {
    fail(failure.message, code: failure.code)
} catch {
    fail(error.localizedDescription)
}
