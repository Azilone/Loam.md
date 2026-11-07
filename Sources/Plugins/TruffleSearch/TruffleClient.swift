import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum TruffleError: Error, Equatable {
    /// Nothing is listening on the socket: the daemon is not running.
    case daemonNotRunning(socket: String)
    case io(String)
    case badReply(String)
    /// The daemon answered `{"ok": false, "error": ...}`.
    case daemon(String)
}

extension TruffleError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .daemonNotRunning(let socket):
            return "Truffle is not running (nothing listens on \(socket)). Install it with `brew install azilone/tap/truffle`, run `truffle setup`, or start `truffle serve`."
        case .io(let message): return "Truffle connection problem: \(message)"
        case .badReply(let reply): return "Truffle sent a reply that is not JSON: \(reply)"
        case .daemon(let message): return "Truffle: \(message)"
        }
    }
}

/// A client for the Truffle daemon: one JSON object per line over a unix socket.
/// https://github.com/Azilone/truffle
public struct TruffleClient: TruffleTransport {
    public let socketPath: String
    public var timeoutSeconds: Int

    public init(socketPath: String = TruffleClient.defaultSocketPath(), timeoutSeconds: Int = 60) {
        self.socketPath = socketPath
        self.timeoutSeconds = timeoutSeconds
    }

    /// `$TRUFFLE_SOCKET`, else where the daemon puts it: `~/Library/Application Support/Truffle` on macOS,
    /// `$XDG_DATA_HOME/truffle` or `~/.local/share/truffle` on Linux.
    public static func defaultSocketPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) -> String {
        if let explicit = environment["TRUFFLE_SOCKET"], !explicit.isEmpty { return explicit }
        #if os(macOS)
        return home + "/Library/Application Support/Truffle/truffle.sock"
        #else
        let data = environment["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.local/share"
        return data + "/truffle/truffle.sock"
        #endif
    }

    /// Sends one request line and returns the reply. Throws `TruffleError.daemon` when the daemon reports an error.
    public func request(_ request: [String: Any]) throws -> [String: Any] {
        let fd = try openConnection()
        defer { close(fd) }

        var line = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
        line.append(UInt8(ascii: "\n"))
        try writeAll(fd, line)

        let reply = try readLine(fd)
        guard let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any] else {
            throw TruffleError.badReply(String(decoding: reply, as: UTF8.self))
        }
        if object["ok"] as? Bool == false {
            throw TruffleError.daemon(object["error"] as? String ?? "unknown error")
        }
        return object
    }

    // MARK: Sockets

    private func openConnection() throws -> Int32 {
        #if os(Linux)
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { throw TruffleError.io("socket: \(String(cString: strerror(errno)))") }

        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        #if canImport(Darwin)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socketPath.utf8CString)
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            throw TruffleError.io("socket path too long: \(socketPath)")
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: path.count) { destination in
                for (index, byte) in path.enumerated() { destination[index] = byte }
            }
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, length) }
        }
        guard result == 0 else {
            close(fd)
            throw TruffleError.daemonNotRunning(socket: socketPath)
        }
        return fd
    }

    private func writeAll(_ fd: Int32, _ data: Data) throws {
        let bytes = [UInt8](data)
        var offset = 0
        while offset < bytes.count {
            #if os(Linux)
            let flags = Int32(MSG_NOSIGNAL)
            #else
            let flags: Int32 = 0
            #endif
            let written = bytes.withUnsafeBufferPointer { send(fd, $0.baseAddress! + offset, bytes.count - offset, flags) }
            guard written > 0 else { throw TruffleError.io("write: \(String(cString: strerror(errno)))") }
            offset += written
        }
    }

    private func readLine(_ fd: Int32) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = recv(fd, &buffer, buffer.count, 0)
            if count < 0 { throw TruffleError.io("read: \(String(cString: strerror(errno)))") }
            if count == 0 { break }
            result.append(buffer, count: count)
            if let newline = result.firstIndex(of: UInt8(ascii: "\n")) { return result[..<newline] }
        }
        guard !result.isEmpty else { throw TruffleError.io("the daemon closed the connection without answering") }
        return result
    }
}
