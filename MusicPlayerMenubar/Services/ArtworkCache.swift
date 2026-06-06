import Foundation
import AppKit
import AVFoundation
import Combine

@MainActor
final class ArtworkCache: ObservableObject {

    static let shared = ArtworkCache()

    private let cache = NSCache<NSString, NSImage>()
    private var pending = Set<String>()

    private init() {
        cache.countLimit = 30
        cache.totalCostLimit = 8 * 1024 * 1024  // 8 MB max
    }

    func thumbnail(for track: Track, size: CGFloat) -> NSImage? {
        let key = cacheKey(track: track, size: size)
        if let cached = cache.object(forKey: key as NSString) {
            return cached
        }
        if !pending.contains(key) {
            pending.insert(key)
            Task.detached(priority: .utility) { [weak self] in
                let image = await Self.loadArtwork(from: track.url, size: size)
                await MainActor.run {
                    guard let self else { return }
                    self.pending.remove(key)
                    if let image {
                        let cost = Int(image.size.width * image.size.height * 4)
                        self.cache.setObject(image, forKey: key as NSString, cost: cost)
                        self.objectWillChange.send()
                    }
                }
            }
        }
        return nil
    }

    private func cacheKey(track: Track, size: CGFloat) -> String {
        "\(track.url.absoluteString)::\(Int(size))"
    }

    private static func loadArtwork(from url: URL, size: CGFloat) async -> NSImage? {
        let asset = AVURLAsset(url: url)
        do {
            let metadata = try await asset.load(.metadata)
            for item in metadata {
                if item.commonKey == .commonKeyArtwork,
                   let data = try await item.load(.dataValue),
                   let full = NSImage(data: data) {
                    return resized(full, to: size)
                }
            }
        } catch {}
        return nil
    }

    private static func resized(_ image: NSImage, to size: CGFloat) -> NSImage {
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let px = size * scale
        let newSize = NSSize(width: px, height: px)
        let thumb = NSImage(size: newSize)
        thumb.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(origin: .zero, size: newSize),
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1.0
        )
        thumb.unlockFocus()
        return thumb
    }
}
