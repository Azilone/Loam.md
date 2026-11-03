import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// How `loam app` reaches the running app: a Unix socket per open vault, private to the user (0600 in a 0700 folder
/// of `/tmp`), one JSON line per request and per answer. The app serves it while a vault is open (any build, unlike
/// the debug channel of agent test instances); the CLI only ever asks for what a person could do in the window.
public enum AppChannel {
    public struct Request: Codable, Equatable, Sendable {
        /// `info`, `open`, `run`, `shot`, `switch` or `relaunch`.
        public var action: String
        /// `open`: a note's vault path; `run`: a command id; `shot`: the PNG's path; `switch`: the other vault's
        /// folder.
        public var target: String?
        public var arguments: [String: String]

        public init(action: String, target: String? = nil, arguments: [String: String] = [:]) {
            self.action = action
            self.target = target
            self.arguments = arguments
        }
    }

    public struct Response: Codable, Equatable, Sendable {
        public var ok: Bool
        public var output: String
        public var error: String?

        public init(ok: Bool, output: String = "", error: String? = nil) {
            self.ok = ok
            self.output = output
            self.error = error
        }

        public static func failure(_ message: String) -> Response { Response(ok: false, error: message) }
    }

    /// The folder of the sockets: one per user, short enough for a socket path.
    public static var folder: String { "/tmp/loam-\(getuid())" }

    /// The socket of the app with `vault` open.
    public static func socketPath(vault: URL) -> String {
        "\(folder)/\(fingerprint(vault.standardizedFileURL.resolvingSymlinksInPath().path)).sock"
    }

    /// Where the app writes the vault it opened last, so `loam app` works from anywhere.
    public static var lastVaultFile: String { "\(folder)/last-vault" }

    /// A stable, short name for a path (FNV-1a, 64 bits, in hex).
    static func fingerprint(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    /// Sends one request to the app of `vault` and returns its answer.
    public static func send(_ request: Request, vault: URL, timeout: TimeInterval = 30) throws -> Response {
        let path = socketPath(vault: vault)
        let descriptor = socket(AF_UNIX, Int32(SOCK_STREAM.rawValueCompat), 0)
        guard descriptor >= 0 else { throw CLIError.usage("socket(): \(String(cString: strerror(errno)))") }
        defer { close(descriptor) }
        var address = Self.address(path)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            throw CLIError.usage("Loam is not running with the vault \(vault.path) open: open it in the app first "
                + "(`open -a Loam`).")
        }
        var time = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
        let data = try JSONEncoder().encode(request) + Data([0x0A])
        guard write(data, to: descriptor) else { throw CLIError.usage("The app closed the connection.") }
        guard let line = readLine(descriptor) else { throw CLIError.usage("The app did not answer.") }
        return try JSONDecoder().decode(Response.self, from: line)
    }

    static func address(_ path: String) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in path.utf8.enumerated() where index < buffer.count - 1 { buffer[index] = byte }
        }
        return address
    }

    static func write(_ data: Data, to descriptor: Int32) -> Bool {
        var offset = 0
        return data.withUnsafeBytes { buffer in
            while offset < data.count {
                let written = Darwin_send(descriptor, buffer.baseAddress! + offset, data.count - offset)
                if written <= 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += written
            }
            return true
        }
    }

    static func readLine(_ descriptor: Int32) -> Data? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) { return Data(buffer[buffer.startIndex..<newline]) }
            let count = recv(descriptor, &chunk, chunk.count, 0)
            if count < 0, errno == EINTR { continue }
            if count <= 0 { return buffer.isEmpty ? nil : buffer }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }
}

/// The app's side: listens on the vault's socket and hands each request to `handler` (which the app runs on the main
/// actor). One thread accepts; each connection gets its own.
public final class AppChannelServer: @unchecked Sendable {
    public typealias Handler = @Sendable (AppChannel.Request) async -> AppChannel.Response

    public let path: String
    private let handler: Handler
    private var listener: Int32 = -1
    private let lock = NSLock()
    private var stopped = false

    public init(vault: URL, handler: @escaping Handler) {
        path = AppChannel.socketPath(vault: vault)
        self.handler = handler
    }

    public func start() throws {
        try FileManager.default.createDirectory(
            atPath: AppChannel.folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        chmod(AppChannel.folder, 0o700)
        unlink(path)
        let descriptor = socket(AF_UNIX, Int32(SOCK_STREAM.rawValueCompat), 0)
        guard descriptor >= 0 else { throw CLIError.usage("socket(): \(String(cString: strerror(errno)))") }
        var address = AppChannel.address(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(descriptor, 8) == 0 else {
            let reason = String(cString: strerror(errno))
            close(descriptor)
            throw CLIError.usage("Cannot listen on \(path): \(reason)")
        }
        chmod(path, 0o600)
        listener = descriptor
        let thread = Thread { [self] in acceptLoop(descriptor) }
        thread.name = "loam-app-channel"
        thread.start()
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        stopped = true
        if listener >= 0 {
            shutdown(listener, Int32(SHUT_RDWR))
            close(listener)
        }
        unlink(path)
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func acceptLoop(_ descriptor: Int32) {
        while !isStopped {
            let connection = accept(descriptor, nil, nil)
            if connection < 0 {
                if isStopped || errno != EINTR { return }
                continue
            }
            #if canImport(Darwin)
            var on: Int32 = 1
            setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            #endif
            let thread = Thread { [self] in serve(connection) }
            thread.start()
        }
    }

    private func serve(_ connection: Int32) {
        defer { close(connection) }
        guard let line = AppChannel.readLine(connection) else { return }
        let response: AppChannel.Response
        if let request = try? JSONDecoder().decode(AppChannel.Request.self, from: line) {
            let box = Box()
            let handler = handler
            Task { box.fulfil(await handler(request)) }
            response = box.wait()
        } else {
            response = .failure("Not a request.")
        }
        let data = ((try? JSONEncoder().encode(response)) ?? Data()) + Data([0x0A])
        _ = AppChannel.write(data, to: connection)
    }

    private final class Box: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)
        private var value = AppChannel.Response.failure("No answer.")
        func fulfil(_ response: AppChannel.Response) {
            value = response
            semaphore.signal()
        }
        func wait() -> AppChannel.Response {
            semaphore.wait()
            return value
        }
    }
}

// The few spellings that differ between Darwin and Glibc.
#if canImport(Darwin)
private extension Int32 {
    var rawValueCompat: Int32 { self }
}
private func Darwin_send(_ descriptor: Int32, _ pointer: UnsafeRawPointer, _ count: Int) -> Int {
    send(descriptor, pointer, count, 0)
}
#else
private extension __socket_type {
    var rawValueCompat: UInt32 { rawValue }
}
private func Darwin_send(_ descriptor: Int32, _ pointer: UnsafeRawPointer, _ count: Int) -> Int {
    send(descriptor, pointer, count, Int32(MSG_NOSIGNAL))
}
#endif
