import Foundation

/// The web library includes shared players that the owned-projects REST API does not expose.
struct LibraryItem: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    var projectID: String?
    var playerID: String?
    var shareID: String?
    var artist: String?
    var artwork: String?
    var canUpload: Bool = false
    var isOwned: Bool = false

    var routeID: String { shareID ?? playerID ?? projectID ?? id }
}

struct WebBox: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let kind: String
    var activeID: String?
    var duration: Double?
    var isAudio: Bool
    var isProcessing: Bool
    var versionName: String?
    var childIDs: [String]
}

struct WebPlayback: Codable, Equatable, Sendable {
    var fileID: String?
    var title: String?
    var artist: String?
    var album: String?
    var artwork: String?
    var playing: Bool
    var loading: Bool
    var buffering: Bool
    var position: Double
    var duration: Double
    var volume: Double
    var quality: String?
    var error: String?
    var canGoNext: Bool
    var canGoPrevious: Bool

    static let empty = WebPlayback(playing: false, loading: false, buffering: false,
                                  position: 0, duration: 0, volume: 1,
                                  canGoNext: false, canGoPrevious: false)
}

enum WebAuthenticationState: String, Codable, Sendable {
    case checking, signedIn, signedOut
}

struct WebSnapshot: Codable, Sendable {
    struct Account: Codable, Equatable, Sendable {
        let uid: String
        var name: String?
    }
    let version: Int
    var account: Account?
    var authentication: WebAuthenticationState?
    var authenticationState: WebAuthenticationState {
        if account != nil { return .signedIn }
        // Old or incomplete adapter snapshots cannot prove that the session expired.
        return authentication == .signedOut ? .signedOut : .checking
    }
    let libraryReady: Bool
    let library: [LibraryItem]
    var routeID: String?
    var projectID: String?
    var levelID: String?
    let boxesReady: Bool
    let boxes: [WebBox]
    var playback: WebPlayback?
    let capabilities: [String]
}

extension WebSnapshot {
    func hasLoadedBoxes(for item: LibraryItem, groupID: String?) -> Bool {
        authenticationState == .signedIn && boxesReady &&
            routeID == item.routeID && levelID == groupID
    }
}
