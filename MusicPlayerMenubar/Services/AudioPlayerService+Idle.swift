import Foundation
import MediaPlayer

// Releasing the player after a long pause, so an idle menubar app isn't
// holding decoded audio and artwork it isn't using.
extension AudioPlayerService {

    func startIdleTimer() {
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

    func cancelIdleTimer() {
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
}
