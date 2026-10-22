import Foundation
import Testing
@testable import Tunes

/// Test transport that records invocations and lets a test decide when (or
/// whether) each completion arrives. No page is loaded and no traffic is sent.
@MainActor
final class ControllableBridgeTransport: SamplyBridgeTransport {
    struct Invocation {
        let command: String
        let arguments: [String: Any]
        let completion: @MainActor (Result<Any?, Error>) -> Void
    }

    private(set) var invocations: [Invocation] = []

    var count: Int { invocations.count }

    func invoke(command: String, arguments: [String: Any],
                completion: @escaping @MainActor (Result<Any?, Error>) -> Void) {
        invocations.append(Invocation(command: command, arguments: arguments, completion: completion))
    }

    func complete(_ index: Int, with json: String) {
        invocations[index].completion(.success(json))
    }

    func fail(_ index: Int, with error: Error) {
        invocations[index].completion(.failure(error))
    }
}

@MainActor
struct SamplyWebSessionBridgeTests {
    private let snapshotJSON = """
    {"payload":{"version":1,"account":{"uid":"fixture-account"},"authentication":"signedIn",\
    "libraryReady":true,"library":[],"boxesReady":false,"boxes":[],"capabilities":["library"]}}
    """

    private let otherSnapshotJSON = """
    {"payload":{"version":1,"account":{"uid":"other-account"},"authentication":"signedIn",\
    "libraryReady":true,"library":[],"boxesReady":false,"boxes":[],"capabilities":["library"]}}
    """

    private func waitForInvocation(_ transport: ControllableBridgeTransport,
                                   count: Int = 1) async {
        for _ in 0..<500 {
            if transport.count >= count { return }
            await Task.yield()
        }
        Issue.record("bridge transport was not invoked")
    }

    @Test func delayedCompletionIsDecodedAndMeasured() async throws {
        let transport = ControllableBridgeTransport()
        let diagnostics = SamplyDiagnostics(isEnabled: true)
        let session = SamplyWebSession(diagnostics: diagnostics, transport: transport)
        let task: Task<WebSnapshot, Error> = Task { try await session.call("snapshot") }
        await waitForInvocation(transport)
        #expect(transport.invocations[0].command == "snapshot")
        transport.complete(0, with: snapshotJSON)

        let snapshot = try await task.value
        #expect(snapshot.account?.uid == "fixture-account")
        #expect(diagnostics.aggregate(stage: .bridgeInvocation)?.count == 1)
        #expect(diagnostics.aggregate(stage: .bridgeInvocation)?.responseBytes == snapshotJSON.utf8.count)
        #expect(diagnostics.aggregate(stage: .responseDecoding)?.count == 1)
        #expect(diagnostics.aggregate(stage: .bridgeInvocation)?.attempts == 1)
    }

    @Test func neverCompletingInvocationReleasesOnGenerationChange() async {
        let transport = ControllableBridgeTransport()
        let session = SamplyWebSession(diagnostics: SamplyDiagnostics(isEnabled: true),
                                       transport: transport)
        let task: Task<WebSnapshot, Error> = Task { try await session.call("snapshot") }
        await waitForInvocation(transport)

        // The same path used by navigation, sign-out, and web-process termination.
        session.beginNewDocumentGeneration()
        do {
            _ = try await task.value
            Issue.record("a never-completing invocation should be released")
        } catch {
            #expect(error is CancellationError)
        }

        // A late completion from the obsolete document must not resume twice.
        transport.complete(0, with: snapshotJSON)
    }

    @Test func obsoleteCompletionCannotSettleANewerDocumentRequest() async throws {
        let transport = ControllableBridgeTransport()
        let session = SamplyWebSession(diagnostics: SamplyDiagnostics(isEnabled: true),
                                       transport: transport)
        let first: Task<WebSnapshot, Error> = Task { try await session.call("snapshot") }
        await waitForInvocation(transport)

        session.beginNewDocumentGeneration()
        let second: Task<WebSnapshot, Error> = Task { try await session.call("snapshot") }
        await waitForInvocation(transport, count: 2)

        // A -> B -> A style late result from the first document.
        transport.complete(0, with: otherSnapshotJSON)
        transport.complete(1, with: snapshotJSON)

        let snapshot = try await second.value
        #expect(snapshot.account?.uid == "fixture-account")
        do {
            _ = try await first.value
            Issue.record("the obsolete request should not deliver a result")
        } catch {
            #expect(error is CancellationError)
        }
    }

    @Test func cancellingTheWaiterStopsWaitingWithoutAnotherRequest() async {
        let transport = ControllableBridgeTransport()
        let session = SamplyWebSession(diagnostics: SamplyDiagnostics(isEnabled: true),
                                       transport: transport)
        let task: Task<WebSnapshot, Error> = Task { try await session.call("snapshot") }
        await waitForInvocation(transport)
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("cancellation should release the waiter")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(transport.count == 1)
        transport.complete(0, with: snapshotJSON)
    }

