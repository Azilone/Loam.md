import XCTest
@testable import DebugProtocol

final class DebugRequestTests: XCTestCase {
    func testRequestIsAFlatObjectWithCmdAndParameters() throws {
        let request = try DebugCoding.decodeRequest(Data(#"{"id": 7, "cmd": "click", "x": 300, "y": 200.5}"#.utf8))
        XCTAssertEqual(request.cmd, "click")
        XCTAssertEqual(request.id, 7)
        XCTAssertEqual(request["x"], 300)
        XCTAssertEqual(request["y"], 200.5)
        XCTAssertNil(request["id"], "id is not a parameter")
    }

    func testRequestWithoutCmdIsMalformed() {
        XCTAssertThrowsError(try DebugCoding.decodeRequest(Data(#"{"x": 1}"#.utf8)))
        XCTAssertThrowsError(try DebugCoding.decodeRequest(Data("not json".utf8)))
    }

    func testEncodingIsOneLineWithSortedKeys() throws {
        let line = DebugCoding.encode(DebugRequest(cmd: "key", params: ["keys": "cmd+n"], id: 1))
        XCTAssertEqual(String(decoding: line, as: UTF8.self), #"{"cmd":"key","id":1,"keys":"cmd+n"}"#)
        XCTAssertFalse(line.contains(0x0A))
    }

    func testResponsesCarryResultOrError() throws {
        let ok = DebugCoding.encode(DebugResponse.success(["path": "/tmp/a.png"], id: 2))
        XCTAssertEqual(String(decoding: ok, as: UTF8.self), #"{"id":2,"ok":true,"result":{"path":"/tmp/a.png"}}"#)
        let failure = try JSONDecoder().decode(DebugResponse.self, from: DebugCoding.encode(DebugResponse.failure("nope")))
        XCTAssertFalse(failure.ok)
        XCTAssertEqual(failure.error, "nope")
    }
}

final class DebugCommandTests: XCTestCase {
    private func parse(_ json: String) throws -> DebugCommand {
        try DebugCommand(request: try DebugCoding.decodeRequest(Data(json.utf8)))
    }

    func testEveryCommandReadsBackFromItsRequest() throws {
        let commands: [DebugCommand] = [
            .help, .ping, .info, .editor, .quit,
            .open(path: "Inbox/Trip.md", placement: "newTab"),
            .type(text: "> a\n"),
            .key(shortcut: "shift+tab", repeats: 3),
            .click(.point(x: 10, y: 20), clicks: 2, modifiers: ["cmd"]),
            .click(.id("sidebar.search"), clicks: 1, modifiers: []),
            .hover(.label("New Note")),
            .drag(from: .point(x: 1, y: 2), to: .id("column.done")),
            .press(.point(x: 5, y: 6)), .move(.id("a")), .release(.label("b")),
            .scroll(at: .point(x: 600, y: 400), dy: -300),
            .window(width: 900, height: 600, front: true),
            .window(width: nil, height: nil, front: nil),
            .window(width: 1000, height: nil, front: nil, live: 40),
            .theme("dark"),
            .reduceMotion(true),
            .ax(depth: 4, find: "Search"), .hit(.point(x: 3, y: 4)),
            .screenshot(path: "/tmp/a.png", mode: .layers, scale: 1, window: "settings"),
            .film(prefix: "/tmp/f", count: 8, intervalMs: 40, scale: 1, then: DebugRequest(cmd: "key", params: ["keys": "cmd+t"])),
            .run(command: "mindmap.open", arguments: ["path": "Map.md"]),
            .wait(ms: 250),
        ]
        for command in commands {
            let line = DebugCoding.encode(command.request)
            XCTAssertEqual(try DebugCommand(request: try DebugCoding.decodeRequest(line)), command, "\(command)")
        }
    }

    func testDefaults() throws {
        XCTAssertEqual(try parse(#"{"cmd":"open","path":"A.md"}"#), .open(path: "A.md", placement: "replace"))
        XCTAssertEqual(try parse(#"{"cmd":"key","keys":"return"}"#), .key(shortcut: "return", repeats: 1))
        XCTAssertEqual(try parse(#"{"cmd":"click","x":1,"y":2}"#), .click(.point(x: 1, y: 2), clicks: 1, modifiers: []))
        XCTAssertEqual(try parse(#"{"cmd":"screenshot","path":"/tmp/a.png"}"#), .screenshot(path: "/tmp/a.png", mode: .view, scale: nil, window: nil))
        XCTAssertEqual(try parse(#"{"cmd":"ax"}"#), .ax(depth: 12, find: nil))
    }

    func testFilmCountIsBounded() throws {
        XCTAssertEqual(
            try parse(#"{"cmd":"film","prefix":"/tmp/f","count":100000,"interval":-5}"#),
            .film(prefix: "/tmp/f", count: 200, intervalMs: 0, scale: nil, then: nil)
        )
    }

    func testMissingAndUnknown() {
        XCTAssertThrowsError(try parse(#"{"cmd":"click","x":1}"#)) { XCTAssertEqual($0 as? DebugError, .missing("x and y, axid or label")) }
        XCTAssertThrowsError(try parse(#"{"cmd":"type"}"#)) { XCTAssertEqual($0 as? DebugError, .missing("text")) }
        XCTAssertThrowsError(try parse(#"{"cmd":"theme","value":"purple"}"#))
        XCTAssertThrowsError(try parse(#"{"cmd":"reduce-motion","value":"yes"}"#))
        XCTAssertThrowsError(try parse(#"{"cmd":"teleport"}"#)) { XCTAssertEqual($0 as? DebugError, .unknownCommand("teleport")) }
    }

    func testNamesCoverEveryCommandAndNothingElse() throws {
        // Every advertised name must parse (or fail only for a missing parameter), never be "unknown".
        for name in DebugCommand.names {
            do { _ = try DebugCommand(request: DebugRequest(cmd: name)) } catch let error as DebugError {
                if case .unknownCommand = error { XCTFail("\(name) is advertised but unknown") }
            }
        }
    }
}

final class DebugInstanceTests: XCTestCase {
    func testNames() {
        XCTAssertTrue(DebugInstance.isValid(name: "table-caret_2.a"))
        for bad in ["", ".hidden", "a/b", "a b", "../x", String(repeating: "a", count: 33), "é"] {
            XCTAssertFalse(DebugInstance.isValid(name: bad), bad)
        }
    }

    func testPathsLiveUnderTheInstanceFolder() throws {
        let base = URL(fileURLWithPath: "/tmp/loam-test-instances")
        let instance = try XCTUnwrap(DebugInstance(name: "foo", base: base))
        XCTAssertEqual(instance.socketPath, "/tmp/loam-test-instances/foo/ctl.sock")
        XCTAssertEqual(instance.vaultURL.path, "/tmp/loam-test-instances/foo/vault")
        XCTAssertNil(DebugInstance(name: "../etc", base: base))
    }

    func testRequestedFromEnvironmentOrArgument() {
        let env = ["LOAM_INSTANCES_DIR": "/tmp/x"]
        XCTAssertNil(DebugInstance.requested(environment: env, arguments: ["Loam"]))
        XCTAssertEqual(DebugInstance.requested(environment: env.merging(["LOAM_INSTANCE": "a"]) { $1 }, arguments: ["Loam"])?.socketPath, "/tmp/x/a/ctl.sock")
        XCTAssertEqual(DebugInstance.requested(environment: env.merging(["LOAM_INSTANCE": "a"]) { $1 }, arguments: ["Loam", "--instance", "b"])?.name, "b")
        XCTAssertNil(DebugInstance.requested(environment: ["LOAM_INSTANCE": "bad/name"], arguments: ["Loam"]))
    }
}

final class DebugSocketTests: XCTestCase {
    private var folder: URL!

    override func setUp() {
        folder = URL(fileURLWithPath: "/tmp/loam-dbg-\(UUID().uuidString.prefix(8))")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    func testRequestsGetOneResponseEachInOrderWithTheirIds() throws {
        let path = folder.appendingPathComponent("ctl.sock").path
        let server = DebugSocketServer(path: path) { request in
            if request.cmd == "slow" { try? await Task.sleep(for: .milliseconds(50)) }
            return .success(["echo": .string(request.cmd), "x": request["x"] ?? .null])
        }
        try server.start()
        defer { server.stop() }

        let client = try DebugClient(path: path)
        let first = try client.send(DebugRequest(cmd: "slow", params: ["x": 1], id: "a"))
        let second = try client.send(DebugRequest(cmd: "ping", id: 2))
        XCTAssertEqual(first.id, "a")
        XCTAssertEqual(first.result?["echo"], "slow")
        XCTAssertEqual(first.result?["x"], 1)
        XCTAssertEqual(second.id, 2)
        XCTAssertEqual(second.result?["echo"], "ping")
    }

    func testBadLinesGetAnErrorAndTheConnectionStaysUp() throws {
        let path = folder.appendingPathComponent("ctl.sock").path
        let server = DebugSocketServer(path: path) { _ in .success() }
        try server.start()
        defer { server.stop() }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(descriptor) }
        var address = DebugSocketServer.address(path)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(connected, 0)
        XCTAssertTrue(DebugSocketServer.write(Data("garbage\n{\"cmd\":\"ping\"}\n".utf8), to: descriptor))
        var reader = LineReader(descriptor: descriptor)
        let bad = try JSONDecoder().decode(DebugResponse.self, from: try XCTUnwrap(reader.nextLine()))
        let good = try JSONDecoder().decode(DebugResponse.self, from: try XCTUnwrap(reader.nextLine()))
        XCTAssertFalse(bad.ok)
        XCTAssertTrue(good.ok)
    }

    func testSocketIsPrivateAndRemovedOnStop() throws {
        let path = folder.appendingPathComponent("ctl.sock").path
        let server = DebugSocketServer(path: path) { _ in .success() }
        try server.start()
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attributes[.posixPermissions] as? Int) ?? 0, 0o600)
        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testAStaleSocketFileIsReplaced() throws {
        let path = folder.appendingPathComponent("ctl.sock").path
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: Data())
        let server = DebugSocketServer(path: path) { _ in .success() }
        try server.start()
        defer { server.stop() }
        XCTAssertTrue(try DebugClient(path: path).send(.ping).ok)
    }

    func testTooLongPathIsRefused() {
        let path = "/tmp/" + String(repeating: "a", count: 120) + "/ctl.sock"
        XCTAssertThrowsError(try DebugSocketServer(path: path) { _ in .success() }.start())
        XCTAssertThrowsError(try DebugClient(path: path))
    }

    func testConnectingToNothingFails() {
        XCTAssertThrowsError(try DebugClient(path: folder.appendingPathComponent("none.sock").path))
    }
}
