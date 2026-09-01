import Foundation
import Combine

/// The track collection and its persistence.
///
/// Split across sibling files:
///
/// - `+Import`: open panels, directory walking, metadata extraction
/// - `+Folders`: the scan folders shown in Settings
///
/// Members those files reach cannot be `private`, which Swift scopes to a
/// single file.
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

    /// Monotonic counters so a banner's dismissal timer only retires the banner
    /// it was started for.
    private var statusGeneration = 0
    private var removalGeneration = 0

    let supportedExtensions: Set<String> = [
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

    func save() {
        do {
            let data = try JSONEncoder().encode(tracks)
            try data.write(to: Self.storageURL, options: .atomic)
        } catch {
            // A silent failure here means every change since launch is lost on
            // quit, with nothing on screen to say so. Surface it.
            print("Failed to save library: \(error.localizedDescription)")
            showStatus("Couldn't save library — changes may be lost")
        }
    }

    // MARK: - Remove

    func removeTrack(_ track: Track) {
        guard let index = tracks.firstIndex(where: { $0.id == track.id }) else { return }
        let removed = tracks.remove(at: index)
        lastRemoved = RemovedTrackInfo(track: removed, index: index)
        save()

        // Match on a generation rather than the track id: removing the same
        // track twice would otherwise let the first timer retire the second
        // banner early, taking the undo option with it.
        removalGeneration += 1
        let generation = removalGeneration
        Task {
            try? await Task.sleep(for: .seconds(8))
            if removalGeneration == generation {
                lastRemoved = nil
            }
        }
    }

    func undoRemove() {
        guard let info = lastRemoved else { return }
        lastRemoved = nil

        // A rescan can re-add the file while the undo banner is still up.
        // Inserting it again would put two entries with the same id in the
        // library, and ForEach requires ids to be unique.
        guard !tracks.contains(where: { $0.id == info.track.id }) else {
            showStatus("\"\(info.track.title)\" is already in the library")
            return
        }

        let insertIndex = min(info.index, tracks.count)
        tracks.insert(info.track, at: insertIndex)
        save()
        showStatus("Restored \"\(info.track.title)\"")
    }

    func clearLibrary() {
        tracks.removeAll()
        lastRemoved = nil
        save()
    }

    // MARK: - Status

    func showStatus(_ message: String) {
        statusMessage = message
        // Same reasoning as the undo banner: comparing the text would let an
        // earlier timer retire a repeat of the same message early.
        statusGeneration += 1
        let generation = statusGeneration
        Task {
            try? await Task.sleep(for: .seconds(4))
            if statusGeneration == generation {
                statusMessage = nil
            }
        }
    }
}
