import Foundation
import Testing
@testable import Tunes

@MainActor
struct SamplyRESTRetryPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func parsesNumericDateMalformedAndPastRetryAfter() {
        #expect(SamplyRESTRetryPolicy.parseRetryAfter("7", now: now) == 7)
        #expect(SamplyRESTRetryPolicy.parseRetryAfter("0", now: now) == 0)
        #expect(SamplyRESTRetryPolicy.parseRetryAfter(nil, now: now) == nil)
        #expect(SamplyRESTRetryPolicy.parseRetryAfter("-1", now: now) == nil)
        #expect(SamplyRESTRetryPolicy.parseRetryAfter("soon", now: now) == nil)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let future = formatter.string(from: now.addingTimeInterval(5))
        #expect(SamplyRESTRetryPolicy.parseRetryAfter(future, now: now) == 5)
        let past = formatter.string(from: now.addingTimeInterval(-60))
        #expect(SamplyRESTRetryPolicy.parseRetryAfter(past, now: now) == 0)
    }

    @Test func fallbackBackoffIsJitteredAndNeverUsesAServerWait() {
        let policy = SamplyRESTRetryPolicy(wallClock: { self.now },
                                           randomUnit: { 0.5 })
        #expect(policy.fallbackDelay(attempt: 0) == 1)
        #expect(policy.fallbackDelay(attempt: 1) == 2)
        let response = HTTPURLResponse(url: URL(string: "https://samply.app")!,
                                       statusCode: 503, httpVersion: nil,
                                       headerFields: ["Retry-After": "9"])!
        #expect(policy.retryDelay(for: response, attempt: 0) == 9)
        #expect(policy.serverDelay(for: response) == 9)
    }

    @Test func onlyTransientTransportFailuresAreRetried() {
        let policy = SamplyRESTRetryPolicy(randomUnit: { 0.5 })
        #expect(policy.shouldRetryTransport(URLError(.timedOut)))
        #expect(policy.shouldRetryTransport(URLError(.networkConnectionLost)))
        #expect(!policy.shouldRetryTransport(URLError(.cancelled)))
        #expect(!policy.shouldRetryTransport(URLError(.serverCertificateUntrusted)))
        #expect(!policy.shouldRetryTransport(URLError(.unsupportedURL)))
        #expect(!policy.shouldRetryTransport(URLError(.userAuthenticationRequired)))
    }
}

@MainActor
private final class AdvancingSleeper: Sleeper {
    let clock: ManualMonotonicClock
    private(set) var durations: [Duration] = []

    init(clock: ManualMonotonicClock) {
        self.clock = clock
    }

    func sleep(for duration: Duration) async throws {
        durations.append(duration)
        let seconds = Double(duration.components.seconds) +
            Double(duration.components.attoseconds) / 1_000_000_000_000_000_000
        clock.advance(by: seconds)
        try Task.checkCancellation()
    }
}

@MainActor
private final class BlockingSleeper: Sleeper {
    private var continuation: CheckedContinuation<Void, Error>?
    private(set) var isSleeping = false

    func sleep(for duration: Duration) async throws {
        isSleeping = true
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.continuation?.resume(throwing: CancellationError())
                self?.continuation = nil
            }
        }
    }
}

private final class RetryRequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int { lock.withLock { value += 1; return value } }
    var count: Int { lock.withLock { value } }
}

/// Fixture-only response controller for an active URLProtocol transfer.
private final class StreamingState: @unchecked Sendable {
    struct Snapshot {
        let starts: Int
        let stops: Int
        let chunks: Int
    }

    let status: Int
    let headers: [String: String]
    let chunkCount: Int
    let chunkInterval: TimeInterval
    let finishDelay: TimeInterval
    let payload: String
    private let lock = NSLock()
    private var starts = 0
    private var stops = 0
    private var chunks = 0

    init(status: Int = 200, headers: [String: String] = [:], chunkCount: Int,
         chunkInterval: TimeInterval = 0.01, finishDelay: TimeInterval = 0,
         payload: String = "[]") {
        self.status = status
        self.headers = headers
        self.chunkCount = chunkCount
        self.chunkInterval = chunkInterval
        self.finishDelay = finishDelay
        self.payload = payload
    }

