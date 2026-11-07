import Foundation
import PluginKit
import PluginKitTesting
import LoamCore
import XCTest
@testable import TruffleSearchPlugin

/// A Truffle that is never there: every request fails as if nothing listened on the socket.
private struct MissingTruffle: TruffleTransport {
    func request(_ request: [String: Any]) throws -> [String: Any] {
        throw TruffleError.daemonNotRunning(socket: "/nowhere.sock")
    }
}

/// A Truffle that answers every request with `reply`, and remembers the last request.
private final class CannedTruffle: TruffleTransport, @unchecked Sendable {
    let reply: [String: Any]
    var last: [String: Any] = [:]
    init(_ reply: [String: Any]) { self.reply = reply }
    func request(_ request: [String: Any]) throws -> [String: Any] {
        last = request
        return reply
    }
}

final class SearchServiceTests: XCTestCase {
    private let files = [
        "Welcome.md": "# Welcome\n\nStart with the plan.\n",
        "Projects/Plan.md": "# Plan\n\nShip the search panel.\nThen the PLAN for backlinks.\n",
        "Projects/Planning notes.md": "nothing here\n",
        "Ideas/Café.md": "Un café serré, puis le plan.\n",
        "Ideas/Long.md": String(repeating: "x", count: 300) + " needle " + String(repeating: "y", count: 300) + "\n",
    ]

    private func vault(_ extra: [String: String] = [:]) throws -> TemporaryVault {
        let vault = try TemporaryVault()
        for (path, text) in files.merging(extra, uniquingKeysWith: { $1 }) { try vault.write(path, text) }
        return vault
    }

    // MARK: Fallback

    func testContentFallbackFindsLinesCaseInsensitivelyWithSnippetsAndLineNumbers() throws {
        let service = VaultSearchService(vault: try vault(), truffle: MissingTruffle())
        let hits = try service.search("plan", kind: .content, limit: 20)
        // Notes named after the query first, then the others in path order.
        XCTAssertEqual(hits.map(\.path), ["Projects/Plan.md", "Projects/Plan.md", "Ideas/Café.md", "Welcome.md"])
        XCTAssertEqual(hits.map(\.line), [1, 4, 1, 3])
        XCTAssertEqual(hits[0].line, 1)
        XCTAssertEqual(hits[0].snippet, "# Plan")
        XCTAssertEqual(hits[0].title, "Plan")
        XCTAssertEqual(hits.first { $0.path == "Welcome.md" }?.line, 3)
        XCTAssertEqual(hits.first { $0.path == "Welcome.md" }?.snippet, "Start with the plan.")
    }

    func testContentFallbackIgnoresAccentsAndCutsLongLines() throws {
        let service = VaultSearchService(vault: try vault(), truffle: MissingTruffle())
        XCTAssertEqual(try service.search("cafe", kind: .content, limit: 5).map(\.path), ["Ideas/Café.md"])
        let long = try XCTUnwrap(try service.search("needle", kind: .content, limit: 5).first)
        let snippet = try XCTUnwrap(long.snippet)
        XCTAssertTrue(snippet.hasPrefix("…"))
        XCTAssertTrue(snippet.hasSuffix("…"))
        XCTAssertTrue(snippet.contains("needle"))
        XCTAssertLessThanOrEqual(snippet.count, BuiltinSearch.snippetLength + 2)
    }

    func testContentFallbackRespectsTheLimitAndTheLinesPerNote() throws {
        let many = (1...20).map { "match \($0)" }.joined(separator: "\n")
        let service = VaultSearchService(vault: try vault(["Many.md": many, "Zed.md": "match\n"]), truffle: MissingTruffle())
        let all = try service.search("match", kind: .content, limit: 100)
        XCTAssertEqual(all.filter { $0.path == "Many.md" }.count, BuiltinSearch.maxLinesPerNote)
        XCTAssertEqual(all.last?.path, "Zed.md")
        XCTAssertEqual(try service.search("match", kind: .content, limit: 2).count, 2)
        XCTAssertEqual(try service.search("match", kind: .content, limit: 0), [])
    }

    func testContentFallbackSeesEditsToANote() throws {
        let vault = try vault()
        let service = VaultSearchService(vault: vault, truffle: MissingTruffle())
        XCTAssertEqual(try service.search("zebra", kind: .content, limit: 5), [])
        try vault.write("Welcome.md", "# Welcome\n\nA zebra, at last.\n")
        XCTAssertEqual(try service.search("zebra", kind: .content, limit: 5).map(\.line), [3])
    }

    func testAServiceThatFollowsChangesWalksAgainOnlyAfterOne() throws {
        let vault = try vault()
        let service = VaultSearchService(vault: vault, truffle: MissingTruffle())
        service.followChanges()
        XCTAssertEqual(try service.search("zebra", kind: .content, limit: 5), [])
        try vault.write("Zebra.md", "A zebra.\n")
        XCTAssertEqual(try service.search("zebra", kind: .content, limit: 5), [], "no change was told yet")
        service.vaultChanged()
        XCTAssertEqual(try service.search("zebra", kind: .content, limit: 5).map(\.path), ["Zebra.md"])
        XCTAssertEqual(try service.search("zebra", kind: .names, limit: 5).map(\.path), ["Zebra.md"])
    }

