import Foundation

/// REST authentication and web authentication are deliberately independent.
/// Never send a PAT to a web page, media URL, or signed storage URL.
@MainActor
final class SamplyAPI {
    private let tokens: any TokenStore
    private let session: URLSession
    private let baseURL: URL

    init(tokens: (any TokenStore)? = nil, session: URLSession? = nil,
         baseURL: URL = URL(string: "https://samply.app/api/v0")!) {
        self.tokens = tokens ?? MemoryTokenStore()
        self.baseURL = baseURL
        if let session { self.session = session }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 30
            config.httpShouldSetCookies = false
            config.urlCache = nil
            self.session = URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
        }
    }

    func projects(token: String? = nil) async throws -> [SamplyProject] {
        try await request(["projects"], token: token)
    }

    func boxes(projectID: String) async throws -> [SamplyBox] {
        try await request(["projects", projectID, "all"])
    }

    func download(projectID: String, fileID: String) async throws -> DownloadTicket {
        try await request(["projects", projectID, "files", fileID, "download"])
    }

    func uploadTicket(projectID: String, name: String, mimeType: String,
                      size: Int64, parentID: String?) async throws -> UploadTicket {
        struct Body: Encodable {
            let name: String
            let mimeType: String
            let size: Int64
            let parentid: String?
        }
        return try await request(["projects", projectID, "files"], method: "POST",
                                 body: JSONEncoder().encode(Body(name: name, mimeType: mimeType,
                                                               size: size, parentid: parentID)))
    }

    static func resourceURL(base: URL, components: [String]) throws -> URL {
        var url = base
        for component in components {
            guard !component.isEmpty, component != ".", component != "..",
                  !component.contains("/"), !component.contains("\\"),
                  !component.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else { throw SamplyError.invalidIdentifier }
            url.appendPathComponent(component)
        }
        return url
    }

    private func request<T: Decodable>(_ path: [String], method: String = "GET",
                                        body: Data? = nil, token: String? = nil) async throws -> T {
        let url = try Self.resourceURL(base: baseURL, components: path)
        guard url.scheme == "https", url.host == "samply.app", url.port == nil else {
            throw SamplyError.insecureURL
        }
        guard let credential = try token ?? tokens.read(), !credential.isEmpty else { throw SamplyError.noToken }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        for attempt in 0...2 {
            try Task.checkCancellation()
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw SamplyError.invalidResponse }
            let retry = response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
            if method == "GET", attempt < 2, [429, 502, 503, 504].contains(response.statusCode) {
                try await Task.sleep(for: .seconds(min(max(retry ?? pow(2, Double(attempt)), 0.5), 15)))
                continue
            }
            if response.statusCode == 401 { throw SamplyError.invalidToken }
            guard (200..<300).contains(response.statusCode) else {
                throw SamplyError.http(response.statusCode, retryAfter: retry)
            }
            do { return try JSONDecoder().decode(T.self, from: data) }
            catch { throw SamplyError.invalidResponse }
        }
        throw SamplyError.invalidResponse
    }
}

/// Do not forward bearer credentials or signed PUTs through unexpected redirects.
final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                               willPerformHTTPRedirection response: HTTPURLResponse,
                               newRequest request: URLRequest,
                               completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
