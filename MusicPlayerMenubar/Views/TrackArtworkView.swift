import SwiftUI

/// Album art for one track, loaded independently of its neighbours.
///
/// Deliberately owns its own state rather than reading a shared observable:
/// an `@ObservedObject` cache republishing on every load re-rendered the whole
/// list, which is what made scrolling expensive.
struct TrackArtworkView: View {
    let track: Track?
    let size: CGFloat
    @State private var image: NSImage?

    /// Which track `image` was loaded for.
    ///
    /// `LazyVStack` recycles rows, and `State(initialValue:)` in `init` only
    /// applies the first time SwiftUI creates state for a view identity — on
    /// reuse it's discarded. Without this guard the previous track's artwork
    /// renders until `.task` catches up.
    @State private var loadedID: String?

    init(track: Track?, size: CGFloat) {
        self.track = track
        self.size = size
        if let track {
            _image = State(initialValue: ArtworkCache.shared.cachedThumbnail(for: track, size: size))
            _loadedID = State(initialValue: track.id)
        }
    }

    var body: some View {
        Group {
            if let image, loadedID == track?.id {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color(nsColor: .controlBackgroundColor)
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.35))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.15))
        .task(id: track?.id) {
            guard let track else {
                image = nil
                loadedID = nil
                return
            }
            if let cached = ArtworkCache.shared.cachedThumbnail(for: track, size: size) {
                image = cached
                loadedID = track.id
                return
            }
            image = nil
            let loaded = await ArtworkCache.shared.loadThumbnail(for: track, size: size)
            // `.task(id:)` cancels this when the row is recycled onto another
            // track, but the decode itself never checks cancellation, so
            // execution resumes here regardless. Comparing against `self.track`
            // would not help: the closure captured the view struct by value, so
            // it still holds the track this task started for.
            guard !Task.isCancelled else { return }
            image = loaded
            loadedID = track.id
        }
    }
}
