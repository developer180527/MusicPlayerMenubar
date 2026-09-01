import Foundation
import AppKit
import Combine
import UniformTypeIdentifiers

@MainActor
final class MusicLibraryService: ObservableObject {

    @Published var tracks: [Track] = []
    @Published var isScanning = false
    @Published var statusMessage: String?
    @Published var lastRemoved: RemovedTrackInfo?
    @Published var customFolders: [URL] = []

    struct RemovedTrackInfo {
        let track: Track
        let index: Int
    }

    private let supportedExtensions: Set<String> = [
        "mp3", "m4a", "aac", "wav", "flac", "aiff", "alac"
    ]

    private static var storageURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let folder = appSupport.appendingPathComponent("MusicPlayerMenubar")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("library.json")
    }

    // MARK: - Persistence

    func loadLibrary() {
        let url = Self.storageURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode([Track].self, from: data)

            // Only drop a track when we can actually see where it lives. Under
            // the sandbox an unreachable result means "no security scope here"
            // just as often as "file deleted", and pruning on that would wipe
            // the whole library the first time a bookmark fails to resolve.
            let store = SecurityScopedStore.shared
            let valid = decoded.filter { track in
                guard store.isCovered(track.url) else { return true }
                return (try? track.url.checkResourceIsReachable()) == true
            }
            let removedCount = decoded.count - valid.count
            tracks = valid
            if removedCount > 0 {
                save()
                showStatus("\(removedCount) track\(removedCount == 1 ? "" : "s") removed — files not found")
            }
        } catch {
            print("Failed to load library: \(error.localizedDescription)")
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(tracks)
            try data.write(to: Self.storageURL, options: .atomic)
        } catch {
            print("Failed to save library: \(error.localizedDescription)")
        }
    }

    // MARK: - Add

    func addFiles() {
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio, .mp3, .mpeg4Audio, .wav, .aiff]
        panel.message = "Select music files or folders"
        panel.level = .floating

        guard panel.runModal() == .OK else { return }

        // The panel grant only lasts for this launch; bookmark it so the files
        // are still reachable next time.
        var ungranted = 0
        for url in panel.urls where !SecurityScopedStore.shared.addRoot(url) {
            ungranted += 1
        }
        if ungranted > 0 {
            showStatus("\(ungranted) item\(ungranted == 1 ? "" : "s") can't be saved for next launch")
        }

        importURLs(panel.urls)
    }

    // MARK: - Custom Folders

    private static let foldersKey = "customScanFolders"

    /// Scan folders are the subset of granted roots the user designated for
    /// rescanning. The stored paths are only an index — the authority to open
    /// them comes from the bookmark `SecurityScopedStore` holds.
    func loadCustomFolders() {
        let paths = UserDefaults.standard.stringArray(forKey: Self.foldersKey) ?? []
        let store = SecurityScopedStore.shared
        customFolders = paths
            .map { URL(fileURLWithPath: $0) }
            .filter { store.isCovered($0) }

        // A folder whose bookmark no longer resolves can never be scanned, so
        // drop it instead of leaving a dead row in Settings.
        if customFolders.count != paths.count {
            saveCustomFolders()
        }
    }

    func addCustomFolder() {
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = "Select folders to scan for music"
        panel.level = .floating

        guard panel.runModal() == .OK else { return }

        let existing = Set(customFolders.map { $0.path })
        var newFolders: [URL] = []
        var ungranted = 0
        for url in panel.urls where !existing.contains(url.path) {
            if SecurityScopedStore.shared.addRoot(url) {
                newFolders.append(url)
            } else {
                ungranted += 1
            }
        }

        if ungranted > 0 {
            showStatus("\(ungranted) folder\(ungranted == 1 ? "" : "s") couldn't be added")
        }
        guard !newFolders.isEmpty else { return }
        customFolders.append(contentsOf: newFolders)
        saveCustomFolders()
    }

    func removeCustomFolder(_ folder: URL) {
        customFolders.removeAll { $0 == folder }
        saveCustomFolders()

        // Keep the underlying grant when tracks still live inside this folder.
        // Removing it from the scan list shouldn't make those tracks unplayable.
        let prefix = folder.standardizedFileURL.path + "/"
        let stillNeeded = tracks.contains {
            $0.url.standardizedFileURL.path.hasPrefix(prefix)
        }
        if !stillNeeded {
            SecurityScopedStore.shared.removeRoot(folder)
        }
    }

    func scanCustomFolders() {
        let valid = customFolders.filter { (try? $0.checkResourceIsReachable()) == true }
        guard !valid.isEmpty else {
            showStatus("No valid folders to scan")
            return
        }
        importURLs(valid)
    }

    private func saveCustomFolders() {
        let paths = customFolders.map { $0.path }
        UserDefaults.standard.set(paths, forKey: Self.foldersKey)
    }

    /// Walks `urls` (recursing into directories) for files with a supported
    /// extension. Kept synchronous: NSEnumerator's iterator can't be used from
    /// an async context.
    nonisolated private static func audioFiles(
        in urls: [URL],
        matching extensions: Set<String>
    ) -> [URL] {
        var results: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
               isDir.boolValue {
                guard let enumerator = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }
                for case let fileURL as URL in enumerator {
                    if extensions.contains(fileURL.pathExtension.lowercased()) {
                        results.append(fileURL)
                    }
                }
            } else if extensions.contains(url.pathExtension.lowercased()) {
                results.append(url)
            }
        }
        return results
    }

    private func importURLs(_ urls: [URL]) {
        let existingURLs = Set(tracks.map { $0.url })
        let extensions = supportedExtensions

        isScanning = true

        Task {
            let fileURLs = await Task.detached(priority: .userInitiated) {
                Self.audioFiles(in: urls, matching: extensions)
            }.value

            let newURLs = fileURLs.filter { !existingURLs.contains($0) }

            guard !newURLs.isEmpty else {
                isScanning = false
                showStatus("No new tracks found")
                return
            }

            let loaded = await withTaskGroup(
                of: Track.self,
                returning: [Track].self
            ) { group in
                for url in newURLs {
                    group.addTask {
                        await MetadataService.extractMetadata(from: url)
                    }
                }
                var results: [Track] = []
                for await track in group {
                    results.append(track)
                }
                return results
            }

            tracks.append(contentsOf: loaded)
            tracks.sort {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
            isScanning = false
            save()
            showStatus("Added \(loaded.count) track\(loaded.count == 1 ? "" : "s")")
        }
    }

    // MARK: - Remove

    func removeTrack(_ track: Track) {
        guard let index = tracks.firstIndex(where: { $0.id == track.id }) else { return }
        let removed = tracks.remove(at: index)
        lastRemoved = RemovedTrackInfo(track: removed, index: index)
        save()

        let removedID = removed.id
        Task {
            try? await Task.sleep(for: .seconds(8))
            if lastRemoved?.track.id == removedID {
                lastRemoved = nil
            }
        }
    }

    func undoRemove() {
        guard let info = lastRemoved else { return }
        let insertIndex = min(info.index, tracks.count)
        tracks.insert(info.track, at: insertIndex)
        lastRemoved = nil
        save()
        showStatus("Restored \"\(info.track.title)\"")
    }

    func clearLibrary() {
        tracks.removeAll()
        lastRemoved = nil
        save()
    }

    // MARK: - Status

    private func showStatus(_ message: String) {
        statusMessage = message
        Task {
            try? await Task.sleep(for: .seconds(4))
            if statusMessage == message {
                statusMessage = nil
            }
        }
    }
}
