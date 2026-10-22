import Foundation

struct SamplyProjectCreator: Codable, Hashable, Sendable {
    /// Only the documented UID is needed for response-identity comparison.
    /// Other creator fields are deliberately ignored so malformed metadata
    /// cannot make an otherwise valid creation response undecodable.
    var uid: String?

    init(uid: String? = nil) {
        self.uid = uid
    }
}

struct SamplyProject: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    var artwork: String?
    var timeModified: Double?
    var playerUrl: URL?
    /// Documented creator metadata. `creator.uid` is used only to compare a
    /// creation response with the already verified account; it is not accepted
    /// as proof of PAT identity by itself.
    var creator: SamplyProjectCreator?

    init(id: String, name: String, artwork: String? = nil,
         timeModified: Double? = nil, playerUrl: URL? = nil,
         creator: SamplyProjectCreator? = nil) {
        self.id = id
        self.name = name
        self.artwork = artwork
        self.timeModified = timeModified
        self.playerUrl = playerUrl
        self.creator = creator
    }
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

struct WebProjectOwnership: Codable, Sendable {
    let accountID: String
    let projectID: String
    let exists: Bool
    let ownerID: String?
}
