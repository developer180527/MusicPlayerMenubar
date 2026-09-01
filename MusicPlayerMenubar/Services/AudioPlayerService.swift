import Foundation
import AppKit
import AVFoundation
import Combine
import MediaPlayer

enum LoopMode: CaseIterable {
    case off
    case one
    case all

    var icon: String {
        switch self {
        case .off: return "repeat"
        case .all: return "repeat"
        case .one: return "repeat.1"
        }
    }

    var label: String {
        switch self {
        case .off: return "Loop Off"
        case .all: return "Loop All"
        case .one: return "Loop One"
        }
    }
}

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

    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObserver: NSKeyValueObservation?
    private var playlist: [Track] = []
    private var commandsConfigured = false
    /// Track whose artwork load has been started (dedup guard).
    private var currentArtworkURL: URL?
    /// Track whose artwork is actually installed in the Now Playing entry.
    private var installedArtworkURL: URL?
    private var idleTimer: Timer?
    private var savedPosition: Double = 0
    private static let idleTimeout: TimeInterval = 120

    /// Local files stream straight off disk, so a large read-ahead window only
    /// wastes RAM. 5s is enough to cover seek and decode hiccups.
    private static let forwardBuffer: TimeInterval = 5

    // MARK: - Playback

    func play(track: Track, playlist: [Track] = []) {
        playbackError = nil
        cancelIdleTimer()

        guard (try? track.url.checkResourceIsReachable()) == true else {
            showError("File not found: \(track.title)")
            return
        }

        cleanupItem()

        let item = AVPlayerItem(url: track.url)
        item.preferredForwardBufferDuration = Self.forwardBuffer
        playerItem = item

        if player == nil {
            player = AVPlayer(playerItem: item)
        } else {
            player?.replaceCurrentItem(with: item)
        }
        player?.volume = volume
        player?.play()

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

        statusObserver = item.observe(\.status, options: [.new]) { [weak self] observed, _ in
            Task { @MainActor in
                guard let self else { return }
                // The callback hops to the main actor, so the user may have
                // moved on by the time it runs. Failing an item we already
                // replaced must not stop whatever is playing now.
                guard self.playerItem === item else { return }
                self.statusObserver = nil
                if observed.status == .failed {
                    self.showError("Can't play: \(track.title)")
                    self.stop()
                }
            }
        }

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

        addEndObserver(for: item)
        addTimeObserver()
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

            let item = AVPlayerItem(url: track.url)
            item.preferredForwardBufferDuration = Self.forwardBuffer
            playerItem = item

            if player == nil {
                player = AVPlayer(playerItem: item)
                player?.volume = volume
            } else {
                player?.replaceCurrentItem(with: item)
            }

            let target = CMTime(seconds: savedPosition, preferredTimescale: 600)
            player?.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)

            addEndObserver(for: item)
            addTimeObserver()
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

    /// Drops a track from the pending queue.
    ///
    /// The queue is a snapshot taken when playback started, so deleting a track
    /// from the library otherwise leaves it there and playback walks into a
    /// file that no longer exists.
    func dropFromQueue(_ track: Track) {
        playlist.removeAll { $0.id == track.id }
    }

    func cycleLoopMode() {
        switch loopMode {
        case .off: loopMode = .all
        case .all: loopMode = .one
        case .one: loopMode = .off
        }
    }

    /// Advances to the next track.
    ///
    /// Returns whether the queue resolved the request — either by starting
    /// another track or by deliberately ending playback. `false` means the
    /// queue could say nothing about what comes next, which the caller must
    /// handle: leaving `isPlaying` set with no audio strands the UI showing a
    /// pause button and a playing menubar icon over silence.
    @discardableResult
    func playNext() -> Bool {
        guard let current = currentTrack,
              !playlist.isEmpty,
              let index = playlist.firstIndex(where: { $0.id == current.id })
        else { return false }

        let nextIndex = (index + 1) % playlist.count
        if loopMode == .off && nextIndex == 0 {
            stop()
            return true
        }
        play(track: playlist[nextIndex])
        return true
    }

    func playPrevious() {
        guard let current = currentTrack,
              !playlist.isEmpty,
              let index = playlist.firstIndex(where: { $0.id == current.id })
        else { return }

        let pos = player?.currentTime().seconds ?? savedPosition
        if pos.isFinite && pos > 3 {
            player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            savedPosition = 0
            updateNowPlayingInfo()
            return
        }

        let prevIndex = index > 0 ? index - 1 : playlist.count - 1
        play(track: playlist[prevIndex])
    }

    // MARK: - Playback Observers

    private func addTimeObserver() {
        removeTimeObserver()
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player?.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self, !self.isSeeking else { return }
                let seconds = time.seconds
                if seconds.isFinite && self.duration > 0 {
                    self.currentTime = seconds
                    self.progress = seconds / self.duration
                }
            }
        }
    }

    private func removeTimeObserver() {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
    }

    private func addEndObserver(for item: AVPlayerItem) {
        removeEndObserver()
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handlePlaybackEnd()
            }
        }
    }

    private func removeEndObserver() {
        if let observer = endObserver {
            NotificationCenter.default.removeObserver(observer)
            endObserver = nil
        }
    }

    private func handlePlaybackEnd() {
        switch loopMode {
        case .one:
            restartCurrentItem()
        case .all:
            if !playNext() { stop() }
        case .off:
            let autoPlay = UserDefaults.standard.object(forKey: "autoPlayNext") as? Bool ?? true
            if autoPlay {
                if !playNext() { stop() }
            } else {
                stop()
            }
        }
    }

    /// Rewinds and replays the current item for loop-one.
    ///
    /// Calling `play(track:)` here tore the item down and built a new one on
    /// every repeat — reopening the file, re-registering observers and
    /// re-running the duration load once per loop. Seeking to zero keeps the
    /// already-open item and costs nothing per iteration.
    private func restartCurrentItem() {
        guard let player, playerItem != nil else {
            // Item was released (idle) — fall back to a full start.
            if let track = currentTrack { play(track: track) }
            return
        }
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
        isPlaying = true
        savedPosition = 0
        progress = 0
        currentTime = 0
        updateNowPlayingInfo()
    }

    private func cleanupItem() {
        removeTimeObserver()
        removeEndObserver()
        statusObserver = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        playerItem = nil
    }

    // MARK: - Idle Memory Management

    private func startIdleTimer() {
        cancelIdleTimer()
        idleTimer = Timer.scheduledTimer(
            withTimeInterval: Self.idleTimeout,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                self?.releaseIdleResources()
            }
        }
    }

    private func cancelIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = nil
    }

    private func releaseIdleResources() {
        guard !isPlaying, player != nil else { return }
        if let player {
            let t = player.currentTime().seconds
            if t.isFinite { savedPosition = t }
        }
        cleanupItem()

        // Drop the player itself too — resume() rebuilds it from savedPosition.
        player = nil

        // Keep the Now Playing entry (so Control Center can still resume us),
        // but release the artwork image the closure is holding onto.
        if var info = MPNowPlayingInfoCenter.default().nowPlayingInfo,
           info[MPMediaItemPropertyArtwork] != nil {
            info[MPMediaItemPropertyArtwork] = nil
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
        currentArtworkURL = nil
        installedArtworkURL = nil

        ArtworkCache.shared.trimCache()
    }

    // MARK: - Now Playing Integration

    private func setupRemoteCommands() {
        guard !commandsConfigured else { return }
        commandsConfigured = true

        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }

        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }

        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayback() }
            return .success
        }

        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.playNext() }
            return .success
        }

        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.playPrevious() }
            return .success
        }

        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let time = event.positionTime
            Task { @MainActor in
                guard let self, self.duration > 0 else { return }
                self.seek(to: time / self.duration)
            }
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        guard let track = currentTrack else {
            clearNowPlayingInfo()
            return
        }

        let elapsed = player?.currentTime().seconds ?? savedPosition

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed.isFinite ? elapsed : 0,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]

        // Carry the artwork across the rebuilds that pause/seek trigger, but
        // only while it still belongs to this track. Copying it unconditionally
        // pinned the previous track's cover onto the new one — and left it
        // there for good when the new track had no artwork of its own.
        if installedArtworkURL == track.url,
           let existing = MPNowPlayingInfoCenter.default().nowPlayingInfo,
           let artwork = existing[MPMediaItemPropertyArtwork] {
            info[MPMediaItemPropertyArtwork] = artwork
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused

        loadNowPlayingArtwork(for: track)
    }

    private func clearNowPlayingInfo() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        currentArtworkURL = nil
        installedArtworkURL = nil
    }

    private func loadNowPlayingArtwork(for track: Track) {
        guard currentArtworkURL != track.url else { return }
        currentArtworkURL = track.url

        Task {
            let image = await ArtworkCache.shared.loadThumbnail(for: track, size: 150)
            guard self.currentTrack?.url == track.url,
                  var info = MPNowPlayingInfoCenter.default().nowPlayingInfo
            else { return }

            if let image {
                info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(
                    boundsSize: image.size
                ) { _ in image }
                self.installedArtworkURL = track.url
            } else {
                // No cover for this track: clear the slot rather than leaving
                // whatever was there before.
                info[MPMediaItemPropertyArtwork] = nil
                self.installedArtworkURL = nil
            }
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }

    // MARK: - Error

    private func showError(_ message: String) {
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
