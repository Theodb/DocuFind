import Darwin
import Foundation

/// Serves the `docufind` command-line tool over a Unix socket in the data directory,
/// so the tool reuses the running app and its loaded model instead of starting its own.
///
/// Each connection carries one JSON line, `{"action": "search", "text": "…"}`, and
/// gets one JSON line back: the worker's result, or `{"error": "…"}`. Only the
/// current user can connect, and only a few read-mostly actions are accepted.
final class CommandServer: @unchecked Sendable {
    static let shared = CommandServer()
    static let socketName = "docufind.sock"
    private static let maximumRequestBytes = 64 * 1024
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var socketPath: String?
    private var socketInode: ino_t = 0

    /// Starts listening at `<data directory>/docufind.sock`. Problems are logged and
    /// otherwise ignored: the app works the same without the command-line tool.
    func start(dataDirectory: URL) {
        lock.lock()
        defer { lock.unlock() }
        guard listener < 0 else { return }
        let path = dataDirectory.appendingPathComponent(Self.socketName).path
        do {
            try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
            let descriptor = try Self.listen(at: path)
            var info = stat()
            socketInode = lstat(path, &info) == 0 ? info.st_ino : 0
            listener = descriptor
            socketPath = path
            let thread = Thread { [weak self] in self?.acceptConnections(on: descriptor) }
            thread.name = "DocuFind command server"
            thread.start()
        } catch {
            NSLog("DocuFind command-line server is unavailable: %@", error.localizedDescription)
        }
    }

    /// Closes the socket and removes its file, unless another process replaced it.
    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard listener >= 0 else { return }
        close(listener)
        listener = -1
        var info = stat()
        if let socketPath, lstat(socketPath, &info) == 0, info.st_ino == socketInode { unlink(socketPath) }
        socketPath = nil
    }

    private static func listen(at path: String) throws -> Int32 {
        var address = try socketAddress(path)
        var info = stat()
        if lstat(path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFSOCK else {
                throw BackendFailure(message: "\(path) exists and is not a socket.")
            }
            // A live socket means another copy of DocuFind already serves this data folder.
            if let other = try? connect(to: path) {
                close(other)
                throw BackendFailure(message: "Another DocuFind is already listening at \(path).")
            }
            unlink(path)
        }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw posixFailure("socket") }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, Darwin.listen(descriptor, 16) == 0 else {
            let failure = posixFailure("bind")
            close(descriptor)
            unlink(path)
            throw failure
        }
        return descriptor
    }

    private static func connect(to path: String) throws -> Int32 {
        var address = try socketAddress(path)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw posixFailure("socket") }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { close(descriptor); throw posixFailure("connect") }
        return descriptor
    }

    private static func socketAddress(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw BackendFailure(message: "The socket path is too long: \(path)")
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
            buffer[path.utf8.count] = 0
        }
        return address
    }

    private static func posixFailure(_ call: String) -> BackendFailure {
        BackendFailure(message: "\(call): \(String(cString: strerror(errno)))")
    }

    private func acceptConnections(on descriptor: Int32) {
        while true {
            let client = accept(descriptor, nil, nil)
            if client < 0 {
                if errno == EINTR || errno == ECONNABORTED { continue }
                return // The listener was closed.
            }
            var yes: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
            var user = uid_t(), group = gid_t()
            guard getpeereid(client, &user, &group) == 0, user == getuid() else { close(client); continue }
            DispatchQueue.global(qos: .userInitiated).async { Self.serve(client) }
        }
    }

    /// Reads one request line, answers it on the main actor, writes one reply line.
    private static func serve(_ client: Int32) {
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while request.count <= maximumRequestBytes, !request.contains(10) {
            let count = read(client, &buffer, buffer.count)
            if count <= 0 { break }
            request.append(buffer, count: count)
        }
        if let newline = request.firstIndex(of: 10) { request = request.prefix(upTo: newline) }
        Task { @MainActor in
            let reply = await Self.reply(to: request)
            DispatchQueue.global(qos: .userInitiated).async {
                reply.withUnsafeBytes { bytes in
                    var offset = 0
                    while offset < bytes.count {
                        let written = write(client, bytes.baseAddress! + offset, bytes.count - offset)
                        if written <= 0 { break }
                        offset += written
                    }
                }
                close(client)
            }
        }
    }

    @MainActor
    private static func reply(to request: Data) async -> Data {
        var payload: [String: Any]
        do {
            guard let object = try JSONSerialization.jsonObject(with: request) as? [String: Any] else {
                throw BackendFailure(message: "Each request must be a JSON object.")
            }
            payload = try await respond(to: object)
            payload.removeValue(forKey: "id")
            payload.removeValue(forKey: "event")
        } catch {
            payload = ["error": error.localizedDescription]
        }
        var data = (try? JSONSerialization.data(withJSONObject: payload))
            ?? Data(#"{"error": "DocuFind could not encode its reply."}"#.utf8)
        data.append(10)
        return data
    }

    @MainActor
    private static func respond(to request: [String: Any]) async throws -> [String: Any] {
        let action = request["action"] as? String ?? ""
        guard ["search", "status", "index", "items"].contains(action) else {
            throw BackendFailure(message: "Unsupported request: \(action.isEmpty ? "no action" : action).")
        }
        let model = AppModel.shared
        // Waits for a connection already in progress, or starts one if the app was
        // opened in the background just for this request.
        if !model.connected { await model.connect() }
        guard model.connected else {
            throw BackendFailure(message: model.error ?? "DocuFind could not start its local runtime. Open DocuFind to see why.")
        }
        if action == "status" { return try await model.client.request("status") }
        guard model.dependenciesReady else {
            throw BackendFailure(message: "The search model isn't installed yet. Open DocuFind and finish setup in Settings.")
        }
        guard !model.installing else {
            throw BackendFailure(message: "The local runtime is being installed. Wait for setup to finish, then try again.")
        }
        switch action {
        case "index":
            guard !model.indexing else { throw BackendFailure(message: "Indexing is already running in DocuFind.") }
            if let paths = request["paths"] as? [String], !paths.isEmpty {
                // Only these folders or files, the way live updates work.
                var status = try await model.indexPaths(paths)
                status["message"] = "Updated \(status["processed"] as? Int ?? 0) files; \((status["deletedPaths"] as? [Any])?.count ?? 0) removed."
                return status
            }
            // Index through the app model so the window shows progress as usual.
            await model.index()
            if let error = model.error { throw BackendFailure(message: error) }
            var status = try await model.client.request("status")
            status["message"] = model.message
            return status
        case "items":
            return try await model.client.request("items", [
                "offset": max(0, request["offset"] as? Int ?? 0),
                "limit": min(max(1, request["limit"] as? Int ?? 500), 2000)
            ])
        default:
            guard !model.indexing else {
                throw BackendFailure(message: "Indexing is running. Wait for it to finish or stop it in DocuFind, then search again.")
            }
            var arguments: [String: Any] = [
                "kind": request["kind"] as? String ?? "all",
                "limit": min(max(1, request["limit"] as? Int ?? 10), 100)
            ]
            if let text = request["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                arguments["text"] = text
            }
            if let path = request["path"] as? String, !path.isEmpty { arguments["path"] = path }
            guard arguments["text"] != nil || arguments["path"] != nil else {
                throw BackendFailure(message: "Give a description or a file to search with.")
            }
            var response = try await model.client.request("search", arguments)
            // Show the closest part of each text passage, as the app does.
            if let text = arguments["text"] as? String, let rows = response["items"] as? [[String: Any]] {
                response["items"] = await model.refinedRows(rows, query: text)
            }
            return response
        }
    }
}