    func testNamesFallbackRanksSubstringsBeforeSubsequencesAndFolders() throws {
        let service = VaultSearchService(vault: try vault(), truffle: MissingTruffle())
        XCTAssertEqual(try service.search("plan", kind: .names, limit: 10).map(\.path), [
            "Projects/Plan.md", "Projects/Planning notes.md",
        ])
        // A subsequence: p-n-n in "Planning notes".
        XCTAssertEqual(try service.search("pnn", kind: .names, limit: 10).map(\.path), ["Projects/Planning notes.md"])
        // The folder matches when the name does not.
        XCTAssertEqual(try service.search("ideas", kind: .names, limit: 10).map(\.path), ["Ideas/Café.md", "Ideas/Long.md"])
        XCTAssertEqual(try service.search("cafe", kind: .names, limit: 10).first?.title, "Café")
        XCTAssertEqual(try service.search("plan", kind: .names, limit: 1).count, 1)
        XCTAssertEqual(try service.search("qqqq", kind: .names, limit: 10), [])
    }

    func testMeaningWithoutTruffleThrowsNotRunningWithAHint() throws {
        let service = VaultSearchService(vault: try vault(), truffle: MissingTruffle())
        XCTAssertThrowsError(try service.search("pets in the lease", kind: .meaning, limit: 5)) {
            XCTAssertEqual($0 as? SearchError, .notRunning)
            XCTAssertTrue($0.localizedDescription.contains("brew install azilone/tap/truffle"))
        }
        XCTAssertThrowsError(try service.search("  ", kind: .content, limit: 5)) {
            XCTAssertEqual($0 as? SearchError, .emptyQuery)
        }
    }

    func testStatusSaysWhetherTruffleRuns() throws {
        let vault = try vault()
        let down = VaultSearchService(vault: vault, truffle: MissingTruffle()).status()
        XCTAssertFalse(down.truffleRunning)
        XCTAssertFalse(down.supports(.meaning))
        XCTAssertTrue(down.supports(.content))
        XCTAssertTrue(down.message.contains("not running"))

        let up = VaultSearchService(vault: vault, truffle: CannedTruffle(["ok": true, "entries": 42])).status()
        XCTAssertEqual(up, SearchStatus(truffleRunning: true, truffleReady: true, indexedFiles: 42, message: up.message))
        XCTAssertTrue(up.supports(.meaning))
    }

    // MARK: Through Truffle

    func testTruffleRepliesBecomeVaultRelativeHits() throws {
        let vault = try vault()
        let root = vault.rootURL.standardizedFileURL.path
        let names = CannedTruffle(["ok": true, "hits": [
            ["path": root + "/Projects/Plan.md", "score": 9], ["path": "/elsewhere/Plan.md", "score": 3],
            ["path": root + "/Projects", "score": 2],
        ]])
        let hits = try VaultSearchService(vault: vault, truffle: names).search("plan", kind: .names, limit: 5)
        XCTAssertEqual(hits, [SearchHit(path: "Projects/Plan.md", title: "Plan", score: 9)])
        XCTAssertEqual(names.last["op"] as? String, "search")
        XCTAssertEqual(names.last["in"] as? String, root)
        XCTAssertEqual(names.last["limit"] as? Int, 5)

        let grep = CannedTruffle(["ok": true, "files": [
            ["path": root + "/Welcome.md", "matches": [["line": 3, "text": "Start with the plan."]]],
        ]])
        let lines = try VaultSearchService(vault: vault, truffle: grep).search("plan", kind: .content, limit: 5)
        XCTAssertEqual(lines, [SearchHit(path: "Welcome.md", title: "Welcome", snippet: "Start with the plan.", line: 3)])
        XCTAssertEqual(grep.last["op"] as? String, "grep")
        XCTAssertEqual(grep.last["pattern"] as? String, "plan")

        let meaning = CannedTruffle(["ok": true, "hits": [
            ["path": root + "/Ideas/Café.md", "excerpt": "Un café\nserré"], ["path": "/other/b.md"],
        ]])
        let found = try VaultSearchService(vault: vault, truffle: meaning).search("coffee", kind: .meaning, limit: 5)
        XCTAssertEqual(found, [SearchHit(path: "Ideas/Café.md", title: "Café", snippet: "Un café serré")])
        XCTAssertEqual(meaning.last["op"] as? String, "meaning.search")
    }

    func testARealSocketThatIsMissingFallsBack() throws {
        let missing = TruffleClient(socketPath: "/tmp/so-missing-\(UUID().uuidString.prefix(8)).sock", timeoutSeconds: 2)
        let service = VaultSearchService(vault: try vault(), truffle: missing)
        XCTAssertEqual(try service.search("ship", kind: .content, limit: 5).map(\.path), ["Projects/Plan.md"])
    }

    // MARK: Plugin

    func testPluginProvidesTheServiceAndCommandsUseIt() async throws {
        let harness = try PluginTestHarness([TruffleSearchPlugin.self], files: ["Note.md": "# Note\n\nA line about zebras.\n"])
        defer { harness.host.deactivateAll() }
        XCTAssertNotNil(harness.kernel.services.service(.search))
        XCTAssertEqual(harness.kernel.commands.all.map(\.id), ["search.content", "search.meaning", "search.names", "search.status"])
        do {
            _ = try await harness.run("search.names")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? CommandError, .missingArgument(name: "q"))
        }
        let status = try JSONDecoder().decode(SearchStatus.self, from: Data(try await harness.run("search.status").utf8))
        XCTAssertFalse(status.message.isEmpty)
    }
}
