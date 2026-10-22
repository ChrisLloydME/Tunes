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
