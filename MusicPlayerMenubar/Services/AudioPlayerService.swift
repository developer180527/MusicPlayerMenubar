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
    private var currentArtworkURL: URL?
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
        if !playlist.isEmpty {
            self.playlist = playlist
        }

        statusObserver = item.observe(\.status, options: [.new]) { [weak self] observed, _ in
            Task { @MainActor in
                guard let self else { return }
                self.statusObserver = nil
                if observed.status == .failed {
                    self.showError("Can't play: \(track.title)")
                    self.stop()
                }
            }
        }

        Task {
            if let dur = try? await item.asset.load(.duration),
               dur.seconds.isFinite && dur.seconds > 0 {
                self.duration = dur.seconds
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
        clearNowPlayingInfo()
    }

    func seek(to progress: Double) {
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

    func cycleLoopMode() {
        switch loopMode {
        case .off: loopMode = .all
        case .all: loopMode = .one
        case .one: loopMode = .off
        }
    }

    func playNext() {
        guard let current = currentTrack,
              !playlist.isEmpty,
              let index = playlist.firstIndex(where: { $0.id == current.id })
        else { return }

        let nextIndex = (index + 1) % playlist.count
        if loopMode == .off && nextIndex == 0 {
            stop()
            return
        }
        play(track: playlist[nextIndex])
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
            if let track = currentTrack {
                play(track: track)
            }
        case .all:
            playNext()
        case .off:
            let autoPlay = UserDefaults.standard.object(forKey: "autoPlayNext") as? Bool ?? true
            if autoPlay {
                playNext()
            } else {
                stop()
            }
        }
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

        if let existing = MPNowPlayingInfoCenter.default().nowPlayingInfo,
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
    }

    private func loadNowPlayingArtwork(for track: Track) {
        guard currentArtworkURL != track.url else { return }
        currentArtworkURL = track.url

        Task {
            guard let image = await ArtworkCache.shared.loadThumbnail(for: track, size: 150)
            else { return }
            guard self.currentTrack?.url == track.url,
                  var info = MPNowPlayingInfoCenter.default().nowPlayingInfo
            else { return }
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            info[MPMediaItemPropertyArtwork] = artwork
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
