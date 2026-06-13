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
            let valid = decoded.filter { (try? $0.url.checkResourceIsReachable()) == true }
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
        importURLs(panel.urls)
    }

    func scanMusicFolder() {
        let musicURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Music")
        guard (try? musicURL.checkResourceIsReachable()) == true else {
            showStatus("Music folder not found")
            return
        }
        importURLs([musicURL])
    }

    private func importURLs(_ urls: [URL]) {
        let existingURLs = Set(tracks.map { $0.url })
        let extensions = supportedExtensions

        isScanning = true

        Task {
            let fileURLs = await Task.detached(priority: .userInitiated) {
                () -> [URL] in
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
