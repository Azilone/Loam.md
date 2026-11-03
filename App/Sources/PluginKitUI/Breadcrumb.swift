import Foundation

/// The folders a page lives in, from the vault's root down, for the page toolbar's trail ("Areas › nested folder").
///
/// Pure and Foundation-only: the toolbar draws it and tries `candidates` from the fullest to the shortest, keeping the
/// first that fits its width.
public struct Breadcrumb: Equatable, Sendable {
    public struct Segment: Equatable, Sendable {
        public let title: String
        /// The vault-relative folder the segment names; nil for the ellipsis standing for folders left out.
        public let folder: String?

        public var isEllipsis: Bool { folder == nil }
    }

    /// The folders, outermost first.
    public let folders: [Segment]

    public var isEmpty: Bool { folders.isEmpty }

    /// The trail of the page `resource` shows: the folders around a note or a file, around a folder (not the folder
    /// itself, which is the page), around the note a virtual page is about (`kanban:Boards/Projects.md`). A page in
    /// the vault's root, or one that is no path at all (`calendar:2026-10`), has none.
    public init(resource: Resource) {
        let path: String
        switch resource.kind {
        case .file, .folder:
            path = resource.path
        case .virtual:
            guard let colon = resource.path.firstIndex(of: ":") else { self.init(folders: []); return }
            path = String(resource.path[resource.path.index(after: colon)...])
        }
        let parts = path.split(separator: "/").map(String.init)
        // A virtual page without a slash (`calendar:2026-10`) names no place.
        guard parts.count > 1 else { self.init(folders: []); return }
        self.init(folderNames: Array(parts.dropLast()))
    }

    public init(folderNames: [String]) {
        var prefix = ""
        self.init(folders: folderNames.map { name in
            prefix += (prefix.isEmpty ? "" : "/") + name
            return Segment(title: name, folder: prefix)
        })
    }

    private init(folders: [Segment]) {
        self.folders = folders
    }

    /// The ways to show the trail, the fullest first, each shorter than the one before: all the folders; the first,
    /// an ellipsis and the last; an ellipsis and the last; the last alone. The last folder, where the page is, is in
    /// every one of them. A short trail has fewer.
    public var candidates: [[Segment]] {
        guard let first = folders.first, let last = folders.last else { return [] }
        let ellipsis = Segment(title: "…", folder: nil)
        var result = [folders]
        if folders.count > 2 { result.append([first, ellipsis, last]) }
        if folders.count > 1 { result.append([ellipsis, last]) }
        if folders.count > 1 { result.append([last]) }
        return result
    }
}