    @Test func fixedFailureCodesMapToTypedBridgeErrors() async throws {
        let cases: [(String, SamplyBridgeError)] = [
            ("notReady", .notReady),
            ("contractMismatch", .contractMismatch),
            ("accessDenied", .accessDenied),
            ("superseded", .superseded),
            ("timedOut", .timedOut),
            ("operationFailed", .operationFailed),
            ("somethingElse", .executionFailed)
        ]
        for (code, expected) in cases {
            let transport = ControllableBridgeTransport()
            let session = SamplyWebSession(diagnostics: nil, transport: transport)
            let task: Task<WebSnapshot, Error> = Task { try await session.call("snapshot") }
            await waitForInvocation(transport)
            transport.complete(0, with: #"{"failure":"\#(code)"}"#)
            do {
                _ = try await task.value
                Issue.record("expected \(expected) for \(code)")
            } catch let error as SamplyBridgeError {
                #expect(error == expected)
            }
        }
    }
}

/// Deterministic sleeper: tests decide when a deadline fires. Cancellation
/// resumes the matching waiter so a timed-out task does not leak.
@MainActor
final class ControllableSleeper: Sleeper {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private var waiters: [Waiter] = []
    var pendingCount: Int { waiters.count }

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    func fireAll() {
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.continuation.resume() }
    }
}

@MainActor
struct SamplyBridgeDeadlineTests {
    private let snapshotJSON = """
    {"payload":{"version":1,"account":{"uid":"fixture-account"},"authentication":"signedIn",\
    "libraryReady":true,"library":[],"boxesReady":false,"boxes":[],"capabilities":["library"]}}
    """

    private func waitForInvocation(_ transport: ControllableBridgeTransport,
                                   count: Int = 1) async {
        for _ in 0..<500 {
            if transport.count >= count { return }
            await Task.yield()
        }
        Issue.record("bridge transport was not invoked")
    }

    private func waitUntil(_ condition: () -> Bool, _ message: String) async {
        for _ in 0..<500 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record(Comment(rawValue: message))
    }

    @Test func productDeadlinesMatchTheApprovedCommandClasses() {
        let policy = SamplyBridgeDeadlinePolicy()
        #expect(policy.timeout(for: "snapshot") == .seconds(5))
        #expect(policy.timeout(for: "versions") == .seconds(5))
        #expect(policy.timeout(for: "browse") == .seconds(25))
        #expect(policy.timeout(for: "playBox") == .seconds(25))
        #expect(policy.timeout(for: "refreshPage") == .seconds(25))
        #expect(policy.timeout(for: "projectOwnership") == .seconds(25))
        for command in ["play", "pause", "toggle", "next", "previous", "seek", "volume", "quality"] {
            #expect(policy.timeout(for: command) == .seconds(10))
        }
    }

    @Test func neverCompletingInvocationTimesOutAndDropsLateSuccess() async {
        let transport = ControllableBridgeTransport()
        let sleeper = ControllableSleeper()
        let session = SamplyWebSession(diagnostics: nil, transport: transport, sleeper: sleeper)
        let task: Task<WebSnapshot, Error> = Task { try await session.call("snapshot") }
        await waitForInvocation(transport)
        await waitUntil({ sleeper.pendingCount == 1 }, "the deadline was not scheduled")

        sleeper.fireAll()
        do {
            _ = try await task.value
            Issue.record("a never-completing invocation should time out")
        } catch let error as SamplyBridgeError {
            #expect(error == .timedOut)
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        // The WebKit completion arrives after the native timeout. It must be
        // ignored rather than resuming the continuation a second time.
        transport.complete(0, with: snapshotJSON)
        await Task.yield()
    }

    @Test func successRacingTheDeadlineWinsOnceAndCancelsTheDeadline() async throws {
        let transport = ControllableBridgeTransport()
        let sleeper = ControllableSleeper()
        let session = SamplyWebSession(diagnostics: nil, transport: transport, sleeper: sleeper)
        let task: Task<WebSnapshot, Error> = Task { try await session.call("snapshot") }
        await waitForInvocation(transport)
        await waitUntil({ sleeper.pendingCount == 1 }, "the deadline was not scheduled")

        transport.complete(0, with: snapshotJSON)
        let snapshot = try await task.value
        #expect(snapshot.account?.uid == "fixture-account")
        await waitUntil({ sleeper.pendingCount == 0 }, "the deadline was not cancelled")
        sleeper.fireAll()
    }

    @Test func cancellingTheWaiterAlsoReleasesTheDeadline() async {
        let transport = ControllableBridgeTransport()
        let sleeper = ControllableSleeper()
        let session = SamplyWebSession(diagnostics: nil, transport: transport, sleeper: sleeper)
        let task: Task<WebSnapshot, Error> = Task { try await session.call("snapshot") }
        await waitForInvocation(transport)
        await waitUntil({ sleeper.pendingCount == 1 }, "the deadline was not scheduled")

        task.cancel()
        do {
            _ = try await task.value
            Issue.record("cancellation should release the waiter")
        } catch {
            #expect(error is CancellationError)
        }
        await waitUntil({ sleeper.pendingCount == 0 }, "cancellation did not release the deadline")
    }
}

@MainActor
struct SamplyBridgeProtocolTests {
    private func snapshot(version: Int = 1, capabilities: [String]) -> WebSnapshot {
        WebSnapshot(version: version, account: .init(uid: "fixture-account"),
                    libraryReady: true, library: [], boxesReady: false, boxes: [],
                    capabilities: capabilities)
    }

