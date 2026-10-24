import Foundation

/// REST authentication and web authentication are deliberately independent.
/// Never send a PAT to a web page, media URL, or signed storage URL.
@MainActor
final class SamplyAPI {
    private let tokens: any TokenStore
    private let session: URLSession
    private let baseURL: URL
    private let diagnostics: SamplyDiagnostics
    private let retryPolicy: SamplyRESTRetryPolicy
    private let deadlineSleeper: any Sleeper
    private var clock: any MonotonicClock { retryPolicy.monotonicClock }

    init(tokens: (any TokenStore)? = nil, session: URLSession? = nil,
         baseURL: URL = URL(string: "https://samply.app/api/v0")!,
         diagnostics: SamplyDiagnostics? = nil,
         retryPolicy: SamplyRESTRetryPolicy? = nil,
         deadlineSleeper: (any Sleeper)? = nil) {
        self.tokens = tokens ?? MemoryTokenStore()
        self.baseURL = baseURL
        self.diagnostics = diagnostics ?? .shared
        self.retryPolicy = retryPolicy ?? SamplyRESTRetryPolicy()
        self.deadlineSleeper = deadlineSleeper ?? TaskSleeper()
        if let session { self.session = session }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 60
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
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }

        let isGET = method == "GET"
        let deadline = clock.now() + max(0.1, timeout)
        var attempt = 0
        while true {
            try Task.checkCancellation()
            let remaining = deadline - clock.now()
            guard remaining > 0 else { throw SamplyError.timedOut }
            // Each attempt gets only the remaining operation budget.
            request.timeoutInterval = max(0.1, remaining)
            attemptCount = attempt + 1
            do {
                let result: (Data, URLResponse)
                if isGET {
                    result = try await getData(for: request, deadline: deadline)
                } else {
                    // Mutations keep their existing timeout and uncertainty
                    // semantics; only GETs get the active transfer deadline.
                    result = try await session.data(for: request)
                }
                let (data, response) = result
                if isGET { try Task.checkCancellation() }
                guard let response = response as? HTTPURLResponse else {
                    throw SamplyError.invalidResponse
                }
                if isGET, retryPolicy.isRetryable(status: response.statusCode), attempt < 2 {
                    let delay = retryPolicy.retryDelay(for: response, attempt: attempt)
                    let remainingAfterRead = deadline - clock.now()
                    guard delay < remainingAfterRead else {
                        // Do not retry past the caller's budget or shorten a
                        // server-requested wait. Report the typed retryable error.
                        throw SamplyError.http(response.statusCode, retryAfter: delay)
                    }
                    try await retryPolicy.sleep(for: delay)
                    attempt += 1
                    continue
                }
                if response.statusCode == 401 {
                    outcome = .accessDenied
                    throw SamplyError.invalidToken
                }
                guard (200..<300).contains(response.statusCode) else {
                    throw SamplyError.http(response.statusCode,
                                           retryAfter: retryPolicy.serverDelay(for: response))
                }
                do {
                    let decoded = try JSONDecoder().decode(T.self, from: data)
                    outcome = .success
                    return decoded
                } catch {
                    throw SamplyError.invalidResponse
                }
            } catch let failure as URLError where isGET
                && retryPolicy.shouldRetryTransport(failure) && attempt < 2 {
                let delay = retryPolicy.fallbackDelay(attempt: attempt)
                let remainingAfterFailure = deadline - clock.now()
                guard delay < remainingAfterFailure else { throw failure }
                try await retryPolicy.sleep(for: delay)
                attempt += 1
            } catch let failure as URLError {
                outcome = failure.code == .cancelled ? .cancelled : .failure
                throw failure
            }
        }
    }

    /// One GET attempt with an absolute operation deadline. The waiter is
    /// released at the deadline even if the transfer keeps producing data; the
    /// active URLSession task is cancelled and its later completion ignored.
    private func getData(for request: URLRequest,
                         deadline: TimeInterval) async throws -> (Data, URLResponse) {
        try Task.checkCancellation()
        let remaining = deadline - clock.now()
        guard remaining > 0 else { throw SamplyError.timedOut }
        let attempt = SamplyRESTGetAttempt(
            session: session, request: request, deadline: deadline,
            clock: clock, sleeper: deadlineSleeper)
        do {
            let result = try await attempt.run()
            try Task.checkCancellation()
            guard clock.now() < deadline else { throw SamplyError.timedOut }
            return result
        } catch {
            // A caller cancellation that raced the deadline still reports as
            // cancellation, not as an expired operation.
            try Task.checkCancellation()
            throw error
        }
    }

}

/// Exactly-once settlement for one cancellable GET task. The deadline can
/// resume the waiter while URLSession is still delivering an active response,
/// then the task is cancelled and its eventual callback is ignored.
@MainActor
private final class SamplyRESTGetAttempt {
    private let session: URLSession
    private let request: URLRequest
    private let deadline: TimeInterval
    private let clock: any MonotonicClock
    private let sleeper: any Sleeper
    private var task: URLSessionDataTask?
    private var deadlineTask: Task<Void, Never>?
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private var bufferedResult: Result<(Data, URLResponse), Error>?
    private var isFinished = false

    init(session: URLSession, request: URLRequest, deadline: TimeInterval,
         clock: any MonotonicClock, sleeper: any Sleeper) {
        self.session = session
        self.request = request
        self.deadline = deadline
        self.clock = clock
        self.sleeper = sleeper
    }

    func run() async throws -> (Data, URLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let bufferedResult {
                    continuation.resume(with: bufferedResult)
                    return
                }
                self.continuation = continuation
                let task = session.dataTask(with: request) { [self] data, response, error in
                    Task { @MainActor in
                        complete(data: data, response: response, error: error)
                    }
                }
                self.task = task
                deadlineTask = Task { [self] in
                    let remaining = deadline - clock.now()
                    guard remaining > 0 else {
                        finish(.failure(SamplyError.timedOut))
                        return
                    }
                    do { try await sleeper.sleep(for: .seconds(remaining)) }
                    catch { return }
                    guard !Task.isCancelled else { return }
                    finish(.failure(SamplyError.timedOut))
                }
                if !isFinished { task.resume() }
            }
        } onCancel: {
            Task { @MainActor [self] in
                finish(.failure(CancellationError()))
            }
        }
    }

    private func complete(data: Data?, response: URLResponse?, error: Error?) {
        if let error {
            // URLSession reports a locally cancelled task as URLError.cancelled.
            // Preserve the caller's cancellation type regardless of which
            // callback wins the race with our cancellation handler.
            if let urlError = error as? URLError, urlError.code == .cancelled {
                finish(.failure(CancellationError()))
            } else {
                finish(.failure(error))
            }
        } else if let data, let response {
            finish(.success((data, response)))
        } else {
            finish(.failure(SamplyError.invalidResponse))
        }
    }

    private func finish(_ result: Result<(Data, URLResponse), Error>) {
        guard !isFinished else { return }
        isFinished = true
        deadlineTask?.cancel()
        deadlineTask = nil
        if case .failure = result {
            task?.cancel()
        }
        task = nil
        if let continuation {
            self.continuation = nil
            continuation.resume(with: result)
        } else {
            bufferedResult = result
        }
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
