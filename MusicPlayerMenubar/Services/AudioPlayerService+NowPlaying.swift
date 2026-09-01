import Foundation
import AppKit
import MediaPlayer

// Control Center and the media keys.
extension AudioPlayerService {

    func setupRemoteCommands() {
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

    func updateNowPlayingInfo() {
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

    func clearNowPlayingInfo() {
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
}
