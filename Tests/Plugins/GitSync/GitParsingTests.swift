import XCTest
@testable import GitSyncPlugin

final class GitParsingTests: XCTestCase {
    private func z(_ fields: String...) -> Data {
        Data(fields.joined(separator: "\0").utf8 + [0])
    }

    func testStatusKeepsSpacesAndAccentsInPaths() {
        let entries = Git.parseStatus(z(" M Idées/Note de Kévin.md", "?? Why? [draft].md", "D  Old.md"))
        XCTAssertEqual(entries, [
            Git.StatusEntry(code: " M", path: "Idées/Note de Kévin.md"),
            Git.StatusEntry(code: "??", path: "Why? [draft].md"),
            Git.StatusEntry(code: "D ", path: "Old.md"),
        ])
        XCTAssertEqual(entries.map(\.isDeletion), [false, false, true])
        XCTAssertEqual(Git.parseStatus(Data()), [])
    }

    func testUnmergedEntriesGiveEachStage() {
        let entries = Git.parseUnmerged(z("100644 aaa 1\tA b.md", "100644 bbb 2\tA b.md", "120000 ccc 3\tlink"))
        XCTAssertEqual(entries, [
            Git.UnmergedEntry(mode: "100644", oid: "aaa", stage: 1, path: "A b.md"),
            Git.UnmergedEntry(mode: "100644", oid: "bbb", stage: 2, path: "A b.md"),
            Git.UnmergedEntry(mode: "120000", oid: "ccc", stage: 3, path: "link"),
        ])
    }

    func testAheadBehind() {
        XCTAssertEqual(Git.parseAheadBehind("3\t5")?.ahead, 3)
        XCTAssertEqual(Git.parseAheadBehind("3\t5")?.behind, 5)
        XCTAssertNil(Git.parseAheadBehind("fatal"))
    }

    func testFailuresAreRecognisedFromGitsMessages() {
        let samples: [(String, Git.Failure)] = [
            ("fatal: unable to access 'https://github.com/a/b.git/': Could not resolve host: github.com", .offline),
            ("ssh: connect to host github.com port 22: Network is unreachable", .offline),
            ("fatal: '/tmp/gone' does not appear to be a git repository", .offline),
            ("remote: Invalid username or password.\nfatal: Authentication failed for 'https://github.com/a/b.git/'",
             .authentication),
            ("git@github.com: Permission denied (publickey).", .authentication),
            ("fatal: could not read Username for 'https://github.com': terminal prompts disabled", .authentication),
            (" ! [rejected]        HEAD -> main (fetch first)\nerror: failed to push some refs", .rejected),
            ("fatal: couldn't find remote ref main", .missingRemoteBranch),
            ("fatal: Unable to create '/v/.git/index.lock': File exists.", .locked),
            ("remote: error: GH001: Large files detected.", .tooLarge),
            ("fatal: something else", .other),
        ]
        for (message, failure) in samples {
            XCTAssertEqual(Git.classify(message), failure, message)
        }
    }

    func testCredentialsNeverShow() {
        XCTAssertEqual(Git.redact("https://kevin:ghp_secret@github.com/a/b.git"), "https://***@github.com/a/b.git")
        XCTAssertEqual(Git.redact("https://github.com/a/b.git"), "https://github.com/a/b.git")
        XCTAssertEqual(Git.redact("git@github.com:a/b.git"), "git@github.com:a/b.git")
        XCTAssertEqual(
            Git.summary("hint: try again\nfatal: unable to access 'https://x:tok@github.com/a.git/'"),
            "fatal: unable to access 'https://***@github.com/a.git/'"
        )
    }
}
