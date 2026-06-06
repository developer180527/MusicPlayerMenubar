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

    func scanLibrary() {
        let musicFolder =
            FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Music")
        scanFolder(musicFolder)
    }

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
        }
    }

    private func scanFolder(_ folder: URL) {
        isScanning = true

        var fileURLs: [URL] = []
        collectFiles(in: folder, into: &fileURLs)

        let existingURLs = Set(tracks.map { $0.url })
        let newURLs = fileURLs.filter { !existingURLs.contains($0) }

        guard !newURLs.isEmpty else {
            isScanning = false
            return
        }

        Task {
            var loaded: [Track] = []
            for url in newURLs {
                let track = await MetadataService.extractMetadata(from: url)
                loaded.append(track)
            }
            self.tracks.append(contentsOf: loaded)
            self.tracks.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            self.isScanning = false
        }
    }

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
