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
final class AudioPlayerService: NSObject, ObservableObject {

    @Published var currentTrack: Track?
    @Published var isPlaying = false
    @Published var progress: Double = 0
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var volume: Float = 0.7
    @Published var loopMode: LoopMode = .off
    @Published var playbackError: String?
    var isSeeking = false

    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var playlist: [Track] = []
    private var commandsConfigured = false
    private var currentArtworkURL: URL?

    // MARK: - Playback

    func play(track: Track, playlist: [Track] = []) {
        playbackError = nil

        guard (try? track.url.checkResourceIsReachable()) == true else {
            showError("File not found: \(track.title)")
            return
        }

        do {
            player = try AVAudioPlayer(contentsOf: track.url)
            player?.delegate = self
            player?.volume = volume
            player?.prepareToPlay()
            player?.play()

            currentTrack = track
            isPlaying = true
            duration = player?.duration ?? track.duration
            if !playlist.isEmpty {
                self.playlist = playlist
            }

            setupRemoteCommands()
            updateNowPlayingInfo()
            startTimer()
        } catch {
            showError("Can't play: \(track.title)")
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        updateNowPlayingInfo()
    }

    func resume() {
        guard let player, currentTrack != nil else { return }
        player.play()
        isPlaying = true
        updateNowPlayingInfo()
    }

    func togglePlayback() {
        if isPlaying {
            pause()
        } else {
            resume()
        }
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        currentTrack = nil
        progress = 0
        currentTime = 0
        duration = 0
        timer?.invalidate()
        clearNowPlayingInfo()
    }

    func seek(to progress: Double) {
        guard let player else { return }
        let targetTime = player.duration * progress
        player.currentTime = targetTime
        self.progress = progress
        self.currentTime = targetTime
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

        if let player, player.currentTime > 3 {
            player.currentTime = 0
            updateNowPlayingInfo()
            return
        }

        let prevIndex = index > 0 ? index - 1 : playlist.count - 1
        play(track: playlist[prevIndex])
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
                guard let self, let player = self.player, player.duration > 0 else { return }
                self.seek(to: time / player.duration)
            }
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        guard let track = currentTrack else {
            clearNowPlayingInfo()
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player?.currentTime ?? 0,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]

        // Preserve existing artwork if already loaded for this track
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
        // Only load once per track
        guard currentArtworkURL != track.url else { return }
        currentArtworkURL = track.url

        Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: track.url)
            do {
                let metadata = try await asset.load(.metadata)
                for item in metadata {
                    if item.commonKey == .commonKeyArtwork,
                       let data = try await item.load(.dataValue),
                       let image = NSImage(data: data) {
                        await MainActor.run { [weak self] in
                            guard let self,
                                  self.currentTrack?.url == track.url,
                                  var info = MPNowPlayingInfoCenter.default().nowPlayingInfo
                            else { return }
                            let artwork = MPMediaItemArtwork(
                                boundsSize: image.size
                            ) { _ in image }
                            info[MPMediaItemPropertyArtwork] = artwork
                            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
                        }
                        return
                    }
                }
            } catch {}
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

    // MARK: - Timer

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(
            withTimeInterval: 0.25,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player else { return }
                if player.duration > 0 && !self.isSeeking {
                    self.progress = player.currentTime / player.duration
                    self.currentTime = player.currentTime
                }
                if !player.isPlaying && self.isPlaying {
                    self.isPlaying = false
                }
            }
        }
    }

    static func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return "\(mins):\(String(format: "%02d", secs))"
    }
}

extension AudioPlayerService: AVAudioPlayerDelegate {

    nonisolated func audioPlayerDidFinishPlaying(
        _ player: AVAudioPlayer,
        successfully flag: Bool
    ) {
        Task { @MainActor in
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
    }
}
