import Foundation

struct Track: Identifiable, Hashable, Codable {

    var id: String { url.absoluteString }
    let url: URL

    var title: String
    var artist: String
    var album: String
    var duration: Double

    static func == (lhs: Track, rhs: Track) -> Bool {
        lhs.url == rhs.url
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(url)
    }
}
