import Foundation
import AppKit
import UniformTypeIdentifiers

// Choosing files, walking directories, and reading their metadata.
extension MusicLibraryService {

    /// How many files may be read for metadata at once.
    ///
    /// Each extraction holds an open `AVURLAsset` while it awaits. Adding a
    /// task per file let a large folder keep thousands of assets alive at once,
    /// spiking memory and file descriptors on exactly the imports where it
    /// hurts most.
    static var metadataConcurrency: Int { 8 }

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

    /// Walks `urls` (recursing into directories) for files with a supported
    /// extension. Kept synchronous: NSEnumerator's iterator can't be used from
    /// an async context.
    nonisolated static func audioFiles(
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

    func importURLs(_ urls: [URL]) {
        // A second import running concurrently would snapshot the same
        // existing-URL set and append the same files again. Duplicate ids in
        // the library break ForEach, which requires them to be unique.
        guard !isScanning else {
            showStatus("Already scanning")
            return
        }

        let extensions = supportedExtensions
        isScanning = true

        Task {
            let fileURLs = await Task.detached(priority: .userInitiated) {
                Self.audioFiles(in: urls, matching: extensions)
            }.value

            // Re-read after the scan: tracks may have changed while it ran.
            let existingURLs = Set(tracks.map { $0.url })
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
                var results: [Track] = []
                results.reserveCapacity(newURLs.count)
                var next = 0

                func addNext() {
                    guard next < newURLs.count else { return }
                    let url = newURLs[next]
                    next += 1
                    group.addTask { await MetadataService.extractMetadata(from: url) }
                }

                // Keep a fixed number in flight, topping up as each finishes.
                for _ in 0..<min(Self.metadataConcurrency, newURLs.count) { addNext() }
                while let track = await group.next() {
                    results.append(track)
                    addNext()
                }
                return results
            }

            // Guard once more: a removal during extraction could reintroduce a
            // track the user just deleted.
            let present = Set(tracks.map { $0.url })
            tracks.append(contentsOf: loaded.filter { !present.contains($0.url) })
            tracks.sort {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
            isScanning = false
            save()
            showStatus("Added \(loaded.count) track\(loaded.count == 1 ? "" : "s")")
        }
    }
}
