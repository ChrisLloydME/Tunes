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
