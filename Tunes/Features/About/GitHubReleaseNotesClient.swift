import Foundation

struct GitHubReleaseNote: Decodable, Identifiable {
    let id: Int
    let name: String?
    let tagName: String
    let body: String?
    let publishedAt: Date?
    let isPrerelease: Bool
    let isDraft: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, body
        case tagName = "tag_name"
        case publishedAt = "published_at"
        case isPrerelease = "prerelease"
        case isDraft = "draft"
    }

    var displayTitle: String {
        let title = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? tagName : title
    }
}

struct GitHubReleaseNotesClient {
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 20
            self.session = URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
        }
    }

    func fetchReleases() async throws -> [GitHubReleaseNote] {
        let url = URL(string: "https://api.github.com/repos/ChrisLloydME/Tunes/releases?per_page=50")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Tunes-Release-Notes", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw ReleaseNotesError.unavailable
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([GitHubReleaseNote].self, from: data).filter { !$0.isDraft }
    }

    private enum ReleaseNotesError: Error { case unavailable }
}
