import Foundation

enum LoopMode: CaseIterable {
    case off
    case one
    case all

    var icon: String {
        switch self {
        case .off: return "repeat"
        case .all: return "repeat"
        case .one: return "repeat.1"
        }
    }

    var label: String {
        switch self {
        case .off: return "Loop Off"
        case .all: return "Loop All"
        case .one: return "Loop One"
        }
    }
}
