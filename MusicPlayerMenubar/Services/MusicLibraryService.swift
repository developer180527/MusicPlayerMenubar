import Foundation
import AppKit
import Combine
import UniformTypeIdentifiers

@MainActor
final class MusicLibraryService: ObservableObject {

    @Published var tracks: [Track] = []
    @Published var isScanning = false

    private let supportedExtensions: Set<String> = [
        "mp3", "m4a", "aac", "wav", "flac", "aiff", "alac", "wma", "ogg"
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
            // Filter out tracks whose files no longer exist
            tracks = decoded.filter { FileManager.default.fileExists(atPath: $0.url.path) }
            if tracks.count != decoded.count { save() }
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

        var fileURLs: [URL] = []
        for url in panel.urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                collectFiles(in: url, into: &fileURLs)
            } else if isSupportedFile(url) {
                fileURLs.append(url)
            }
        }

        let existingURLs = Set(tracks.map { $0.url })
        let newURLs = fileURLs.filter { !existingURLs.contains($0) }

        guard !newURLs.isEmpty else { return }

        isScanning = true
        Task {
            var loaded: [Track] = []
            for url in newURLs {
                let track = await MetadataService.extractMetadata(from: url)
                loaded.append(track)
            }
            self.tracks.append(contentsOf: loaded)
            self.tracks.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            self.isScanning = false
            self.save()
        }
    }

    // MARK: - Remove

    func removeTrack(_ track: Track) {
        tracks.removeAll { $0.id == track.id }
        save()
    }

    // MARK: - Helpers

    private func collectFiles(in folder: URL, into results: inout [URL]) {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for case let fileURL as URL in enumerator {
            if isSupportedFile(fileURL) {
                results.append(fileURL)
            }
        }
    }

    private func isSupportedFile(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }
}
