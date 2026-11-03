import Foundation

/// Pure readers of git's machine output, and what a failed command's message means for the sync.
enum Git {
    /// One line of `git status --porcelain=v1 -z --no-renames`.
    struct StatusEntry: Equatable {
        /// The index (`X`) and work tree (`Y`) letters, `??` for an untracked file.
        let code: String
        let path: String

        var isDeletion: Bool { code.contains("D") }
    }

    static func parseStatus(_ data: Data) -> [StatusEntry] {
        fields(data).compactMap { field in
            guard field.count > 3 else { return nil }
            let code = String(field.prefix(2))
            return StatusEntry(code: code, path: String(field.dropFirst(3)))
        }
    }

    /// One line of `git ls-files -u -z`: a path in conflict at one stage (1 base, 2 local, 3 remote).
    struct UnmergedEntry: Equatable {
        let mode: String
        let oid: String
        let stage: Int
        let path: String
    }

    static func parseUnmerged(_ data: Data) -> [UnmergedEntry] {
        fields(data).compactMap { field in
            guard let tab = field.firstIndex(of: "\t") else { return nil }
            let info = field[..<tab].split(separator: " ")
            guard info.count == 3, let stage = Int(info[2]) else { return nil }
            return UnmergedEntry(mode: String(info[0]), oid: String(info[1]), stage: stage,
                                 path: String(field[field.index(after: tab)...]))
        }
    }

    /// `git rev-list --left-right --count A...B`: commits only in A, commits only in B.
    static func parseAheadBehind(_ text: String) -> (ahead: Int, behind: Int)? {
        let parts = text.split(whereSeparator: { $0 == "\t" || $0 == " " })
        guard parts.count == 2, let ahead = Int(parts[0]), let behind = Int(parts[1]) else { return nil }
        return (ahead, behind)
    }

    /// The NUL-separated fields of a `-z` output.
    static func fields(_ data: Data) -> [String] {
        data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    }

    /// What a failed command means for the sync.
    enum Failure: String, Codable, Equatable {
        /// No network, the host does not answer, or git gave up waiting.
        case offline
        /// The remote refused who we are: a password, a token or an ssh key is missing or wrong.
        case authentication
        /// The remote has commits we do not have: fetch and merge again.
        case rejected
        /// The branch does not exist on the remote yet.
        case missingRemoteBranch
        /// Another git process is working in this repository.
        case locked
        /// A file is too large for the host (GitHub refuses files over 100 MB).
        case tooLarge
        case other
    }

    static func classify(_ stderr: String) -> Failure {
        let text = stderr.lowercased()
        func has(_ needles: String...) -> Bool { needles.contains { text.contains($0) } }
        if has("index.lock", "unable to create", "another git process") { return .locked }
        if has("gh001", "exceeds github's file size limit", "large files detected", "file size limit") {
            return .tooLarge
        }
        if has("authentication failed", "permission denied", "could not read username", "could not read password",
               "terminal prompts disabled", "the requested url returned error: 403",
               "the requested url returned error: 401", "invalid username or password", "repository not found",
               "host key verification failed") {
            return .authentication
        }
        if has("couldn't find remote ref") { return .missingRemoteBranch }
        if has("[rejected]", "non-fast-forward", "fetch first", "updates were rejected", "\t!\t") { return .rejected }
        if has("could not resolve host", "network is unreachable", "timed out", "connection refused",
               "connection reset", "operation timed out", "ssh: connect to host", "unable to access",
               "could not connect", "failed to connect", "no route to host", "temporary failure in name resolution",
               "the remote end hung up unexpectedly", "does not appear to be a git repository") {
            return .offline
        }
        return .other
    }

    /// `url` with any user name or password removed, safe to show and to log.
    static func redact(_ url: String) -> String {
        guard let scheme = url.range(of: "://"), let at = url[scheme.upperBound...].firstIndex(of: "@") else {
            return url
        }
        let slash = url[scheme.upperBound...].firstIndex(of: "/") ?? url.endIndex
        guard at < slash else { return url }
        return String(url[..<scheme.upperBound]) + "***@" + String(url[url.index(after: at)...])
    }

    /// The last meaningful lines of git's message, without hints, credentials redacted.
    static func summary(_ stderr: String) -> String {
        let lines = stderr.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("hint:") }
        return lines.suffix(3).map { line in
            line.split(separator: " ").map { word in word.contains("://") ? redact(String(word)) : String(word) }
                .joined(separator: " ")
        }.joined(separator: " ")
    }
}
