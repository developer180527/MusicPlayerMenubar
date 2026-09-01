import Foundation

/// Persists security-scoped bookmarks for the folders and files the user has
/// explicitly granted access to.
///
/// Under App Sandbox a stored path carries no authority — rebuilding a `URL`
/// from a string produces something the kernel refuses to open. Access has to
/// travel with the URL as a bookmark created at the moment the user picked it
/// in an open panel.
///
/// Individual tracks are deliberately *not* bookmarked. A library of a few
/// thousand files would mean a few thousand bookmarks to store and resolve on
/// every launch. Instead each track is expected to live underneath one of these
/// roots, and the root's security scope covers everything inside it. The number
/// of bookmarks tracks the number of times the user granted access, not the
/// size of the library.
@MainActor
final class SecurityScopedStore {

    static let shared = SecurityScopedStore()

    private static let bookmarksKey = "securityScopedBookmarks"

    private struct Root {
        let url: URL
        let bookmark: Data
        /// Whether `startAccessingSecurityScopedResource` succeeded, so that
        /// teardown can balance every start with exactly one stop.
        let isAccessing: Bool
    }

    private var entries: [Root] = []

    /// Bookmarks that didn't resolve this launch. Usually an unplugged external
    /// drive rather than a revoked grant, so they're kept and retried next time
    /// instead of forcing the user to re-authorize the folder.
    private var unresolved: [Data] = []

    /// Folders and files currently resolved and held open.
    var roots: [URL] { entries.map(\.url) }

    private init() {}

    // MARK: - Lifecycle

    /// Resolves stored bookmarks and opens access to each one.
    ///
    /// Must run before the library loads — until this completes, every track
    /// URL reads as unreachable.
    func restore() {
        guard let stored = UserDefaults.standard.array(forKey: Self.bookmarksKey) as? [Data] else {
            return
        }

        var resolved: [Root] = []
        var failed: [Data] = []

        for data in stored {
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else {
                failed.append(data)
                continue
            }

            let opened = url.startAccessingSecurityScopedResource()

            // A stale bookmark still resolved this time, but won't survive
            // another move. Rewrite it now, while access is held.
            var bookmark = data
            if isStale, let fresh = try? Self.makeBookmark(for: url) {
                bookmark = fresh
            }

            resolved.append(Root(url: url, bookmark: bookmark, isAccessing: opened))
        }

        entries = resolved
        unresolved = failed
        persist()
    }

    /// Balances every `startAccessingSecurityScopedResource` taken above.
    func releaseAll() {
        for entry in entries where entry.isAccessing {
            entry.url.stopAccessingSecurityScopedResource()
        }
        entries.removeAll()
    }

    // MARK: - Grants

    /// Records access to a URL the user just chose in an open panel.
    ///
    /// Returns `false` only if a bookmark could not be created, which means the
    /// grant cannot be persisted across launches.
    @discardableResult
    func addRoot(_ url: URL) -> Bool {
        // Already reachable through a root we hold — nothing to store.
        if isCovered(url) { return true }

        guard let bookmark = try? Self.makeBookmark(for: url) else { return false }

        let opened = url.startAccessingSecurityScopedResource()
        entries.append(Root(url: url, bookmark: bookmark, isAccessing: opened))
        persist()
        return true
    }

    func removeRoot(_ url: URL) {
        // Compare standardized paths, not URLs. `URL(fileURLWithPath:)` only
        // appends the directory slash when it can stat the path, so a caller
        // rebuilding a URL for a folder that has gone away (unplugged drive)
        // produces a value that `==` won't match — leaving a bookmark that can
        // never be removed. `isCovered` already compares this way.
        let target = url.standardizedFileURL.path
        guard let index = entries.firstIndex(
            where: { $0.url.standardizedFileURL.path == target }
        ) else { return }
        let entry = entries[index]
        if entry.isAccessing {
            entry.url.stopAccessingSecurityScopedResource()
        }
        entries.remove(at: index)
        persist()
    }

    /// Whether `url` sits inside (or is) a root we currently hold access to.
    ///
    /// Also the guard that keeps the library from being pruned when no scope is
    /// active: an uncovered URL tells us nothing about whether the file exists.
    func isCovered(_ url: URL) -> Bool {
        let target = url.standardizedFileURL.path
        return entries.contains { entry in
            let root = entry.url.standardizedFileURL.path
            if target == root { return true }
            let prefix = root.hasSuffix("/") ? root : root + "/"
            return target.hasPrefix(prefix)
        }
    }

    // MARK: - Persistence

    private func persist() {
        let all = entries.map(\.bookmark) + unresolved
        UserDefaults.standard.set(all, forKey: Self.bookmarksKey)
    }

    nonisolated private static func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }
}
