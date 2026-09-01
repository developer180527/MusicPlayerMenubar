import Foundation

/// Marker for the network-capable edition.
///
/// **The boundary is structural, not a checkbox.**
///
/// Files in this folder are compiled *only* into the `MusicPlayerMenubarStream`
/// target. The local-only `MusicPlayerMenubar` target synchronizes just the
/// shared `MusicPlayerMenubar/` folder, so nothing in here can reach it — there
/// is no per-file membership to remember or get wrong.
///
/// Two rules keep that true:
///
/// 1. Networking code goes in this folder. Never in `MusicPlayerMenubar/`.
/// 2. When shared code needs to vary, put the seam behind a protocol that each
///    target injects — not a `#if` in a shared file. `STREAM_EDITION` exists as
///    an escape hatch for trivial cases (a window title, an about string), not
///    as the mechanism for feature differences.
enum StreamEdition {

    /// True in this target by construction; the local-only target never
    /// compiles this file.
    static let isNetworkCapable = true
}