    func recordStart() { lock.withLock { starts += 1 } }
    func recordStop() { lock.withLock { stops += 1 } }
    func recordChunk() { lock.withLock { chunks += 1 } }
    var snapshot: Snapshot { lock.withLock { Snapshot(starts: starts, stops: stops, chunks: chunks) } }
}

private final class StreamingStubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var state: StreamingState?

    private let queue = DispatchQueue(label: "TunesTests.streaming-stub")
    private let lock = NSLock()
    private var cancelled = false
    private var responseState: StreamingState?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let state = Self.state, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        lock.withLock { responseState = state }
        state.recordStart()
        queue.async { [weak self] in
            guard let self, !self.isCancelled,
                  let response = HTTPURLResponse(url: url, statusCode: state.status,
                                                 httpVersion: "HTTP/1.1",
                                                 headerFields: state.headers) else { return }
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if state.chunkCount == 0 {
                self.scheduleFinish(state)
            } else {
                self.sendChunk(0, state: state)
            }
        }
    }

    private func sendChunk(_ index: Int, state: StreamingState) {
        guard !isCancelled else { return }
        client?.urlProtocol(self, didLoad: Data(state.payload.utf8))
        state.recordChunk()
        if state.chunkCount < 0 || index + 1 < state.chunkCount {
            queue.asyncAfter(deadline: .now() + state.chunkInterval) { [weak self] in
                self?.sendChunk(index + 1, state: state)
            }
        } else {
            scheduleFinish(state)
        }
    }

    private func scheduleFinish(_ state: StreamingState) {
        guard state.finishDelay >= 0 else { return }
        queue.asyncAfter(deadline: .now() + state.finishDelay) { [weak self] in
            guard let self, !self.isCancelled else { return }
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        let state = lock.withLock {
            cancelled = true
            return responseState
        }
        state?.recordStop()
    }

    private var isCancelled: Bool { lock.withLock { cancelled } }
}

@MainActor
@Suite(.serialized)
struct SamplyAPIRetryTests {
    private final class Stub: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            do {
                let response = try Self.handler!(request)
                let http = HTTPURLResponse(url: request.url!, statusCode: response.0,
                                           httpVersion: "HTTP/1.1",
                                           headerFields: response.1)!
                client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(response.2.utf8))
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
        override func stopLoading() {}

