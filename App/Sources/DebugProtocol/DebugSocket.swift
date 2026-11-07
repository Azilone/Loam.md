// The server and client exist only where the channel does: debug builds, or `-DLOAM_AGENT_BRIDGE` (see AgentInstance).
#if DEBUG || LOAM_AGENT_BRIDGE
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A Unix socket server speaking one JSON line per message: each request line gets exactly one response line, in
/// order, per connection. The handler runs wherever it likes (the app's hands it to the main actor).
///
/// The socket file is private to the user (0600, in a 0700 folder) and removed on `stop`.
public final class DebugSocketServer: @unchecked Sendable {
    public typealias Handler = @Sendable (DebugRequest) async -> DebugResponse

    public let path: String
    private let handler: Handler
    private var listener: Int32 = -1
    private let lock = NSLock()
    private var stopped = false

    public init(path: String, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    /// Binds and starts accepting on a background thread. Replaces a stale socket file left by a crashed run.
    public func start() throws {
        guard path.utf8.count <= DebugInstance.maxSocketPathLength else {
            throw DebugError.failed("Socket path longer than \(DebugInstance.maxSocketPathLength) bytes: \(path)")
        }
        let folder = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        unlink(path)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw DebugError.failed("socket(): \(String(cString: strerror(errno)))") }
        var address = Self.address(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(descriptor, 16) == 0 else {
            let reason = String(cString: strerror(errno))
            close(descriptor)
            throw DebugError.failed("Cannot listen on \(path): \(reason)")
        }
        chmod(path, 0o600)
        listener = descriptor
        let thread = Thread { [self] in acceptLoop(descriptor) }
        thread.name = "loam-debug-accept"
        thread.start()
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        stopped = true
        if listener >= 0 { shutdown(listener, SHUT_RDWR); close(listener) }
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
            var on: Int32 = 1
            setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            let thread = Thread { [self] in serve(connection) }
            thread.name = "loam-debug-connection"
            thread.start()
        }
    }

    private func serve(_ connection: Int32) {
        defer { close(connection) }
        var reader = LineReader(descriptor: connection)
        while let line = reader.nextLine() {
            if line.allSatisfy({ $0 == 0x20 || $0 == 0x0D }) { continue }
            let response: DebugResponse
            do {
                let request = try DebugCoding.decodeRequest(line)
                let box = ResponseBox()
                let handler = handler
                Task { box.fulfil(await handler(request)) }
                var answer = box.wait()
                answer.id = request.id
                response = answer
            } catch {
                response = .failure(String(describing: error))
            }
            guard Self.write(DebugCoding.encode(response) + Data([0x0A]), to: connection) else { return }
        }
    }

    private final class ResponseBox: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)
        private var response = DebugResponse.failure("No answer")
        func fulfil(_ value: DebugResponse) { response = value; semaphore.signal() }
        func wait() -> DebugResponse { semaphore.wait(); return response }
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
                let written = send(descriptor, buffer.baseAddress! + offset, data.count - offset, 0)
                if written <= 0 { if errno == EINTR { continue }; return false }
                offset += written
            }
            return true
        }
    }
}

/// Reads newline-terminated lines from a descriptor.
struct LineReader {
    let descriptor: Int32
    private var buffer = Data()

    init(descriptor: Int32) { self.descriptor = descriptor }

    mutating func nextLine() -> Data? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer = Data(buffer[(newline + 1)...])
                return Data(line)
            }
            var chunk = [UInt8](repeating: 0, count: 65536)
            let count = recv(descriptor, &chunk, chunk.count, 0)
            if count < 0, errno == EINTR { continue }
            if count <= 0 {
                guard !buffer.isEmpty else { return nil }
                defer { buffer = Data() }
                return buffer
            }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }
}

/// A blocking client of the channel: what the tests and a Swift tool use. `loam-ctl` speaks the same lines.
public final class DebugClient {
    private let descriptor: Int32
    private var reader: LineReader

    public init(path: String) throws {
        guard path.utf8.count <= DebugInstance.maxSocketPathLength else {
            throw DebugError.failed("Socket path longer than \(DebugInstance.maxSocketPathLength) bytes: \(path)")
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DebugError.failed("socket(): \(String(cString: strerror(errno)))") }
        var address = DebugSocketServer.address(path)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            let reason = String(cString: strerror(errno))
            close(fd)
            throw DebugError.failed("Cannot connect to \(path): \(reason)")
        }
        descriptor = fd
        reader = LineReader(descriptor: fd)
    }

    deinit { close(descriptor) }

    /// Sends one request and waits for its response.
    public func send(_ request: DebugRequest) throws -> DebugResponse {
        guard DebugSocketServer.write(DebugCoding.encode(request) + Data([0x0A]), to: descriptor) else {
            throw DebugError.failed("The connection closed.")
        }
        guard let line = reader.nextLine() else { throw DebugError.failed("The connection closed before an answer.") }
        return try JSONDecoder().decode(DebugResponse.self, from: line)
    }

    public func send(_ command: DebugCommand) throws -> DebugResponse { try send(command.request) }
}
#endif
