import Foundation

/// Runs a tool (`swift`, `git`, `codesign`) for the plugin commands, its output appended to a log file so a long
/// build never fills a pipe. Waits without blocking a thread.
enum Subprocess {
    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Runs `tool` found on the PATH (through `/usr/bin/env`), appending stdout and stderr to `log`.
    /// Returns the exit status.
    @discardableResult
    static func run(
        _ tool: String,
        _ arguments: [String],
        in directory: URL? = nil,
        environment extra: [String: String] = [:],
        log: URL
    ) async throws -> Int32 {
        let files = FileManager.default
        try files.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !files.fileExists(atPath: log.path) { files.createFile(atPath: log.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(Data("$ \(([tool] + arguments).joined(separator: " "))\n".utf8))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [tool] + arguments
        process.currentDirectoryURL = directory
        process.environment = environment(extra)
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in continuation.resume(returning: finished.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: Failure(message: "cannot run \(tool): \(error.localizedDescription)"))
            }
        }
    }

    /// Runs `tool` and returns its trimmed stdout, or throws with its output when it fails.
    static func output(_ tool: String, _ arguments: [String], in directory: URL? = nil,
                       environment extra: [String: String] = [:]) async throws -> String {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("loam-subprocess-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: log) }
        let status = try await run(tool, arguments, in: directory, environment: extra, log: log)
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        // Drop the "$ command" line the log starts with.
        let body = text.split(separator: "\n", omittingEmptySubsequences: false).dropFirst().joined(separator: "\n")
        guard status == 0 else { throw Failure(message: "\(tool) failed (\(status)): \(lastLines(body, 10))") }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The process environment plus `extra`, without the `DYLD_*` variables a test runner sets: a child tool must
    /// not load the libraries of the build under test.
    static func environment(_ extra: [String: String]) -> [String: String] {
        ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("DYLD_") }.merging(extra) { _, new in new }
    }

    static func lastLines(_ text: String, _ count: Int) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(count + (text.hasSuffix("\n") ? 1 : 0))
            .joined(separator: "\n")
            .trimmingCharacters(in: .newlines)
    }
}
