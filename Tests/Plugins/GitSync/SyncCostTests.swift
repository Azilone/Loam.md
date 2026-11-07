import XCTest
@testable import GitSyncPlugin

/// What a sync costs on a vault of 1000 notes, plain and encrypted, through a local bare remote. Runs only with
/// LOAM_SYNC_BENCH=1 (about two minutes); LOAM_BENCH_TOOL=<path to loam> measures a release build of `loam crypt`.
/// Prints a table, also written to LOAM_BENCH_OUT when set.
final class SyncCostTests: XCTestCase {
    private let noteCount = 1000

    func testTheCostOfASyncOnAThousandNotes() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["LOAM_SYNC_BENCH"] == "1", "set LOAM_SYNC_BENCH=1 to measure")
        let tool = environment["LOAM_BENCH_TOOL"].map { GitCrypt.quote($0) + " crypt" } ?? GitFixture.cryptTool
        var rows: [String] = ["tool: \(tool)", "notes: \(noteCount)", "",
                              "| | plain | encrypted |", "|---|---|---|"]
        var plain: [String: Double] = [:]
        var encrypted: [String: Double] = [:]
        for encrypt in [false, true] {
            let fixture = try await GitFixture()
            let a = try fixture.emptyDevice("A", cryptTool: tool)
            try writeNotes(into: a)
            let setup = try await time { try await a.setUp(fixture.remoteURL, device: "A", encrypt: encrypt) }
            let b = try await fixture.clonedDevice("B", cryptTool: tool)
            if encrypt { try await b.importKey(from: a) }
            let adopt = try await time { await b.sync() }

            var results: [String: Double] = ["first sync (setup)": setup, "second device's first sync": adopt]
            results["sync, nothing changed"] = try await median(21) { await a.sync() }
            var edit = 0
            results["sync, 1 note changed here"] = try await median(21) {
                edit += 1
                try a.write("Notes/Folder 3/Note 30.md", "# Note 30\nedit \(edit)\n")
                return await a.sync()
            }
            if environment["LOAM_BENCH_TRACE"] == "1" {
                let before = a.runner.timings.count
                try a.write("Notes/Folder 3/Note 30.md", "# Note 30\ntraced\n")
                _ = await a.sync()
                print("\n\(encrypt ? "encrypted" : "plain"), 1 note changed here:")
                for timing in a.runner.timings.dropFirst(before) {
                    print(String(format: "%6.1f ms  ", timing.seconds * 1000) + timing.command.prefix(4).joined(separator: " "))
                }
            }
            var incoming: [Double] = []
            for round in 0..<11 {
                try a.write("Notes/Folder 5/Note 50.md", "# Note 50\nfrom A \(round)\n")
                _ = await a.sync()
                let before = b.runner.timings.count
                incoming.append(try await time { await b.sync() })
                if round == 10, environment["LOAM_BENCH_TRACE"] == "1" {
                    print("\n\(encrypt ? "encrypted" : "plain"), 1 note changed elsewhere:")
                    for timing in b.runner.timings.dropFirst(before) {
                        print(String(format: "%6.1f ms  ", timing.seconds * 1000) + timing.command.prefix(4).joined(separator: " "))
                    }
                }
            }
            results["sync, 1 note changed elsewhere"] = incoming.sorted()[incoming.count / 2]
            var conflicts: [Double] = []
            for round in 0..<5 {
                try a.write("Notes/Folder 7/Note \(70 + round).md", "# Note\nsame line, A\n")
                try b.write("Notes/Folder 7/Note \(70 + round).md", "# Note\nsame line, B\n")
                _ = await a.sync()
                conflicts.append(try await time { await b.sync() })
            }
            results["sync with a conflict copy"] = conflicts.sorted()[conflicts.count / 2]
            XCTAssertEqual(b.files().keys.filter(ConflictPlan.isCopy).count, 5)
            if encrypt { encrypted = results } else { plain = results }
        }

        // Turning encryption on in a vault that already syncs plain: every note encrypted once.
        let fixture = try await GitFixture()
        let a = try fixture.emptyDevice("A", cryptTool: tool)
        try writeNotes(into: a)
        _ = try await a.setUp(fixture.remoteURL, device: "A")
        let turnOn = try await time {
            _ = try await a.engine.setUp(SetupRequest(encrypt: true))
            return await a.sync()
        }

        // The cryptography alone, in process: every note encrypted and decrypted once.
        let key = VaultKey.generate()
        let notes = a.files().filter { $0.key.hasSuffix(".md") }.map(\.value)
        let start = Date()
        for note in notes { _ = try CryptCodec.decrypt(try CryptCodec.encrypt(note, with: key), with: key) }
        let crypto = Date().timeIntervalSince(start)
        let bytes = notes.reduce(0) { $0 + $1.count }

        for name in ["first sync (setup)", "second device's first sync", "sync, nothing changed",
                     "sync, 1 note changed here", "sync, 1 note changed elsewhere", "sync with a conflict copy"] {
            rows.append("| \(name) | \(format(plain[name])) | \(format(encrypted[name])) |")
        }
        rows.append("| turning encryption on (\(noteCount) notes) | | \(format(turnOn)) |")
        rows.append("| encrypt + decrypt \(notes.count) notes (\(bytes / 1024) KB), in process | | "
                    + String(format: "%.1f ms", crypto * 1000) + " |")
        let table = rows.joined(separator: "\n")
        print("\n" + table + "\n")
        if let out = environment["LOAM_BENCH_OUT"] { try table.write(toFile: out, atomically: true, encoding: .utf8) }
    }

    /// 1000 notes of 200 B to 4 KB in 20 folders, the same every run.
    private func writeNotes(into device: Device) throws {
        var seed: UInt64 = 42
        func next() -> UInt64 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return seed >> 33
        }
        let words = ["note", "idea", "meeting", "plan", "draft", "link", "task", "read", "write", "Loam", "garden",
                     "project", "daily", "review", "[[Welcome]]", "#tag", "- [ ] todo", "**bold**", "the", "and"]
        for index in 0..<noteCount {
            let length = 30 + Int(next() % 600)
            var text = "# Note \(index)\n\n"
            for word in 0..<length {
                text += words[Int(next() % UInt64(words.count))] + (word % 12 == 11 ? "\n" : " ")
            }
            try device.write("Notes/Folder \(index / 50)/Note \(index).md", text + "\n")
        }
    }

    private func time(_ body: () async throws -> CycleOutcome) async throws -> Double {
        let start = Date()
        let outcome = try await body()
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(outcome.status.state, .synced, outcome.status.message ?? "")
        return elapsed
    }

    private func median(_ runs: Int, _ body: () async throws -> CycleOutcome) async throws -> Double {
        var times: [Double] = []
        for _ in 0..<runs { times.append(try await time(body)) }
        return times.sorted()[runs / 2]
    }

    private func format(_ seconds: Double?) -> String {
        guard let seconds else { return "" }
        return seconds < 1 ? String(format: "%.0f ms", seconds * 1000) : String(format: "%.2f s", seconds)
    }
}
