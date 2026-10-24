import Foundation
import Testing
@testable import Tunes

private final class LoaderRequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() -> Int { lock.withLock { value += 1; return value } }
    var count: Int { lock.withLock { value } }
}

@MainActor
private final class ManualHandoffScheduler: BoundedDataHandoffScheduling {
    private var actions: [@MainActor @Sendable () -> Void] = []
    private(set) var scheduledCount = 0
    var pendingCount: Int { actions.count }

    func schedule(_ action: @escaping @MainActor @Sendable () -> Void) {
        actions.append(action)
        scheduledCount += 1
    }

    func runNext() {
        guard !actions.isEmpty else { return }
        actions.removeFirst()()
    }

    func runAll() {
        while !actions.isEmpty { actions.removeFirst()() }
    }
}

private final class LoaderSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func signal() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

private final class MultiChunkStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var headers: [String: String] = [:]
    nonisolated(unsafe) static var chunks: [Data] = []
    nonisolated(unsafe) static var finishAfterChunks = true
    nonisolated(unsafe) static var finishOnStop = false
    nonisolated(unsafe) static var onStart: (@Sendable () -> Void)?

    private let lock = NSLock()
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: Self.status,
                                             httpVersion: "HTTP/1.1",
                                             headerFields: Self.headers) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        Self.onStart?()
        for chunk in Self.chunks {
            if isStopped { return }
            client?.urlProtocol(self, didLoad: chunk)
        }
        if Self.finishAfterChunks { client?.urlProtocolDidFinishLoading(self) }
    }

    override func stopLoading() {
        let alreadyStopped = lock.withLock {
            if stopped { return true }
            stopped = true
            return false
        }
        if !alreadyStopped, Self.finishOnStop {
            // Late callback after the loader has already settled cancellation.
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    private var isStopped: Bool { lock.withLock { stopped } }
}

@MainActor
@Suite(.serialized)
struct BoundedHTTPDataLoaderTests {
    private final class Stub: URLProtocol {
        nonisolated(unsafe) static var handler:
            (@Sendable (URLRequest) throws -> (Int, [String: String], Data))?
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            do {
                let response = try Self.handler!(request)
                let http = HTTPURLResponse(url: request.url!, statusCode: response.0,
                                           httpVersion: "HTTP/1.1",
                                           headerFields: response.1)!
                client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: response.2)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
        override func stopLoading() {}
    }

    private func loader() -> BoundedHTTPDataLoader {
        BoundedHTTPDataLoader(protocolClasses: [Stub.self])
    }

    private func streamingLoader(_ scheduler: ManualHandoffScheduler) -> BoundedHTTPDataLoader {
        BoundedHTTPDataLoader(protocolClasses: [MultiChunkStub.self],
                              handoffScheduler: scheduler)
    }

    private func configureStub(status: Int = 200, headers: [String: String] = [:],
                               chunks: [Data], finishAfterChunks: Bool = true,
                               finishOnStop: Bool = false,
                               onStart: (@Sendable () -> Void)? = nil) {
        MultiChunkStub.status = status
        MultiChunkStub.headers = headers
        MultiChunkStub.chunks = chunks
        MultiChunkStub.finishAfterChunks = finishAfterChunks
        MultiChunkStub.finishOnStop = finishOnStop
        MultiChunkStub.onStart = onStart
    }

    private func waitUntil(_ condition: @escaping () -> Bool, _ message: String) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record(Comment(rawValue: message))
    }

    @Test func rejectsNonHTTPSWithoutStartingATransfer() async {
        let counter = LoaderRequestCounter()
        Stub.handler = { _ in
            _ = counter.increment()
            return (200, [:], Data())
        }
        do {
            _ = try await loader().data(from: URL(string: "http://example.test/a.png")!,
                                        maxBytes: 100)
            Issue.record("Expected an insecure URL failure")
        } catch {
            #expect((error as? BoundedHTTPDataLoader.Failure) == .insecureURL)
        }
        #expect(counter.count == 0)
    }

    @Test func rejectsANonSuccessStatus() async {
        Stub.handler = { _ in (404, [:], Data("missing".utf8)) }
        do {
            _ = try await loader().data(from: URL(string: "https://example.test/a.png")!,
                                        maxBytes: 100)
            Issue.record("Expected a bad status failure")
        } catch {
            #expect((error as? BoundedHTTPDataLoader.Failure) == .badStatus)
        }
    }

    @Test func stopsReceivingOnceTheByteLimitIsExceeded() async {
        Stub.handler = { _ in (200, [:], Data(repeating: 1, count: 128)) }
        do {
            _ = try await loader().data(from: URL(string: "https://example.test/a.png")!,
                                        maxBytes: 32)
            Issue.record("Expected an oversized failure")
        } catch {
            #expect((error as? BoundedHTTPDataLoader.Failure) == .tooLarge)
        }
    }

    @Test func returnsBoundedBytesForAValidResponse() async throws {
        let bytes = Data(repeating: 7, count: 64)
        Stub.handler = { _ in (200, ["Content-Type": "image/png"], bytes) }
        let received = try await loader().data(
            from: URL(string: "https://example.test/a.png")!, maxBytes: 64)
        #expect(received == bytes)
    }

    @Test func manyChunksUseOneBoundedHandoff() async throws {
        let scheduler = ManualHandoffScheduler()
        let chunks = (0..<8).map { Data(repeating: UInt8($0), count: 4) }
        configureStub(chunks: chunks)
        let loader = streamingLoader(scheduler)
        let task = Task {
            try await loader.data(from: URL(string: "https://example.test/a.png")!,
                                  maxBytes: 32)
        }
        await waitUntil({ scheduler.pendingCount == 1 }, "the terminal handoff was not queued")

        #expect(loader.retainedByteCount <= 32)
        #expect(loader.pendingTransferCount == 1)
        #expect(scheduler.scheduledCount == 1)
        scheduler.runAll()
        let received = try await task.value
        #expect(received == chunks.reduce(into: Data()) { $0.append($1) })
        #expect(loader.retainedByteCount == 0)
        #expect(loader.pendingTransferCount == 0)
    }

    @Test func oversizedSingleChunkIsRejectedBeforeAppend() async {
        let scheduler = ManualHandoffScheduler()
        configureStub(chunks: [Data(repeating: 1, count: 128)])
        let loader = streamingLoader(scheduler)
        let task = Task {
            try await loader.data(from: URL(string: "https://example.test/a.png")!,
                                  maxBytes: 32)
        }
        await waitUntil({ scheduler.pendingCount == 1 }, "the oversized handoff was not queued")
        #expect(loader.retainedByteCount == 0)
        #expect(loader.pendingTransferCount == 1)
        scheduler.runAll()
        await #expect(throws: BoundedHTTPDataLoader.Failure.tooLarge) { try await task.value }
        #expect(loader.retainedByteCount == 0)
    }

    @Test func manySmallChunksRetainAtMostTheByteLimit() async {
        let scheduler = ManualHandoffScheduler()
        configureStub(chunks: Array(repeating: Data(repeating: 1, count: 8), count: 10))
        let loader = streamingLoader(scheduler)
        let task = Task {
            try await loader.data(from: URL(string: "https://example.test/a.png")!,
                                  maxBytes: 32)
        }
        await waitUntil({ scheduler.pendingCount == 1 }, "the over-limit handoff was not queued")
        #expect(loader.retainedByteCount <= 32)
        #expect(loader.pendingTransferCount == 1)
        #expect(scheduler.scheduledCount == 1)
        scheduler.runAll()
        await #expect(throws: BoundedHTTPDataLoader.Failure.tooLarge) { try await task.value }
        #expect(loader.retainedByteCount == 0)
    }

    @Test func unknownContentLengthStillEnforcesTheByteLimit() async {
        let scheduler = ManualHandoffScheduler()
        configureStub(headers: [:], chunks: Array(repeating: Data(repeating: 1, count: 16), count: 3))
        let loader = streamingLoader(scheduler)
        let task = Task {
            try await loader.data(from: URL(string: "https://example.test/a.png")!,
                                  maxBytes: 32)
        }
        await waitUntil({ scheduler.pendingCount == 1 }, "the unknown-length handoff was not queued")
        #expect(loader.retainedByteCount <= 32)
        scheduler.runAll()
        await #expect(throws: BoundedHTTPDataLoader.Failure.tooLarge) { try await task.value }
    }

    @Test func falseLowContentLengthStillEnforcesTheByteLimit() async {
        let scheduler = ManualHandoffScheduler()
        configureStub(headers: ["Content-Length": "4"],
                      chunks: Array(repeating: Data(repeating: 1, count: 16), count: 3))
        let loader = streamingLoader(scheduler)
        let task = Task {
            try await loader.data(from: URL(string: "https://example.test/a.png")!,
                                  maxBytes: 32)
        }
        await waitUntil({ scheduler.pendingCount == 1 }, "the false-length handoff was not queued")
        #expect(loader.retainedByteCount <= 32)
        scheduler.runAll()
        await #expect(throws: BoundedHTTPDataLoader.Failure.tooLarge) { try await task.value }
    }

    @Test func oversizedContentLengthRejectsBeforeTheBody() async {
        let scheduler = ManualHandoffScheduler()
        configureStub(headers: ["Content-Length": "100"],
                      chunks: [Data(repeating: 1, count: 8)])
        let loader = streamingLoader(scheduler)
        let task = Task {
            try await loader.data(from: URL(string: "https://example.test/a.png")!,
                                  maxBytes: 32)
        }
        await waitUntil({ scheduler.pendingCount == 1 }, "the content-length handoff was not queued")
        #expect(loader.retainedByteCount == 0)
        scheduler.runAll()
        await #expect(throws: BoundedHTTPDataLoader.Failure.tooLarge) { try await task.value }
    }

    @Test func cancellationSettlesOnceWhenCompletionArrivesLate() async {
        let scheduler = ManualHandoffScheduler()
        let signal = LoaderSignal()
        configureStub(chunks: [Data("x".utf8)], finishAfterChunks: false,
                      finishOnStop: true, onStart: { signal.signal() })
        let loader = streamingLoader(scheduler)
        let task = Task {
            try await loader.data(from: URL(string: "https://example.test/a.png")!,
                                  maxBytes: 32)
        }
        await waitUntil({ signal.isSet }, "the transfer did not start")
        task.cancel()
        await waitUntil({ scheduler.pendingCount == 1 }, "the cancel handoff was not queued")
        #expect(scheduler.scheduledCount == 1)
        scheduler.runAll()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(loader.retainedByteCount == 0)
        #expect(loader.pendingTransferCount == 0)
    }

    @Test func cancellationBeforeDelayedHandoffWins() async {
        let scheduler = ManualHandoffScheduler()
        configureStub(chunks: [Data(repeating: 1, count: 4)])
        let loader = streamingLoader(scheduler)
        let task = Task {
            try await loader.data(from: URL(string: "https://example.test/a.png")!,
                                  maxBytes: 32)
        }
        await waitUntil({ scheduler.pendingCount == 1 }, "the success handoff was not queued")
        task.cancel()
        scheduler.runAll()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(scheduler.scheduledCount == 1)
        #expect(loader.retainedByteCount == 0)
        #expect(loader.pendingTransferCount == 0)
    }

    @Test func transportErrorsAreNotRewrittenWithURLs() async {
        Stub.handler = { _ in throw URLError(.serverCertificateUntrusted) }
        do {
            _ = try await loader().data(from: URL(string: "https://example.test/a.png")!,
                                        maxBytes: 64)
            Issue.record("Expected a transport failure")
        } catch let error as URLError {
            #expect(error.code == .serverCertificateUntrusted)
            #expect(!error.localizedDescription.contains("example.test"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