        nonisolated(unsafe) static var handler:
            (@Sendable (URLRequest) throws -> (Int, [String: String], String))?
    }

    private func client(clock: ManualMonotonicClock, sleeper: any Sleeper,
                        wallClock: @escaping () -> Date,
                        handler: @escaping @Sendable (URLRequest) throws -> (Int, [String: String], String)) -> SamplyAPI {
        Stub.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Stub.self]
        let tokens = MemoryTokenStore()
        try? tokens.save("fixture-token")
        let policy = SamplyRESTRetryPolicy(wallClock: wallClock,
                                           monotonicClock: clock,
                                           sleeper: sleeper,
                                           randomUnit: { 0.5 })
        return SamplyAPI(tokens: tokens,
                         session: URLSession(configuration: config),
                         retryPolicy: policy)
    }

    private func streamingClient(state: StreamingState, clock: ManualMonotonicClock,
                                 retrySleeper: (any Sleeper)? = nil,
                                 deadlineSleeper: (any Sleeper)? = nil) -> SamplyAPI {
        StreamingStubURLProtocol.state = state
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StreamingStubURLProtocol.self]
        let tokens = MemoryTokenStore()
        try? tokens.save("fixture-token")
        let policy = SamplyRESTRetryPolicy(wallClock: { Date() },
                                           monotonicClock: clock,
                                           sleeper: retrySleeper ?? TaskSleeper(),
                                           randomUnit: { 0.5 })
        return SamplyAPI(tokens: tokens,
                         session: URLSession(configuration: config),
                         retryPolicy: policy,
                         deadlineSleeper: deadlineSleeper ?? TaskSleeper())
    }

    private func waitUntil(_ condition: @escaping () -> Bool, _ message: String) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record(Comment(rawValue: message))
    }

    @Test func numericRetryAfterIsHonoredWithinTheBudget() async throws {
        let clock = ManualMonotonicClock(time: 100)
        let sleeper = AdvancingSleeper(clock: clock)
        let counter = RetryRequestCounter()
        let api = client(clock: clock, sleeper: sleeper, wallClock: { Date() }) { _ in
            counter.increment() == 1 ? (503, ["Retry-After": "1"], "{}") : (200, [:], "[]")
        }
        let projects = try await api.projects(timeout: 10)
        #expect(projects.isEmpty)
        #expect(counter.count == 2)
        #expect(sleeper.durations == [.seconds(1)])
    }

    @Test func httpDateRetryAfterUsesTheInjectedWallClock() async throws {
        let clock = ManualMonotonicClock(time: 100)
        let sleeper = AdvancingSleeper(clock: clock)
        let counter = RetryRequestCounter()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let header = formatter.string(from: now.addingTimeInterval(5))
        let api = client(clock: clock, sleeper: sleeper, wallClock: { now }) { _ in
            counter.increment() == 1 ? (503, ["Retry-After": header], "{}") : (200, [:], "[]")
        }
        _ = try await api.projects(timeout: 20)
        #expect(counter.count == 2)
        #expect(sleeper.durations == [.seconds(5)])
    }

    @Test func serverDelayBeyondTheBudgetReturnsTheTypedErrorWithoutRetrying() async {
        let clock = ManualMonotonicClock(time: 100)
        let sleeper = AdvancingSleeper(clock: clock)
        let counter = RetryRequestCounter()
        let api = client(clock: clock, sleeper: sleeper, wallClock: { Date() }) { _ in
            counter.increment()
            return (503, ["Retry-After": "30"], "{}")
        }
        do {
            _ = try await api.projects(timeout: 3)
            Issue.record("Expected a retryable HTTP failure")
        } catch let error as SamplyError {
            guard case .http(let code, let retryAfter) = error else {
                Issue.record("Wrong error: \(error)")
                return
            }
            #expect(code == 503)
            #expect(retryAfter == 30)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(counter.count == 1)
        #expect(sleeper.durations.isEmpty)
    }

    @Test func threeAttemptsExhaustTheGETBudget() async {
        let clock = ManualMonotonicClock(time: 100)
        let sleeper = AdvancingSleeper(clock: clock)
        let counter = RetryRequestCounter()
        let api = client(clock: clock, sleeper: sleeper, wallClock: { Date() }) { _ in
            counter.increment()
            return (503, ["Retry-After": "0"], "{}")
        }
        do {
            _ = try await api.projects(timeout: 30)
            Issue.record("Expected three attempts to fail")
        } catch let error as SamplyError {
            guard case .http(let code, _) = error else {
                Issue.record("Wrong error: \(error)")
                return
            }
            #expect(code == 503)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(counter.count == 3)
    }

    @Test func transientTransportFailureRecoversWithinTheBudget() async throws {
        let clock = ManualMonotonicClock(time: 100)
        let sleeper = AdvancingSleeper(clock: clock)
        let counter = RetryRequestCounter()
        let api = client(clock: clock, sleeper: sleeper, wallClock: { Date() }) { _ in
            if counter.increment() == 1 { throw URLError(.networkConnectionLost) }
            return (200, [:], "[]")
        }
        _ = try await api.projects(timeout: 10)
        #expect(counter.count == 2)
        #expect(sleeper.durations == [.seconds(1)])
    }

    @Test func terminalResponsesAndDecodeFailuresAreNotRetried() async {
        for outcome in [(401, "{}"), (403, "{}"), (200, #"{"unexpected":true}"#)] {
            let clock = ManualMonotonicClock(time: 100)
            let sleeper = AdvancingSleeper(clock: clock)
            let counter = RetryRequestCounter()
            let api = client(clock: clock, sleeper: sleeper, wallClock: { Date() }) { _ in
                counter.increment()
                return (outcome.0, [:], outcome.1)
            }
            await #expect(throws: (any Error).self) { try await api.projects(timeout: 10) }
            #expect(counter.count == 1)
            #expect(sleeper.durations.isEmpty)
        }
    }

    @Test func certificateFailureIsTerminalWithoutRetry() async {
        let clock = ManualMonotonicClock(time: 100)
        let sleeper = AdvancingSleeper(clock: clock)
        let counter = RetryRequestCounter()
        let api = client(clock: clock, sleeper: sleeper, wallClock: { Date() }) { _ in
            _ = counter.increment()
            throw URLError(.serverCertificateUntrusted)
        }
        await #expect(throws: URLError.self) { try await api.projects(timeout: 10) }
        #expect(counter.count == 1)
        #expect(sleeper.durations.isEmpty)
    }

    @Test func cancellationDuringBackoffStopsPromptly() async {
        let clock = ManualMonotonicClock(time: 100)
        let sleeper = BlockingSleeper()
        let counter = RetryRequestCounter()
        let api = client(clock: clock, sleeper: sleeper, wallClock: { Date() }) { _ in
            counter.increment()
            return (503, ["Retry-After": "1"], "{}")
        }
        let task = Task { try await api.projects(timeout: 10) }
        for _ in 0..<500 where !sleeper.isSleeping { await Task.yield() }
        #expect(sleeper.isSleeping)
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(counter.count == 1)
    }

    @Test func activeChunkedTransferStopsAtTheAbsoluteDeadline() async {
        let clock = ManualMonotonicClock(time: 100)
        let deadline = ControllableSleeper()
        let state = StreamingState(chunkCount: 200, chunkInterval: 0.01)
        let api = streamingClient(state: state, clock: clock, deadlineSleeper: deadline)
        let task = Task { try await api.projects(timeout: 10) }
        await waitUntil({ state.snapshot.starts == 1 && state.snapshot.chunks > 0 },
                        "the chunked transfer did not start")

        let started = ContinuousClock.now
        deadline.fireAll()
        do {
            _ = try await task.value
            Issue.record("an active transfer was allowed to finish past the deadline")
        } catch let error as SamplyError {
            guard case .timedOut = error else {
                Issue.record("unexpected deadline error: \(error)")
                return
            }
        } catch {
            Issue.record("unexpected deadline failure: \(error)")
        }
        #expect(ContinuousClock.now - started < .seconds(1))

        await waitUntil({ state.snapshot.stops > 0 }, "the active URLSession task was not cancelled")
        try? await Task.sleep(for: .milliseconds(50))
        let settledChunks = state.snapshot.chunks
        try? await Task.sleep(for: .milliseconds(50))
        #expect(state.snapshot.chunks == settledChunks)
        #expect(state.snapshot.starts == 1)
        await waitUntil({ deadline.pendingCount == 0 }, "the deadline work was not cancelled")
    }

    @Test func stalledResponseReleasesAtTheDeadline() async {
        let clock = ManualMonotonicClock(time: 100)
        let deadline = ControllableSleeper()
        let state = StreamingState(chunkCount: 0, finishDelay: 2)
        let api = streamingClient(state: state, clock: clock, deadlineSleeper: deadline)
        let task = Task { try await api.projects(timeout: 10) }
        await waitUntil({ state.snapshot.starts == 1 }, "the stalled response did not start")

        let started = ContinuousClock.now
        deadline.fireAll()
        do {
            _ = try await task.value
            Issue.record("a stalled response was allowed to finish past the deadline")
        } catch let error as SamplyError {
            guard case .timedOut = error else {
                Issue.record("unexpected stalled error: \(error)")
                return
            }
        } catch {
            Issue.record("unexpected stalled failure: \(error)")
        }
        #expect(ContinuousClock.now - started < .seconds(1))
        await waitUntil({ state.snapshot.stops > 0 }, "the stalled task was not cancelled")
        #expect(state.snapshot.starts == 1)
    }

    @Test func neverCompletingTransferReleasesAtTheDeadline() async {
        let clock = ManualMonotonicClock(time: 100)
        let deadline = ControllableSleeper()
        let state = StreamingState(chunkCount: 0, finishDelay: -1)
        let api = streamingClient(state: state, clock: clock, deadlineSleeper: deadline)
        let task = Task { try await api.projects(timeout: 10) }
        await waitUntil({ state.snapshot.starts == 1 }, "the never-completing response did not start")
        // Fail rather than hang if the deadline fails to release the waiter.
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(2))
            task.cancel()
        }

        let started = ContinuousClock.now
        deadline.fireAll()
        do {
            _ = try await task.value
            Issue.record("a never-completing response was allowed to finish")
        } catch let error as SamplyError {
            guard case .timedOut = error else {
                Issue.record("unexpected never-completing error: \(error)")
                watchdog.cancel()
                return
            }
        } catch {
            Issue.record("unexpected never-completing failure: \(error)")
        }
        watchdog.cancel()
        #expect(ContinuousClock.now - started < .seconds(1))
        await waitUntil({ state.snapshot.stops > 0 }, "the never-completing task was not cancelled")
        #expect(state.snapshot.starts == 1)
    }

    @Test func successBeforeTheDeadlineIsAccepted() async throws {
        let clock = ManualMonotonicClock(time: 100)
        let deadline = ControllableSleeper()
        let state = StreamingState(chunkCount: 1, finishDelay: 0.01)
        let api = streamingClient(state: state, clock: clock, deadlineSleeper: deadline)
        let projects = try await api.projects(timeout: 10)
        #expect(projects.isEmpty)
        #expect(state.snapshot.starts == 1)
        await waitUntil({ deadline.pendingCount == 0 }, "the successful deadline was not cancelled")
    }

    @Test func successAfterTheDeadlineIsRejected() async {
        let clock = ManualMonotonicClock(time: 100)
        let deadline = ControllableSleeper()
        let state = StreamingState(chunkCount: 1, finishDelay: 1.0)
        let api = streamingClient(state: state, clock: clock, deadlineSleeper: deadline)
        let task = Task { try await api.projects(timeout: 10) }
        await waitUntil({ state.snapshot.chunks > 0 }, "the transfer did not deliver its chunk")

        clock.advance(by: 11)
        do {
            _ = try await task.value
            Issue.record("an overdue success was accepted")
        } catch let error as SamplyError {
            guard case .timedOut = error else {
                Issue.record("unexpected overdue error: \(error)")
                return
            }
        } catch {
            Issue.record("unexpected overdue failure: \(error)")
        }
        #expect(state.snapshot.starts == 1)
        await waitUntil({ deadline.pendingCount == 0 }, "the overdue deadline was not cancelled")
    }

    @Test func cancellingAnActiveTransferStopsTheTask() async {
        let clock = ManualMonotonicClock(time: 100)
        let deadline = ControllableSleeper()
        let state = StreamingState(chunkCount: 200, chunkInterval: 0.01)
        let api = streamingClient(state: state, clock: clock, deadlineSleeper: deadline)
        let task = Task { try await api.projects(timeout: 10) }
        await waitUntil({ state.snapshot.chunks > 0 }, "the transfer did not start")

        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        await waitUntil({ state.snapshot.stops > 0 }, "cancellation did not stop the active task")
        #expect(state.snapshot.starts == 1)
        await waitUntil({ deadline.pendingCount == 0 }, "cancellation left deadline work running")
    }

    @Test func postMutationIsNeverReplayed() async {
        let clock = ManualMonotonicClock(time: 100)
        let sleeper = AdvancingSleeper(clock: clock)
        let counter = RetryRequestCounter()
        let api = client(clock: clock, sleeper: sleeper, wallClock: { Date() }) { _ in
            counter.increment()
            return (503, ["Retry-After": "1"], "{}")
        }
        await #expect(throws: (any Error).self) { try await api.createProject(name: "Album") }
        #expect(counter.count == 1)
        #expect(sleeper.durations.isEmpty)
    }
}
