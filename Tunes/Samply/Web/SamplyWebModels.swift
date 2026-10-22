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

/// Feature-level adapter capabilities. A broken data-export build can disable
/// refresh or ownership reads without disabling status, browsing, or playback.
enum SamplyCapability: String, CaseIterable, Sendable {
    case library, boxes, browse, playback, refresh, ownership, versions
}

struct WebSnapshot: Codable, Sendable {
    struct Account: Codable, Equatable, Sendable {
        let uid: String
        var name: String?
        var avatarURL: String?
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

/// The 700 ms polling payload. It deliberately has no Library or box arrays so
/// its cost does not grow with collection size. On-demand commands still return
/// complete `WebSnapshot` values.
struct WebRuntimeSnapshot: Codable, Sendable {
    let version: Int
    var account: WebSnapshot.Account?
    var authentication: WebAuthenticationState?
    var authenticationState: WebAuthenticationState {
        if account != nil { return .signedIn }
        return authentication == .signedOut ? .signedOut : .checking
    }
    var routeID: String?
    var projectID: String?
    var levelID: String?
    let boxesReady: Bool
    var playback: WebPlayback?
    let capabilities: [String]

    init(_ snapshot: WebSnapshot) {
        version = snapshot.version
        account = snapshot.account
        authentication = snapshot.authentication
        routeID = snapshot.routeID
        projectID = snapshot.projectID
        levelID = snapshot.levelID
        boxesReady = snapshot.boxesReady
        playback = snapshot.playback
        capabilities = snapshot.capabilities
    }

    func supports(_ capability: SamplyCapability) -> Bool {
        capabilities.contains(capability.rawValue)
    }

    func validateVersion() throws {
        guard version == 1 else { throw SamplyBridgeError.contractMismatch }
    }

    func hasLoadedBoxes(routeID: String, groupID: String?,
                        expectedProjectID: String?) -> Bool {
        authenticationState == .signedIn && boxesReady &&
            self.routeID == routeID && levelID == groupID &&
            (expectedProjectID == nil || projectID == expectedProjectID)
    }
}

extension WebSnapshot {
    func supports(_ capability: SamplyCapability) -> Bool {
        capabilities.contains(capability.rawValue)
    }
    /// The adapter protocol is versioned; an unknown version must not drive
    /// native state merely because it decoded into the current shape.
    func validateVersion() throws {
        guard version == 1 else { throw SamplyBridgeError.contractMismatch }
    }

    func hasLoadedBoxes(for item: LibraryItem, groupID: String?,
                        expectedProjectID: String? = nil) -> Bool {
        hasLoadedBoxes(routeID: item.routeID, groupID: groupID,
                       expectedProjectID: expectedProjectID ?? item.projectID)
    }

    func hasLoadedBoxes(routeID: String, groupID: String?,
                        expectedProjectID: String?) -> Bool {
        authenticationState == .signedIn && boxesReady &&
            self.routeID == routeID && levelID == groupID &&
            (expectedProjectID == nil || projectID == expectedProjectID)
    }
}
