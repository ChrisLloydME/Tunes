import Foundation

/// REST authentication and web authentication are deliberately independent.
/// Never send a PAT to a web page, media URL, or signed storage URL.
@MainActor
final class SamplyAPI {
    private let tokens: any TokenStore
    private let session: URLSession
    private let baseURL: URL
    private let diagnostics: SamplyDiagnostics
    private let clock: any MonotonicClock

    init(tokens: (any TokenStore)? = nil, session: URLSession? = nil,
         baseURL: URL = URL(string: "https://samply.app/api/v0")!,
         diagnostics: SamplyDiagnostics? = nil) {
        self.tokens = tokens ?? MemoryTokenStore()
        self.baseURL = baseURL
        self.diagnostics = diagnostics ?? .shared
        clock = SystemMonotonicClock()
        if let session { self.session = session }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 30
            config.httpShouldSetCookies = false
            config.urlCache = nil
            self.session = URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
        }
    }

    func projects(token: String? = nil, timeout: TimeInterval = 30) async throws -> [SamplyProject] {
        try await request(["projects"], token: token, timeout: timeout)
    }

    func project(projectID: String, token: String? = nil,
                 timeout: TimeInterval = 15) async throws -> SamplyProject {
        try await request(["projects", projectID], token: token, timeout: timeout)
    }

    /// Creates an empty owned project through the documented REST API.
    /// The server also creates a project-scoped player with the account's default
    /// player options; Tunes never sends those settings or repeats this request.
    func createProject(name: String, token: String? = nil,
                       timeout: TimeInterval = 30) async throws -> SamplyProject {
        struct Body: Encodable {
            let name: String
        }
        return try await request(["projects"], method: "POST",
                                 body: JSONEncoder().encode(Body(name: name)),
                                 token: token, timeout: timeout)
    }

    func boxes(projectID: String, timeout: TimeInterval = 30) async throws -> [SamplyBox] {
        try await request(["projects", projectID, "all"], timeout: timeout)
    }

    func download(projectID: String, fileID: String, timeout: TimeInterval = 30) async throws -> DownloadTicket {
        try await request(["projects", projectID, "files", fileID, "download"], timeout: timeout)
    }

    func uploadTicket(projectID: String, name: String, mimeType: String,
                      size: Int64, parentID: String?, token: String? = nil,
                      timeout: TimeInterval = 30) async throws -> UploadTicket {
        struct Body: Encodable {
            let name: String
            let mimeType: String
            let size: Int64
            let parentid: String?
        }
        return try await request(["projects", projectID, "files"], method: "POST",
                                 body: JSONEncoder().encode(Body(name: name, mimeType: mimeType,
                                                                size: size, parentid: parentID)),
                                 token: token, timeout: timeout)
    }

    /// Requests the documented project-artwork upload ticket. The subsequent
    /// storage PUT is performed by `SamplyUploader`, never by this API session.
    func artworkTicket(projectID: String, name: String, mimeType: String,
                       size: Int64, token: String? = nil,
                       timeout: TimeInterval = 30) async throws -> UploadTicket {
        struct Body: Encodable {
            let name: String
            let mimeType: String
            let size: Int64
        }
        return try await request(["projects", projectID, "artwork"], method: "POST",
                                 body: JSONEncoder().encode(Body(name: name, mimeType: mimeType,
                                                                size: size)),
                                 token: token, timeout: timeout)
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
                                        body: Data? = nil, token: String? = nil,
                                        timeout: TimeInterval = 30) async throws -> T {
        let operationID = diagnostics.nextOperationID()
        let startedAt = clock.now()
        var attemptCount = 0
        var outcome: SamplyDiagnosticOutcome = .failure
        defer {
            diagnostics.record(SamplyDiagnosticSample(
                stage: .restAttempt, command: .rest, operationID: operationID,
                duration: clock.now() - startedAt, attemptCount: attemptCount,
                outcome: outcome))
        }
        let url = try Self.resourceURL(base: baseURL, components: path)
        guard url.scheme == "https", url.host == "samply.app", url.port == nil else {
            throw SamplyError.insecureURL
        }
        guard let credential = try token ?? tokens.read(), !credential.isEmpty else { throw SamplyError.noToken }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = max(0.1, timeout)
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        for attempt in 0...2 {
            attemptCount = attempt + 1
            try Task.checkCancellation()
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw SamplyError.invalidResponse }
            let retry = response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
            if method == "GET", attempt < 2, [429, 502, 503, 504].contains(response.statusCode) {
                try await Task.sleep(for: .seconds(min(max(retry ?? pow(2, Double(attempt)), 0.5), 15)))
                continue
            }
            if response.statusCode == 401 {
                outcome = .accessDenied
                throw SamplyError.invalidToken
            }
            guard (200..<300).contains(response.statusCode) else {
                throw SamplyError.http(response.statusCode, retryAfter: retry)
            }
            do {
                let decoded = try JSONDecoder().decode(T.self, from: data)
                outcome = .success
                return decoded
            } catch { throw SamplyError.invalidResponse }
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
