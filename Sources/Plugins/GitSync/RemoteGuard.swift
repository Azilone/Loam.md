import Foundation

/// The check that an encrypted vault's remote holds only ciphertext, run by GitHub on every push: a file pushed in
/// plain text by a tool without Loam's encryption (an agent's plain clone) fails it. Required on the branch (branch
/// protection), it refuses such a push before it lands.
enum RemoteGuard {
    static let workflowPath = ".github/workflows/loam-encrypted.yml"

    /// Bash run in a checkout made without the filter, where files hold what the remote holds. Prints each plain file
    /// and fails when there is one. The files git reads itself, `.github/` and empty files are left out.
    static let checkScript = #"""
        plain=0
        while IFS= read -r -d '' f; do
          case "$f" in .github/*|.gitattributes|*/.gitattributes|.gitignore|*/.gitignore) continue ;; esac
          [ -f "$f" ] && [ ! -L "$f" ] && [ -s "$f" ] || continue
          if [ "$(head -c 10 "$f" | od -An -tx1 | tr -d ' \n')" != "004c4f414d4352595054" ]; then
            echo "::error file=$f::$f is not encrypted"
            plain=$((plain + 1))
          fi
        done < <(git ls-files -z)
        if [ "$plain" -gt 0 ]; then echo "$plain file(s) not encrypted"; exit 1; fi
        echo "Every file is encrypted."
        """#

    static var workflow: String {
        let header = """
            # Written by Loam (sync.protect). Fails when a file on this remote is not encrypted, so a push from a tool
            # without Loam's encryption shows at once. Make it required on the branch (Settings > Branches) to refuse
            # such pushes. The notes stay encrypted: this only reads the first bytes of each file.
            name: Loam encrypted
            on: [push, pull_request]
            permissions:
              contents: read
            jobs:
              encrypted:
                runs-on: ubuntu-latest
                steps:
                  - uses: actions/checkout@v4
                  - name: Every file holds Loam ciphertext
                    shell: bash
                    run: |
            """
        let script = checkScript.split(separator: "\n").map { "          " + $0 }
        return ([header] + script).joined(separator: "\n") + "\n"
    }
}

extension SyncEngine {
    /// `sync.protect`, and part of `sync.setup encrypt=true`: writes the remote check (`RemoteGuard`) and keeps
    /// `.github/` out of the encryption, so GitHub can read it. The next sync commits and pushes them.
    func installRemoteGuard() async throws -> [String] {
        var report: [String] = []
        let attributes = (try? String(contentsOf: root.appendingPathComponent(".gitattributes"), encoding: .utf8)) ?? ""
        guard CryptAttributes.declaredKey(in: attributes) != nil else {
            throw SetupError(message: "This vault is not encrypted: the remote check is for encrypted vaults.")
        }
        if !attributes.contains(CryptAttributes.githubRule) {
            let separator = attributes.isEmpty || attributes.hasSuffix("\n") ? "" : "\n"
            try await host.write(".gitattributes", Data((attributes + separator + CryptAttributes.githubRule + "\n").utf8))
        }
        let located = await git(["rev-parse", "--absolute-git-dir"])
        if located.succeeded { updateCloneRules(gitDir: located.text) }
        let current = try? Data(contentsOf: root.appendingPathComponent(RemoteGuard.workflowPath))
        if current != Data(RemoteGuard.workflow.utf8) {
            try await host.write(RemoteGuard.workflowPath, Data(RemoteGuard.workflow.utf8))
            report.append("Added \(RemoteGuard.workflowPath): GitHub checks on every push that the remote holds only "
                          + "encrypted files. To refuse a push that is not, make the check \"encrypted\" required for "
                          + "the branch (repository Settings > Branches), and block force pushes there.")
        }
        return report
    }

    /// Adds rules a clone made by an older Loam lacks to its own attributes (`info/attributes`, which wins over
    /// `.gitattributes`): `.github/` stays plain.
    func updateCloneRules(gitDir: String) {
        let url = URL(fileURLWithPath: gitDir).appendingPathComponent("info/attributes")
        guard let current = try? String(contentsOf: url, encoding: .utf8),
              current.contains(CryptAttributes.cloneMarker), !current.contains(CryptAttributes.githubRule) else { return }
        let separator = current.hasSuffix("\n") ? "" : "\n"
        try? Data((current + separator + CryptAttributes.githubRule + "\n").utf8).write(to: url, options: .atomic)
    }
}

/// A file that reached the remote in plain text after the vault was encrypted.
struct Leak: Codable, Equatable {
    let commit: String
    let subject: String
    let path: String
}

extension SyncEngine {
    /// `sync.leak.report`: the files committed in plain text on the remote's branch since the vault was encrypted
    /// (as last fetched), commit by commit. History from before encryption is readable by design and left out.
    func leaks() async -> [Leak] {
        let settings = await host.settings()
        let head = await git(["symbolic-ref", "-q", "--short", "HEAD"])
        let branch = settings.branch.isEmpty ? head.text : settings.branch
        let remoteRef = "refs/remotes/\(settings.remote)/\(branch)"
        guard await git(["rev-parse", "-q", "--verify", remoteRef + "^{commit}"]).succeeded else { return [] }
        // The first commit that named the key: encryption starts there.
        let started = await git(["log", "--format=%H", "--reverse", "-S", CryptAttributes.keyLine, remoteRef, "--",
                                 ".gitattributes"])
        guard let start = started.text.split(separator: "\n").first.map(String.init) else { return [] }
        let log = await git(["log", "--format=%x01%H %s", "--raw", "--no-abbrev", "--no-renames", "--diff-filter=AM",
                             "\(start)^!", remoteRef, "--not", "\(start)^@"])
        var changes: [(commit: String, subject: String, path: String, oid: String)] = []
        var commit = ""
        var subject = ""
        for line in log.text.split(separator: "\n") {
            if line.hasPrefix("\u{1}") {
                let parts = line.dropFirst().split(separator: " ", maxSplits: 1).map(String.init)
                commit = parts.first ?? ""
                subject = parts.count > 1 ? parts[1] : ""
            } else if line.hasPrefix(":") {
                // ":100644 100644 <old> <new> M\t<path>"
                let halves = line.split(separator: "\t", maxSplits: 1).map(String.init)
                let fields = halves[0].split(separator: " ")
                guard halves.count == 2, fields.count >= 4, !CryptAttributes.isExempt(halves[1]) else { continue }
                changes.append((commit, subject, halves[1], String(fields[3])))
            }
        }
        let contents = await blobs(changes.map(\.oid))
        return zip(changes, contents).compactMap { change, content in
            guard let content, !content.isEmpty, !CryptCodec.isEncrypted(content) else { return nil }
            return Leak(commit: String(change.commit.prefix(10)), subject: change.subject, path: change.path)
        }
    }

    static func leakReport(_ leaks: [Leak]) -> String {
        guard !leaks.isEmpty else { return "No file reached the remote unencrypted since the vault was encrypted." }
        let lines = leaks.map { "\($0.commit) \($0.path) (\($0.subject))" }
        return (["\(leaks.count) file(s) reached the remote unencrypted. They are encrypted again once synced, but "
                 + "these commits keep the plain text:"] + lines + [
                    "To remove them from the remote's history, see \"Removing a leak\" in docs/GIT-SYNC.md: it rewrites "
                        + "history, so Loam never does it on its own."]).joined(separator: "\n")
    }
}
