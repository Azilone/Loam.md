import XCTest
import PluginKit
import LoamCore
@testable import TruffleSearchPlugin
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A stand-in for the Truffle daemon: answers each request line with whatever `handler` returns.
final class FakeDaemon {
    let path = "/tmp/so-\(UUID().uuidString.prefix(8)).sock"
    private(set) var requests: [[String: Any]] = []
    private let handler: ([String: Any]) -> [String: Any]
    private var listener: Int32 = -1
    private let lock = NSLock()

    init(_ handler: @escaping ([String: Any]) -> [String: Any]) throws {
        self.handler = handler
        #if os(Linux)
        listener = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #else
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        #endif
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: bytes.count) { destination in
                for (index, byte) in bytes.enumerated() { destination[index] = byte }
            }
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, length) }
        }
        guard bound == 0, listen(listener, 8) == 0 else { throw TruffleError.io("fake daemon: \(errno)") }
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    deinit {
        close(listener)
        unlink(path)
    }

    var received: [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    private func acceptLoop() {
        while true {
            let connection = accept(listener, nil, nil)
            if connection < 0 { return }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while !data.contains(UInt8(ascii: "\n")) {
                let count = recv(connection, &buffer, buffer.count, 0)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            if let line = data.split(separator: UInt8(ascii: "\n")).first,
               let request = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] {
                lock.lock()
                requests.append(request)
                lock.unlock()
                var reply = handler(request)
                reply["id"] = request["id"]
                var out = (try? JSONSerialization.data(withJSONObject: reply)) ?? Data()
                out.append(UInt8(ascii: "\n"))
                _ = out.withUnsafeBytes { send(connection, $0.baseAddress, out.count, 0) }
            }
            close(connection)
        }
    }
}

final class TruffleSearchTests: XCTestCase {
    func testSocketPathFollowsTheEnvironment() {
        XCTAssertEqual(TruffleClient.defaultSocketPath(environment: ["TRUFFLE_SOCKET": "/x/t.sock"], home: "/h"), "/x/t.sock")
        #if os(macOS)
        XCTAssertEqual(TruffleClient.defaultSocketPath(environment: [:], home: "/h"), "/h/Library/Application Support/Truffle/truffle.sock")
        #else
        XCTAssertEqual(TruffleClient.defaultSocketPath(environment: ["XDG_DATA_HOME": "/d"], home: "/h"), "/d/truffle/truffle.sock")
        XCTAssertEqual(TruffleClient.defaultSocketPath(environment: [:], home: "/h"), "/h/.local/share/truffle/truffle.sock")
        #endif
    }

    func testRequestRoundTrip() throws {
        let daemon = try FakeDaemon { _ in ["ok": true, "pong": 1] }
        let reply = try TruffleClient(socketPath: daemon.path, timeoutSeconds: 5).request(["op": "ping"])
        XCTAssertEqual(reply["pong"] as? Int, 1)
        XCTAssertEqual(daemon.received.first?["op"] as? String, "ping")
    }

    func testDaemonErrorsAndMissingDaemon() throws {
        let daemon = try FakeDaemon { _ in ["ok": false, "error": "still indexing"] }
        XCTAssertThrowsError(try TruffleClient(socketPath: daemon.path, timeoutSeconds: 5).request(["op": "status"])) {
            XCTAssertEqual($0 as? TruffleError, .daemon("still indexing"))
        }
        let missing = "/tmp/so-missing-\(UUID().uuidString.prefix(8)).sock"
        XCTAssertThrowsError(try TruffleClient(socketPath: missing).request(["op": "ping"])) {
            XCTAssertEqual($0 as? TruffleError, .daemonNotRunning(socket: missing))
        }
    }

    func testErrorsReadWellInTheCLI() {
        XCTAssertTrue(TruffleError.daemonNotRunning(socket: "/s").errorDescription!.contains("brew install azilone/tap/truffle"))
        XCTAssertEqual(TruffleError.daemon("still indexing").errorDescription, "Truffle: still indexing")
    }

}
