import Foundation
import AVFoundation

struct MetadataService {

    static func extractMetadata(from url: URL) async -> Track {
        let asset = AVURLAsset(url: url)
        var title = url.deletingPathExtension().lastPathComponent
        var artist = "Unknown Artist"
        var album = "Unknown Album"
        var duration: Double = 0

        do {
            let metadata = try await asset.load(.metadata)
            let cmDuration = try await asset.load(.duration)
            duration = CMTimeGetSeconds(cmDuration)

            for item in metadata {
                guard let key = item.commonKey else { continue }

                switch key {
                case .commonKeyTitle:
                    if let value = try await item.load(.stringValue) {
                        title = value
                    }
                case .commonKeyArtist:
                    if let value = try await item.load(.stringValue) {
                        artist = value
                    }
                case .commonKeyAlbumName:
                    if let value = try await item.load(.stringValue) {
                        album = value
                    }
                default:
                    break
                }
            }
        } catch {
            if duration == 0 {
                if let player = try? AVAudioPlayer(contentsOf: url) {
                    duration = player.duration
                }
            }
        }

        return Track(
            url: url,
            title: title,
            artist: artist,
            album: album,
            duration: duration
        )
    }
}
