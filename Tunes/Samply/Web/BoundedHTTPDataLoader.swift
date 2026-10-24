import Foundation

/// Loads artwork or avatar bytes with an explicit byte limit enforced while the
/// response is received. The session is memory-only, cookie-free, rejects
/// redirects, and permits only HTTPS URLs.
@MainActor
protocol BoundedDataLoading: AnyObject {
    func data(from url: URL, maxBytes: Int) async throws -> Data
}

/// Test seam for the single terminal MainActor handoff. Production schedules
/// immediately; fixtures can delay it while inspecting retained bytes.
@MainActor
protocol BoundedDataHandoffScheduling: AnyObject {
    func schedule(_ action: @escaping @MainActor @Sendable () -> Void)
}

@MainActor
final class TaskBoundedDataHandoffScheduler: BoundedDataHandoffScheduling {
    func schedule(_ action: @escaping @MainActor @Sendable () -> Void) {
        Task { @MainActor in action() }
    }
}

@MainActor
final class BoundedHTTPDataLoader: NSObject, BoundedDataLoading, URLSessionDataDelegate, URLSessionTaskDelegate {
    enum Failure: Error, Equatable {
        case insecureURL
        case tooLarge
        case badStatus
        case notAnImage
    }

    /// One bounded receive buffer. All capacity checks and appends happen on
    /// the URLSession delegate path before a single terminal handoff.
    private final class Transfer: @unchecked Sendable {
        let maxBytes: Int
        private let completion: @Sendable (Terminal) -> Void
        private let lock = NSLock()
        private var data = Data()
        private var hasResponse = false
        private var terminal: Terminal?

        init(maxBytes: Int, completion: @escaping @Sendable (Terminal) -> Void) {
            self.maxBytes = maxBytes
            self.completion = completion
        }

        var retainedBytes: Int { lock.withLock { data.count } }

        /// Returns whether the response may continue. Non-200, non-HTTPS, or a
        /// Content-Length larger than the bound fails before any body arrives.
        func receive(_ response: HTTPURLResponse?) -> Bool {
            var terminalToSend: Terminal?
            lock.lock()
            if terminal == nil {
                hasResponse = true
                let acceptable = response?.statusCode == 200
                    && response?.url?.scheme?.lowercased() == "https"
                if !acceptable {
                    terminalToSend = Terminal(.failure(Failure.badStatus))
                } else if let length = response?.value(forHTTPHeaderField: "Content-Length")
                    .flatMap({ Int($0) }), length > maxBytes {
                    terminalToSend = Terminal(.failure(Failure.tooLarge))
                }
                terminal = terminalToSend
            }
            lock.unlock()
            if let terminalToSend { completion(terminalToSend) }
            return terminalToSend == nil
        }

        /// Returns false once this transfer can receive no more data.
        func append(_ chunk: Data) -> Bool {
            var terminalToSend: Terminal?
            var isActive = true
            lock.lock()
            if terminal == nil {
                if chunk.count > maxBytes - data.count {
                    // Reject before appending, so an oversized chunk never
                    // contributes to retained response data.
                    terminalToSend = Terminal(.failure(Failure.tooLarge))
                    terminal = terminalToSend
                    isActive = false
                } else {
                    data.append(chunk)
                }
            } else {
                isActive = false
            }
            lock.unlock()
            if let terminalToSend { completion(terminalToSend) }
            return isActive
        }

        func complete(error: Error?) {
            var terminalToSend: Terminal?
            lock.lock()
            if terminal == nil {
                if let error {
                    if (error as? URLError)?.code == .cancelled {
                        terminalToSend = Terminal(.failure(CancellationError()))
                    } else {
                        terminalToSend = Terminal(.failure(error))
                    }
                } else if !hasResponse {
                    terminalToSend = Terminal(.failure(Failure.badStatus))
                } else {
                    terminalToSend = Terminal(.success(data))
                }
                terminal = terminalToSend
            }
            lock.unlock()
            if let terminalToSend { completion(terminalToSend) }
        }

        func cancel() {
            var terminalToSend: Terminal?
            lock.lock()
            if terminal == nil {
                terminalToSend = Terminal(.failure(CancellationError()))
                terminal = terminalToSend
            }
            lock.unlock()
            if let terminalToSend { completion(terminalToSend) }
        }
    }

    private final class Terminal: @unchecked Sendable {
        let result: Result<Data, Error>
        init(_ result: Result<Data, Error>) { self.result = result }
    }

    private final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var transfers: [Int: Transfer] = [:]

        func insert(_ transfer: Transfer, for taskID: Int) {
            lock.withLock { transfers[taskID] = transfer }
        }
        func transfer(for taskID: Int) -> Transfer? {
            lock.withLock { transfers[taskID] }
        }
        func remove(_ taskID: Int) {
            _ = lock.withLock { transfers.removeValue(forKey: taskID) }
        }
        var retainedByteCount: Int {
            lock.withLock { transfers.values.reduce(0) { $0 + $1.retainedBytes } }
        }
        var count: Int { lock.withLock { transfers.count } }
    }

    private let configuration: URLSessionConfiguration
    private let handoffScheduler: any BoundedDataHandoffScheduling
    private let registry = Registry()
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private lazy var session = URLSession(configuration: configuration,
                                         delegate: self, delegateQueue: nil)

    /// Retained receive bytes and transfers awaiting the terminal handoff.
    var retainedByteCount: Int { registry.retainedByteCount }
    var pendingTransferCount: Int { registry.count }

    init(protocolClasses: [AnyClass] = [],
         handoffScheduler: (any BoundedDataHandoffScheduling)? = nil) {
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
        self.handoffScheduler = handoffScheduler ?? TaskBoundedDataHandoffScheduler()
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
        let registry = self.registry
        let transfer = Transfer(maxBytes: maxBytes) { [weak self] terminal in
            self?.scheduleHandoff(taskID: task.taskIdentifier, terminal: terminal)
        }
        registry.insert(transfer, for: task.taskIdentifier)
        let data: Data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Data, Error>) in
                if Task.isCancelled {
                    registry.remove(task.taskIdentifier)
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pending[task.taskIdentifier] = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
            registry.transfer(for: task.taskIdentifier)?.cancel()
        }
        // A caller can cancel after the terminal handoff was queued but before
        // this continuation resumed. Do not hand it a successful result.
        try Task.checkCancellation()
        return data
    }

    private nonisolated func scheduleHandoff(taskID: Int, terminal: Terminal) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.handoffScheduler.schedule { [weak self] in
                self?.finish(taskIdentifier: taskID, result: terminal.result)
            }
        }
    }

    private func finish(taskIdentifier: Int, result: Result<Data, Error>) {
        guard let continuation = pending.removeValue(forKey: taskIdentifier) else {
            registry.remove(taskIdentifier)
            return
        }
        registry.remove(taskIdentifier)
        continuation.resume(with: result)
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
        guard let transfer = registry.transfer(for: dataTask.taskIdentifier) else {
            completionHandler(.cancel)
            return
        }
        let acceptable = transfer.receive(http)
        if !acceptable { dataTask.cancel() }
        completionHandler(acceptable ? .allow : .cancel)
    }

    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                                didReceive data: Data) {
        guard let transfer = registry.transfer(for: dataTask.taskIdentifier) else { return }
        if !transfer.append(data) { dataTask.cancel() }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                didCompleteWithError error: Error?) {
        registry.transfer(for: task.taskIdentifier)?.complete(error: error)
    }
}
