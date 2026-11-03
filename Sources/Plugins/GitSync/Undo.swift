import Foundation

extension SyncEngine {
    /// `sync.undo`: takes back what one device (an agent) committed, since a time, with new commits that revert
    /// them; history keeps both. Stops, changing nothing, when someone changed the same lines since.
    /// Returns the files it changed.
    func undo(device: String, since: Date?) async throws -> [String] {
        let listed = await git(["status", "--porcelain=v1", "-z", "--untracked-files=all"])
        guard listed.succeeded, Git.parseStatus(listed.stdout).isEmpty else {
            throw SetupError(message: "Some changes here are not committed yet: sync first (sync.now), then undo.")
        }
        let log = await git(["log", "--no-merges", "--format=%H%x02%an%x02%ct%x02%s", "HEAD"])
        let commits: [String] = log.text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\u{2}", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 4, let seconds = TimeInterval(fields[2]) else { return nil }
            let author = Self.deviceNamed(in: fields[3]) ?? fields[1]
            guard author == device else { return nil }
            if let since, Date(timeIntervalSince1970: seconds) < since { return nil }
            return fields[0]
        }
        guard !commits.isEmpty else {
            throw SetupError(message: "No commits from \(device)\(since == nil ? "" : " in that time") to undo.")
        }
        // Newest first, so each revert applies on top of the next.
        let reverted = await git(["revert", "--no-commit", "--no-edit"] + commits)
        guard reverted.succeeded else {
            _ = await git(["revert", "--abort"])
            throw SetupError(message: "Some of \(device)'s changes were changed again since, so they cannot be taken "
                             + "back on their own: nothing was changed. Undo a shorter time (since=), or by hand.")
        }
        let changed = Git.fields(await git(["diff", "--cached", "--name-only", "-z", "--no-renames"]).stdout)
        guard !changed.isEmpty else { return [] }
        let name = await deviceName()
        let count = commits.count == 1 ? "1 change" : "\(commits.count) changes"
        let commit = await git(["commit", "--quiet", "-m", "vault sync: undo \(count) by \(device) (\(name))"])
        guard commit.succeeded else {
            throw SetupError(message: "Could not commit the undo: \(Git.summary(commit.stderr))")
        }
        _ = await host.reload(changed.filter { $0.hasSuffix(".md") })
        return changed
    }

    /// `since=`: a day (2026-10-28), a time (2026-10-28T14:00), or a span back from now (30m, 6h, 2d).
    static func parseSince(_ text: String, now: Date) -> Date? {
        let text = text.trimmingCharacters(in: .whitespaces)
        if let unit = text.last, let amount = Double(text.dropLast()) {
            switch unit {
            case "m": return now.addingTimeInterval(-amount * 60)
            case "h": return now.addingTimeInterval(-amount * 3600)
            case "d": return now.addingTimeInterval(-amount * 86400)
            default: break
            }
        }
        for format in ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}
