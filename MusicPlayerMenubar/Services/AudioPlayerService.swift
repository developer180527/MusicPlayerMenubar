import Foundation
import AppKit
import AVFoundation
import Combine
import MediaPlayer

/// Playback engine.
///
/// The type is split across several files by concern:
///
/// - this file: state, and the transport controls that act on it
/// - `+Item`: building the player item and the observers watching it
/// - `+Queue`: loop mode, advancing, and what happens when a track ends
/// - `+Idle`: releasing the player after a long pause
/// - `+NowPlaying`: Control Center integration
///
/// Members reachable from those files cannot be `private`, since Swift scopes
/// that to a single file. Anything used only within one file keeps it.
@MainActor
final class AudioPlayerService: ObservableObject {

    @Published var currentTrack: Track?
    @Published var isPlaying = false
    @Published var progress: Double = 0
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var volume: Float = 0.7
    @Published var loopMode: LoopMode = .off
    @Published var playbackError: String?
    var isSeeking = false

    var player: AVPlayer?
    var playerItem: AVPlayerItem?
    var timeObserver: Any?
    var endObserver: NSObjectProtocol?
    var statusObserver: NSKeyValueObservation?
    var playlist: [Track] = []
    var commandsConfigured = false
    /// Track whose artwork load has been started (dedup guard).
    var currentArtworkURL: URL?
    /// Track whose artwork is actually installed in the Now Playing entry.
    var installedArtworkURL: URL?
    var idleTimer: Timer?
    var savedPosition: Double = 0
    static let idleTimeout: TimeInterval = 120

    /// Local files stream straight off disk, so a large read-ahead window only
    /// wastes RAM. 5s is enough to cover seek and decode hiccups.
    static let forwardBuffer: TimeInterval = 5

    // MARK: - Playback

    func play(track: Track, playlist: [Track] = []) {
        playbackError = nil
        cancelIdleTimer()

        guard (try? track.url.checkResourceIsReachable()) == true else {
            showError("File not found: \(track.title)")
            return
        }

        cleanupItem()

        currentTrack = track
        isPlaying = true
        duration = track.duration
        savedPosition = 0
        // Without this the scrubber keeps the previous track's position until
        // the first observer tick, up to half a second of showing the wrong
        // elapsed time against the new title.
        progress = 0
        currentTime = 0
        if !playlist.isEmpty {
            self.playlist = playlist
        }

        let item = installItem(for: track)
        player?.play()

        Task {
            let loaded = try? await item.asset.load(.duration)
            // Switching tracks quickly leaves this load in flight; publishing it
            // would stamp the previous track's length onto the current one and
            // skew the scrubber and every seek computed from it.
            guard self.playerItem === item else { return }
            if let loaded, loaded.seconds.isFinite, loaded.seconds > 0 {
                self.duration = loaded.seconds
                self.updateNowPlayingInfo()
            }
        }

        setupRemoteCommands()
        updateNowPlayingInfo()
    }

    func pause() {
        if let player {
            let t = player.currentTime().seconds
            if t.isFinite { savedPosition = t }
        }
        player?.pause()
        isPlaying = false
        updateNowPlayingInfo()
        startIdleTimer()
    }

    func resume() {
        cancelIdleTimer()

        if playerItem == nil, let track = currentTrack {
            guard (try? track.url.checkResourceIsReachable()) == true else {
                showError("File not found: \(track.title)")
                return
            }

            installItem(for: track)

            let target = CMTime(seconds: savedPosition, preferredTimescale: 600)
            player?.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        }

        guard player != nil, playerItem != nil, currentTrack != nil else { return }
        player?.play()
        isPlaying = true
        updateNowPlayingInfo()
    }

    func togglePlayback() {
        if isPlaying { pause() }
        else { resume() }
    }

    func stop() {
        cancelIdleTimer()
        cleanupItem()
        player = nil
        isPlaying = false
        currentTrack = nil
        progress = 0
        currentTime = 0
        duration = 0
        savedPosition = 0
        // playNext/playPrevious both require a currentTrack, so the queue is
        // unreachable once stopped — and holding it pins every Track in the
        // last playlist, which is the entire library in the common case.
        playlist = []
        clearNowPlayingInfo()
    }

    func seek(to progress: Double) {
        // Nothing meaningful to seek within a zero-length or unknown track, and
        // a non-finite duration would produce an invalid CMTime.
        guard duration.isFinite, duration > 0, progress.isFinite else { return }
        let targetTime = duration * progress
        self.progress = progress
        self.currentTime = targetTime
        savedPosition = targetTime

        if let player {
            let cmTime = CMTime(seconds: targetTime, preferredTimescale: 600)
            player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        updateNowPlayingInfo()
    }

    func setVolume(_ newVolume: Float) {
        volume = newVolume
        player?.volume = newVolume
    }

    // MARK: - Error

    func showError(_ message: String) {
        playbackError = message
        Task {
            try? await Task.sleep(for: .seconds(4))
            if playbackError == message {
                playbackError = nil
            }
        }
    }

    // MARK: - Helpers

    static func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return "\(mins):\(String(format: "%02d", secs))"
    }
}
