import Foundation
import Testing
@testable import Tunes

@MainActor
struct SamplyBackendReadCoordinatorTests {
    private let seedJSON = """
    {"payload":{"version":1,"account":{"uid":"fixture-account"},"authentication":"signedIn",\
    "libraryReady":true,"library":[{"id":"album-a","name":"Seed","projectID":"project-a",\
    "playerID":"player-a","shareID":"share-a","artist":"Artist","canUpload":false,"isOwned":true}],\
    "routeID":"share-1","projectID":"project-1","boxesReady":false,"boxes":[],\
    "capabilities":["library","boxes","playback","browse","refresh","ownership"]}}
    """

    private let refreshedJSON = """
    {"payload":{"version":1,"account":{"uid":"fixture-account"},"authentication":"signedIn",\
    "libraryReady":true,"library":[{"id":"album-a","name":"Refreshed","projectID":"project-a",\
    "playerID":"player-a","shareID":"share-a","artist":"Artist","canUpload":false,"isOwned":true}],\
    "routeID":"share-1","projectID":"project-1","boxesReady":false,"boxes":[],\
    "capabilities":["library","boxes","playback","browse","refresh","ownership"]}}
    """

    private let failureJSON = #"{"failure":"timedOut"}"#

    private func waitUntil(_ condition: () -> Bool, _ message: String) async {
        for _ in 0..<1_000 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record(Comment(rawValue: message))
    }

    private func makeBackend(sleeper: (any Sleeper)? = nil)
        -> (SamplyBackend, SamplyWebSession, ControllableBridgeTransport) {
        let transport = ControllableBridgeTransport()
        let session = SamplyWebSession(diagnostics: nil, transport: transport)
        let backend = SamplyBackend(tokens: MemoryTokenStore(), diagnostics: nil,
                                    web: session, sleeper: sleeper,
                                    randomUnit: { 0.5 })
        return (backend, session, transport)
    }

    private func seed(_ backend: SamplyBackend, _ transport: ControllableBridgeTransport) async {
        let task = Task { await backend.recover(.library) }
        await waitUntil({ transport.count == 1 }, "the seed snapshot was not requested")
        transport.complete(0, with: seedJSON)
        await task.value
        #expect(backend.isConnected)
    }

    @Test func identicalLibraryReadsShareOneServerRead() async {
        let (backend, session, transport) = makeBackend()
        await seed(backend, transport)

        let first = Task { await backend.refresh(.library) }
        await waitUntil({ transport.count == 2 }, "the first read did not start")
        let second = Task { await backend.refresh(.library) }
        await Task.yield()
        #expect(transport.count == 2)

        transport.complete(1, with: refreshedJSON)
        await first.value
        await second.value
        #expect(backend.library.first?.name == "Refreshed")
    }

    @Test func cancellingOneWaiterKeepsTheSharedReadForTheOther() async {
        let (backend, session, transport) = makeBackend()
        await seed(backend, transport)

        let first = Task { await backend.refresh(.library) }
        await waitUntil({ transport.count == 2 }, "the first read did not start")
        let second = Task { await backend.refresh(.library) }
        await Task.yield()
        #expect(transport.count == 2)

        second.cancel()
        await Task.yield()
        transport.complete(1, with: refreshedJSON)
        await first.value
        await second.value
        #expect(backend.library.first?.name == "Refreshed")
    }

    @Test func cancellingTheFinalWaiterInvalidatesTheSharedRead() async {
        let (backend, session, transport) = makeBackend()
        await seed(backend, transport)

        let first = Task { await backend.refresh(.library) }
        await waitUntil({ transport.count == 2 }, "the first read did not start")
        first.cancel()
        await first.value
        await waitUntil({ !backend.isRefreshing }, "the shared read stayed busy")

        // A late result for the cancelled read must not be committed.
        transport.complete(1, with: refreshedJSON)
        await Task.yield()
        #expect(backend.library.first?.name == "Seed")

        let second = Task { await backend.refresh(.library) }
        await waitUntil({ transport.count == 3 }, "a fresh read did not start")
        transport.complete(2, with: refreshedJSON)
        await second.value
        #expect(backend.library.first?.name == "Refreshed")
    }

    @Test func automaticRecoveryStopsAfterThreeAttemptsAndDoesNotRestart() async {
        let sleeper = ControllableSleeper()
        let (backend, session, transport) = makeBackend(sleeper: sleeper)
        await seed(backend, transport)

        let failing = Task { await backend.refresh(.library) }
        await waitUntil({ transport.count == 2 }, "the failing read did not start")
        transport.complete(1, with: failureJSON)
        await failing.value
        #expect(backend.hasTransientError)
        #expect(backend.error != nil)

        for attempt in 0..<3 {
            await waitUntil({ sleeper.pendingCount == 1 }, "recovery attempt \(attempt) was not scheduled")
            sleeper.fireAll()
            let expectedIndex = 2 + attempt
            await waitUntil({ transport.count == expectedIndex + 1 },
                            "recovery attempt \(attempt) did not issue a read")
            transport.complete(expectedIndex, with: failureJSON)
            await waitUntil({ !backend.isRefreshing }, "recovery read \(attempt) stayed busy")
        }

        await waitUntil({ backend.recoveryExhausted }, "the recovery budget did not exhaust")
        #expect(backend.library.first?.name == "Seed")
        #expect(backend.hasTransientError)
        #expect(sleeper.pendingCount == 0)

        backend.reconcileRecovery()
        await Task.yield()
        #expect(transport.count == 5)
        #expect(sleeper.pendingCount == 0)
    }

    @Test func explicitUserRetryStartsANewEpisodeAndClearsTheFailure() async {
        let sleeper = ControllableSleeper()
        let (backend, session, transport) = makeBackend(sleeper: sleeper)
        await seed(backend, transport)

        let failing = Task { await backend.refresh(.library) }
        await waitUntil({ transport.count == 2 }, "the failing read did not start")
        transport.complete(1, with: failureJSON)
        await failing.value
        for attempt in 0..<3 {
            await waitUntil({ sleeper.pendingCount == 1 }, "recovery attempt \(attempt) was not scheduled")
            sleeper.fireAll()
            await waitUntil({ transport.count == 3 + attempt },
                            "recovery attempt \(attempt) did not issue a read")
            transport.complete(2 + attempt, with: failureJSON)
            await waitUntil({ !backend.isRefreshing }, "recovery read \(attempt) stayed busy")
        }
        await waitUntil({ backend.recoveryExhausted }, "the recovery budget did not exhaust")

        let retry = Task { await backend.recover(.library, forcePageRefresh: true) }
        await waitUntil({ transport.count == 6 }, "the retry store snapshot did not start")
        transport.complete(5, with: seedJSON)
        await waitUntil({ transport.count == 7 }, "the retry page refresh did not start")
        transport.complete(6, with: refreshedJSON)
        await retry.value

        #expect(!backend.hasTransientError)
        #expect(backend.error == nil)
        #expect(!backend.recoveryExhausted)
        #expect(backend.library.first?.name == "Refreshed")
    }
}
