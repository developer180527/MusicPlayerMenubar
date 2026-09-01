import Foundation

struct Track: Identifiable, Hashable, Codable {

    var id: String { url.absoluteString }
    let url: URL

    var title: String
    var artist: String
    var album: String
    var duration: Double

    var searchTitle: String
    var searchArtist: String
    var searchAlbum: String

    enum CodingKeys: String, CodingKey {
        case url, title, artist, album, duration
    }

    /// A duration that is safe to store and to compute with.
    ///
    /// `CMTimeGetSeconds` yields NaN for indefinite or invalid times, and
    /// `JSONEncoder` refuses non-conforming floats — so a single such track
    /// made encoding the whole library throw, silently preventing every
    /// subsequent save. Normalizing here means no `Track` can carry one.
    private static func sanitized(_ duration: Double) -> Double {
        duration.isFinite && duration > 0 ? duration : 0
    }

    init(url: URL, title: String, artist: String, album: String, duration: Double) {
        self.url = url
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = Self.sanitized(duration)
        self.searchTitle = title.lowercased()
        self.searchArtist = artist.lowercased()
        self.searchAlbum = album.lowercased()
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decode(URL.self, forKey: .url)
        title = try c.decode(String.self, forKey: .title)
        artist = try c.decode(String.self, forKey: .artist)
        album = try c.decode(String.self, forKey: .album)
        duration = Self.sanitized(try c.decode(Double.self, forKey: .duration))
        searchTitle = title.lowercased()
        searchArtist = artist.lowercased()
        searchAlbum = album.lowercased()
    }

    static func == (lhs: Track, rhs: Track) -> Bool {
        lhs.url == rhs.url
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(url)
    }
}
