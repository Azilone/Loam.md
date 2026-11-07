import Foundation

extension SyncEngine {
    /// Files whose presence says a repository is a software project, not a vault.
    static let projectMarkers: Set<String> = [
        "Package.swift", "package.json", "Cargo.toml", "go.mod", "pyproject.toml", "setup.py", "pom.xml",
        "build.gradle", "Gemfile", "composer.json", "Makefile", "CMakeLists.txt", "Dockerfile",
    ]
    static let noteExtensions: Set<String> = ["md", "markdown", "txt", "canvas", "base", "excalidraw"]

    /// Why the first sync must not join the remote, or nil when it may. Joining merges the remote's whole history into
    /// the vault (its files land among the notes) and pushes the notes into it, so a repository that is not a vault
    /// (a codebase, a photo library) stops here, before anything is merged or pushed. A remote made by Loam (its
    /// commits, `.loam/`, its encryption key) or a remote of notes passes, and so does an empty one.
    func foreignRemoteReason(remote: String, remoteRef: String, branch: String, hasRemoteRef: Bool,
                             hasHead: Bool) async -> String? {
        let address = Git.redact(await git(["remote", "get-url", remote]).text)
        guard hasRemoteRef else {
            // No branch of that name, but others: a repository with its own work (`master`), where pushing would
            // start a branch of notes beside the code.
            let heads = await git(["ls-remote", "--heads", remote], timeout: Self.networkTimeout)
            let names = heads.text.split(separator: "\n")
                .compactMap { $0.split(separator: "\t").last?.replacingOccurrences(of: "refs/heads/", with: "") }
            guard heads.succeeded, !names.isEmpty else { return nil }
            return "\(address) is not empty: it has the branch \(names.prefix(3).joined(separator: ", ")) but no "
                + "\(branch). Sync with an empty repository, or name its branch (branch=\(names[0])) if it really is "
                + "the vault. To go ahead anyway: sync.setup confirm=foreign-remote."
        }
        // A vault already shares its history with the remote: nothing to join.
        if hasHead, (await git(["merge-base", "HEAD", remoteRef])).succeeded { return nil }

        let listed = await git(["ls-tree", "-r", "--name-only", "-z", remoteRef])
        let files = Git.fields(listed.stdout)
        guard listed.succeeded, !files.isEmpty else { return nil }
        if await remoteDeclaredKey(remoteRef) != nil || files.contains(where: { $0.hasPrefix(".loam/") }) { return nil }
        let subjects = await git(["log", "-n", "200", "--format=%s", remoteRef]).text.split(separator: "\n")
        if subjects.contains(where: { $0.hasPrefix("vault backup:") || $0.hasPrefix("vault sync:") }) { return nil }

        let names = files.map { ($0 as NSString).lastPathComponent }
        let markers = names.filter { Self.projectMarkers.contains($0) || $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".sln") }
        let notes = files.filter { Self.noteExtensions.contains(($0 as NSString).pathExtension.lowercased()) }.count
        guard !markers.isEmpty || notes * 2 < files.count else { return nil }
        let shown: [String] = markers.isEmpty ? Array(files.prefix(3)) : Array(Array(Set(markers)).sorted().prefix(3))
        let sample = shown.joined(separator: ", ")
        return "\(address) holds \(files.count) files that do not look like a vault (\(sample)). Joining would copy "
            + "them into this vault and push your notes into that repository, so nothing was merged or pushed. Use "
            + "an empty repository. If you are sure, run sync.setup confirm=foreign-remote."
    }

    /// Keeps where this clone stood before a merge (`refs/loam/before-merge`) and before it first joined a remote
    /// (`refs/loam/before-join`), so whatever a merge brings in can be taken back with plain git
    /// (`git reset --hard refs/loam/before-join`). Never pushed. Local changes are already committed by then.
    func markBeforeMerge(joining: Bool) async {
        _ = await git(["update-ref", "refs/loam/before-merge", "HEAD"])
        if joining { _ = await git(["update-ref", "refs/loam/before-join", "HEAD"]) }
    }
}
