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
        cache.totalCostLimit = 4 * 1024 * 1024

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

    /// Caps the on-disk thumbnail cache, oldest first.
    ///
    /// Keys carry a content fingerprint, so re-tagging a file writes a new
    /// entry instead of overwriting the old one. Without a sweep those orphans
    /// would accumulate for the life of the install.
    func pruneDiskCache() {
        let dir = diskCacheDir
        Task.detached(priority: .background) {
            Self.prune(dir: dir, limit: 20 * 1024 * 1024)
        }
    }

    nonisolated private static func prune(dir: URL, limit: Int) {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return }

        var entries: [(url: URL, date: Date, size: Int)] = []
        var total = 0
        for file in files {
            guard let values = try? file.resourceValues(forKeys: Set(keys)) else { continue }
            let size = values.fileSize ?? 0
            entries.append((file, values.contentModificationDate ?? .distantPast, size))
            total += size
        }

        guard total > limit else { return }

        for entry in entries.sorted(by: { $0.date < $1.date }) {
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
            if total <= limit { break }
        }
    }

    private func diskURL(for key: String) -> URL {
        diskCacheDir.appendingPathComponent(Self.stableHash(key) + ".jpg")
    }

    /// Keyed on file *contents*, not just identity.
    ///
    /// A key of URL + size alone goes stale the moment a file's embedded
    /// artwork changes: the path is unchanged, so both cache layers keep
    /// serving the old image — and because the disk cache persists, it survives
    /// relaunches. Folding in modification time and size means re-tagged files
    /// miss the cache and get decoded fresh, while untouched files still hit.
    private func cacheKey(track: Track, size: CGFloat) -> String {
        "\(track.url.absoluteString)::\(Int(size))::\(Self.contentToken(for: track.url))"
    }

    /// Cheap content fingerprint. This is a metadata stat, not a read of the
    /// audio data, so it stays inexpensive on the synchronous scroll path.
    nonisolated private static func contentToken(for url: URL) -> String {
        // `URL` caches resource values on the instance, and `Track.url` is held
        // for the lifetime of the app — querying it directly returns whatever
        // was read the first time, which would make this fingerprint as stale
        // as the bug it exists to prevent. Drop the cache on a local copy first.
        var probe = url
        probe.removeAllCachedResourceValues()

        guard let values = try? probe.resourceValues(
            forKeys: [.contentModificationDateKey, .fileSizeKey]
        ), let modified = values.contentModificationDate else {
            // No security scope, or the file vanished. Fall back to a constant
            // so lookups stay consistent; the URL still keeps keys distinct.
            return "x"
        }
        let stamp = UInt64(max(0, modified.timeIntervalSince1970) * 1000)
        return "\(stamp)-\(values.fileSize ?? 0)"
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
