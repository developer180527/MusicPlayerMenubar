import Foundation
import AppKit

struct Track: Identifiable, Hashable {

    let id = UUID()
    let url: URL

    var title: String
    var artist: String
    var album: String
    var duration: Double
    var artwork: NSImage?

    static func == (lhs: Track, rhs: Track) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
