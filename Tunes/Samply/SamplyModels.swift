import Foundation

struct SamplyProject: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    var artwork: String?
    var timeModified: Double?
    var playerUrl: URL?
}

struct SamplyBox: Codable, Identifiable, Hashable, Sendable {
    struct Child: Codable, Hashable, Sendable {
        let id: String
        var name: String?
    }
    let id: String
    let object: String
    let name: String
    var children: [Child]?
    var trashed: Bool?
    var hidden: Bool?
    var duration: Double?

    var isAudio: Bool { object == "file" && duration != nil }
}

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

struct UploadTicket: Codable, Sendable {
    let boxid: String
    let contentType: String
    let metadata: [String: String]
    let stackid: String?
    let url: URL
}

struct DownloadTicket: Codable, Sendable {
    let url: URL
    let expires: Double
}

enum SamplyError: LocalizedError {
    case noToken, invalidToken, invalidIdentifier, invalidResponse, insecureURL
    case http(Int, retryAfter: TimeInterval?)
    case bridgeUnavailable, webContract(String), timedOut, fileChanged

    var errorDescription: String? {
        switch self {
        case .noToken: "Add a Samply Personal Access Token in Connection Settings first."
        case .invalidToken: "Your token is invalid or expired. Update it in Connection Settings."
        case .invalidIdentifier: "Invalid Samply resource ID."
        case .invalidResponse: "Samply returned an unexpected response."
        case .insecureURL: "The server did not return a valid HTTPS address."
        case .http(let code, _):
            switch code {
            case 403: "Samply denied this operation. Check your account permissions."
            case 404: "This resource could not be found in Samply."
            case 429: "Too many requests to Samply. Please try again later."
            default: "Samply request failed (HTTP \(code))."
            }
        case .bridgeUnavailable: "Open the Samply sign-in window and wait for the page to load."
        case .webContract(let detail): "Samply web integration unavailable: \(detail)"
        case .timedOut: "Samply timed out. Open the Samply window to check your sign-in and access permissions."
        case .fileChanged: "The file has changed or cannot be read. Please select it again."
        }
    }
}
