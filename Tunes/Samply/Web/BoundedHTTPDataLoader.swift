import Foundation

/// Loads artwork or avatar bytes with an explicit byte limit enforced while the
/// response is received. The session is memory-only, cookie-free, rejects
/// redirects, and permits only HTTPS URLs.
@MainActor
protocol BoundedDataLoading: AnyObject {
    func data(from url: URL, maxBytes: Int) async throws -> Data
}

@MainActor
final class BoundedHTTPDataLoader: NSObject, BoundedDataLoading, URLSessionDataDelegate, URLSessionTaskDelegate {
    enum Failure: Error, Equatable {
        case insecureURL
        case tooLarge
        case badStatus
        case notAnImage
    }

    private struct Pending {
        let maxBytes: Int
        let continuation: CheckedContinuation<Data, Error>
        var data = Data()
        var response: HTTPURLResponse?
        var exceeded = false
    }

    private let configuration: URLSessionConfiguration
    private var pending: [Int: Pending] = [:]
    private lazy var session = URLSession(configuration: configuration,
                                         delegate: self, delegateQueue: nil)

    init(protocolClasses: [AnyClass] = []) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        if !protocolClasses.isEmpty { configuration.protocolClasses = protocolClasses }
        self.configuration = configuration
        super.init()
    }

    func data(from url: URL, maxBytes: Int) async throws -> Data {
        guard url.scheme?.lowercased() == "https", url.host != nil else {
            throw Failure.insecureURL
        }
        guard maxBytes > 0 else { throw Failure.tooLarge }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pending[task.taskIdentifier] = Pending(maxBytes: maxBytes,
                                                       continuation: continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: - URLSession delegate

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                willPerformHTTPRedirection response: HTTPURLResponse,
                                newRequest request: URLRequest,
                                completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // Artwork redirects are not followed, so credentialed policy cannot leak
        // into an image transfer.
        completionHandler(nil)
    }

    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                                didReceive response: URLResponse,
                                completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let http = response as? HTTPURLResponse
        Task { @MainActor [weak self] in
            guard let self, var entry = self.pending[dataTask.taskIdentifier] else {
                completionHandler(.cancel)
                return
            }
            entry.response = http
            self.pending[dataTask.taskIdentifier] = entry
            let acceptable = http?.statusCode == 200
                && http?.url?.scheme?.lowercased() == "https"
            if !acceptable { dataTask.cancel() }
            completionHandler(acceptable ? .allow : .cancel)
        }
    }

    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                                didReceive data: Data) {
        Task { @MainActor [weak self] in
            guard let self, var entry = self.pending[dataTask.taskIdentifier] else { return }
            entry.data.append(data)
            if entry.data.count > entry.maxBytes {
                entry.exceeded = true
                self.pending[dataTask.taskIdentifier] = entry
                dataTask.cancel()
            } else {
                self.pending[dataTask.taskIdentifier] = entry
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                didCompleteWithError error: Error?) {
        Task { @MainActor [weak self] in
            self?.finish(taskIdentifier: task.taskIdentifier, error: error)
        }
    }

    private func finish(taskIdentifier: Int, error: Error?) {
        guard let entry = pending.removeValue(forKey: taskIdentifier) else { return }
        if entry.exceeded {
            entry.continuation.resume(throwing: Failure.tooLarge)
            return
        }
        if let response = entry.response, response.statusCode != 200 {
            entry.continuation.resume(throwing: Failure.badStatus)
            return
        }
        if let error {
            if (error as? URLError)?.code == .cancelled {
                entry.continuation.resume(throwing: CancellationError())
            } else {
                entry.continuation.resume(throwing: error)
            }
            return
        }
        entry.continuation.resume(returning: entry.data)
    }
}