    @Test func capabilitiesAreAdvertisedAndCheckedPerFeature() {
        let statusOnly = snapshot(capabilities: ["library", "boxes", "playback"])
        #expect(statusOnly.supports(.playback))
        #expect(statusOnly.supports(.library))
        #expect(!statusOnly.supports(.refresh))
        #expect(!statusOnly.supports(.ownership))
        #expect(!statusOnly.supports(.browse))

        let withoutExport = snapshot(capabilities: ["library", "boxes", "playback", "browse"])
        #expect(withoutExport.supports(.playback))
        #expect(withoutExport.supports(.browse))
        #expect(!withoutExport.supports(.refresh))
        #expect(!withoutExport.supports(.ownership))
    }

    @Test func unsupportedSnapshotVersionsAreRejected() {
        #expect(throws: SamplyBridgeError.contractMismatch) {
            try snapshot(version: 2, capabilities: []).validateVersion()
        }
        #expect(throws: Never.self) {
            try snapshot(version: 1, capabilities: []).validateVersion()
        }
    }
}

@MainActor
struct SamplyRuntimeSessionTests {
    private let fullJSON = """
    {"payload":{"version":1,"account":{"uid":"fixture-account"},"authentication":"signedIn",\
    "libraryReady":true,"library":[],"routeID":"share-1","projectID":"project-1",\
    "boxesReady":false,"boxes":[],"capabilities":["library","boxes","playback","browse"]}}
    """

    private let runtimeJSON = """
    {"payload":{"version":1,"account":{"uid":"fixture-account"},"authentication":"signedIn",\
    "routeID":"share-1","projectID":"project-1","boxesReady":true,\
    "playback":{"fileID":"track-a","title":"Track","playing":true,"loading":false,\
    "buffering":false,"position":12,"duration":120,"volume":1,\
    "canGoNext":false,"canGoPrevious":false},\
    "capabilities":["library","boxes","playback","browse"]}}
    """

    private let otherAccountRuntimeJSON = """
    {"payload":{"version":1,"account":{"uid":"other-account"},"authentication":"signedIn",\
    "routeID":"share-2","projectID":"project-2","boxesReady":false,\
    "playback":{"fileID":"track-b","title":"Other","playing":false,"loading":false,\
    "buffering":false,"position":0,"duration":60,"volume":1,\
    "canGoNext":false,"canGoPrevious":false},\
    "capabilities":["library","boxes","playback"]}}
    """

    private func waitForInvocation(_ transport: ControllableBridgeTransport,
                                   count: Int = 1) async {
        for _ in 0..<500 {
            if transport.count >= count { return }
            await Task.yield()
        }
        Issue.record("bridge transport was not invoked")
    }

    @Test func runtimeReadSamplesIdentityAndPlaybackWithoutAFullSnapshot() async {
        let transport = ControllableBridgeTransport()
        let session = SamplyWebSession(diagnostics: nil, transport: transport)
        let task = Task { await session.refreshRuntime() }
        await waitForInvocation(transport)
        transport.complete(0, with: runtimeJSON)
        let succeeded = await task.value
        #expect(succeeded)
        #expect(session.runtimeSnapshot?.playback?.fileID == "track-a")
        #expect(session.account?.uid == "fixture-account")
        #expect(session.snapshot == nil)
        #expect(session.authenticationState == .signedIn)
    }

    @Test func aChangedRuntimeIdentityDropsFullContentFromTheOldAccount() async {
        let transport = ControllableBridgeTransport()
        let session = SamplyWebSession(diagnostics: nil, transport: transport)
        let fullTask = Task { await session.refresh() }
        await waitForInvocation(transport)
        transport.complete(0, with: fullJSON)
        #expect(await fullTask.value)
        #expect(session.snapshot != nil)
        #expect(session.account?.uid == "fixture-account")

        let runtimeTask = Task { await session.refreshRuntime() }
        await waitForInvocation(transport, count: 2)
        transport.complete(1, with: otherAccountRuntimeJSON)
        #expect(await runtimeTask.value)
        #expect(session.snapshot == nil)
        #expect(session.runtimeSnapshot?.account?.uid == "other-account")
        #expect(session.account?.uid == "other-account")
    }
}
