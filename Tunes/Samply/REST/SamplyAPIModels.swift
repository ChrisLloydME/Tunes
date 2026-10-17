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
