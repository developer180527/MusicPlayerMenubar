import Foundation
import AVFoundation

// Building the player item, and the observers that watch it.
extension AudioPlayerService {

    /// Creates the player item for `track` and attaches everything that watches
    /// it.
    ///
    /// Both `play` and `resume` need this. Keeping two copies is how `resume`
    /// came to have no status observer: a file that was reachable but
    /// unplayable failed there with nothing watching, leaving the interface
    /// claiming playback over silence.
    @discardableResult
    func installItem(for track: Track) -> AVPlayerItem {
        let item = AVPlayerItem(url: track.url)
        item.preferredForwardBufferDuration = Self.forwardBuffer
        playerItem = item

        if player == nil {
            player = AVPlayer(playerItem: item)
        } else {
            player?.replaceCurrentItem(with: item)
        }
        player?.volume = volume

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

        addEndObserver(for: item)
        addTimeObserver()
        return item
    }

    func addTimeObserver() {
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

    func removeTimeObserver() {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
    }

    func addEndObserver(for item: AVPlayerItem) {
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

    func removeEndObserver() {
        if let observer = endObserver {
            NotificationCenter.default.removeObserver(observer)
            endObserver = nil
        }
    }

    /// Rewinds and replays the current item for loop-one.
    ///
    /// Calling `play(track:)` here tore the item down and built a new one on
    /// every repeat — reopening the file, re-registering observers and
    /// re-running the duration load once per loop. Seeking to zero keeps the
    /// already-open item and costs nothing per iteration.
    func restartCurrentItem() {
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

    func cleanupItem() {
        removeTimeObserver()
        removeEndObserver()
        statusObserver = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        playerItem = nil
    }
}
