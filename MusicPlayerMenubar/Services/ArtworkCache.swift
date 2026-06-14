import Foundation
import AppKit
import AVFoundation

private let artworkLoadLimiter = ArtworkLoadLimiter(limit: 3)

private actor ArtworkLoadLimiter {
    private var active = 0
    private let limit: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func acquire() async {
        if active < limit {
            active += 1
        } else {
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    func release() {
        if waiters.isEmpty {
            active -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

@MainActor
final class ArtworkCache {

    static let shared = ArtworkCache()

    private let cache = NSCache<NSString, NSImage>()
    private let diskCacheDir: URL

    private init() {
        cache.countLimit = 200
        cache.totalCostLimit = 8 * 1024 * 1024

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        diskCacheDir = caches.appendingPathComponent("MusicPlayerMenubar/artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskCacheDir, withIntermediateDirectories: true)
    }

    func cachedThumbnail(for track: Track, size: CGFloat) -> NSImage? {
        let key = cacheKey(track: track, size: size)
        let nsKey = key as NSString
        if let cached = cache.object(forKey: nsKey) {
            return cached
        }
        guard let image = NSImage(contentsOfFile: diskURL(for: key).path) else { return nil }
        cache.setObject(image, forKey: nsKey, cost: Self.costFor(size: size))
        return image
    }

    func loadThumbnail(for track: Track, size: CGFloat) async -> NSImage? {
        let key = cacheKey(track: track, size: size)
        let nsKey = key as NSString
        if let cached = cache.object(forKey: nsKey) { return cached }

        let dURL = diskURL(for: key)
        if let image = NSImage(contentsOfFile: dURL.path) {
            cache.setObject(image, forKey: nsKey, cost: Self.costFor(size: size))
            return image
        }

        let url = track.url
        let image: NSImage? = await Task.detached(priority: .utility) {
            await artworkLoadLimiter.acquire()
            let result = await Self.loadArtwork(from: url, size: size)
            await artworkLoadLimiter.release()
            if let result { Self.saveToDisk(image: result, url: dURL) }
            return result
        }.value
        guard let image else { return nil }
        cache.setObject(image, forKey: nsKey, cost: Self.costFor(size: size))
        return image
    }

    func trimCache() {
        cache.removeAllObjects()
    }

    private func diskURL(for key: String) -> URL {
        diskCacheDir.appendingPathComponent(Self.stableHash(key) + ".jpg")
    }

    private func cacheKey(track: Track, size: CGFloat) -> String {
        "\(track.url.absoluteString)::\(Int(size))"
    }

    nonisolated private static func stableHash(_ string: String) -> String {
        var hash: UInt64 = 5381
        for byte in string.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        return String(hash, radix: 16)
    }

    nonisolated private static func costFor(size: CGFloat) -> Int {
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let px = size * scale
        return Int(px * px * 4)
    }

    nonisolated private static func saveToDisk(image: NSImage, url: URL) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
        else { return }
        try? jpeg.write(to: url, options: .atomic)
    }

    nonisolated private static func loadArtwork(from url: URL, size: CGFloat) async -> NSImage? {
        let asset = AVURLAsset(url: url)
        do {
            let metadata = try await asset.load(.metadata)
            for item in metadata {
                if item.commonKey == .commonKeyArtwork,
                   let data = try await item.load(.dataValue) {
                    return autoreleasepool {
                        resized(data: data, to: size)
                    }
                }
            }
        } catch {}
        return nil
    }

    nonisolated private static func resized(data: Data, to size: CGFloat) -> NSImage? {
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let px = Int(size * scale)

        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let options = [
                  kCGImageSourceThumbnailMaxPixelSize: px,
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary as? [CFString: Any],
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }

        let image = NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
        return image
    }
}
