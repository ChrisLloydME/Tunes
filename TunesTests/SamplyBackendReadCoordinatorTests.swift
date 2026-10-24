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

    private let staleJSON = """
    {"payload":{"version":1,"account":{"uid":"fixture-account"},"authentication":"signedIn",\
    "libraryReady":true,"library":[{"id":"album-a","name":"Stale","projectID":"project-a",\
    "playerID":"player-a","shareID":"share-a","artist":"Artist","canUpload":false,"isOwned":true}],\
    "routeID":"share-1","projectID":"project-1","boxesReady":false,"boxes":[],\
    "capabilities":["library","boxes","playback","browse","refresh","ownership"]}}
    """

    private let againJSON = """
    {"payload":{"version":1,"account":{"uid":"fixture-account"},"authentication":"signedIn",\
    "libraryReady":true,"library":[{"id":"album-a","name":"Again","projectID":"project-a",\
    "playerID":"player-a","shareID":"share-a","artist":"Artist","canUpload":false,"isOwned":true}],\
    "routeID":"share-1","projectID":"project-1","boxesReady":false,"boxes":[],\
    "capabilities":["library","boxes","playback","browse","refresh","ownership"]}}
    """

    private let failureJSON = #"{"failure":"timedOut"}"#

    private let browseTimedJSON = """
    {"payload":{"version":1,"account":{"uid":"fixture-account"},"authentication":"signedIn",\
    "libraryReady":true,"library":[{"id":"album-a","name":"Seed","projectID":"project-a",\
    "playerID":"player-a","shareID":"share-a","artist":"Artist","canUpload":false,"isOwned":true}],\
    "routeID":"share-a","projectID":"project-a","boxesReady":true,\
    "boxes":[{"id":"track-a","name":"Track","kind":"file","isAudio":true,\
    "isProcessing":false,"childIDs":[]}],\
    "capabilities":["library","boxes","playback","browse"]},\
    "timing":{"routerMilliseconds":30,"boxesMilliseconds":70,\
    "responseMilliseconds":4,"totalMilliseconds":104}}
    """

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

    @Test func creationRecoverySharesTheToolbarLibraryRead() async throws {
        let (backend, _, transport) = makeBackend()
        await seed(backend, transport)

        let toolbar = Task { await backend.refresh(.library) }
        await waitUntil({ transport.count == 2 }, "the toolbar read did not start")
        let creation = Task {
            try await backend.refreshLibrarySnapshot(accountID: "fixture-account")
        }
        await Task.yield()
        #expect(transport.count == 2)

        transport.complete(1, with: refreshedJSON)
        await toolbar.value
        let snapshot = try await creation.value
        #expect(snapshot.library.first?.name == "Refreshed")
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
        // Releasing one waiter must not notify the page or start another read.
        #expect(transport.count == 2)
        transport.complete(1, with: refreshedJSON)
        await first.value
        await second.value
        #expect(transport.invocations.map(\.command) == ["snapshot", "refreshPage"])
        #expect(transport.count == 2)
        #expect(backend.library.first?.name == "Refreshed")
    }

    @Test func cancellingTheFinalWaiterInvalidatesTheSharedRead() async {
        let (backend, session, transport) = makeBackend()
        await seed(backend, transport)

        let first = Task { await backend.refresh(.library) }
        await waitUntil({ transport.count == 2 }, "the first read did not start")
        let requestID = transport.invocations[1].arguments["requestID"] as? Int
        first.cancel()
        await first.value
        await waitUntil({ transport.count == 3 }, "the final waiter did not expire its request")
        #expect(transport.invocations.map(\.command) == ["snapshot", "refreshPage", "cancel"])
        #expect(transport.invocations[2].arguments["requestID"] as? Int == requestID)
        await waitUntil({ !backend.isRefreshing }, "the shared read stayed busy")
        await Task.yield()
        #expect(transport.count == 3, "the cancelled read was automatically replayed")

        // A late result for the cancelled read must not be committed.
        transport.complete(1, with: refreshedJSON)
        await Task.yield()
        #expect(backend.library.first?.name == "Seed")

        let second = Task { await backend.refresh(.library) }
        await waitUntil({ transport.count == 4 }, "a fresh read did not start")
        transport.complete(3, with: refreshedJSON)
        await second.value
        #expect(backend.library.first?.name == "Refreshed")
    }

    @Test func cancelledReadCannotOverwriteANewerRead() async {
        let (backend, _, transport) = makeBackend()
        await seed(backend, transport)

        let first = Task { await backend.refresh(.library) }
        await waitUntil({ transport.count == 2 }, "read A did not start")
        first.cancel()
        await first.value
        await waitUntil({ transport.count == 3 }, "read A did not expire its request")

        let second = Task { await backend.refresh(.library) }
        await waitUntil({ transport.count == 4 }, "read B did not start")
        transport.complete(3, with: refreshedJSON)
        await second.value
        #expect(backend.library.first?.name == "Refreshed")

        // A finishes after B. The late result must not replace B.
        transport.complete(1, with: staleJSON)
        await Task.yield()
        #expect(backend.library.first?.name == "Refreshed")
        #expect(transport.count == 4)
    }

    @Test func cancelledReadCannotOverwriteARepeatedRead() async {
        let (backend, _, transport) = makeBackend()
        await seed(backend, transport)

        // A starts and is cancelled before the newer B read.
        let first = Task { await backend.refresh(.library) }
        await waitUntil({ transport.count == 2 }, "read A did not start")
        first.cancel()
        await first.value
        await waitUntil({ transport.count == 3 }, "read A did not expire its request")

        // B finishes first and is accepted.
        let second = Task { await backend.refresh(.library) }
        await waitUntil({ transport.count == 4 }, "read B did not start")
        transport.complete(3, with: refreshedJSON)
        await second.value
        #expect(backend.library.first?.name == "Refreshed")

        // A is requested again and accepted before the first A result arrives.
        let third = Task { await backend.refresh(.library) }
        await waitUntil({ transport.count == 5 }, "the repeated read did not start")
        transport.complete(4, with: againJSON)
        await third.value
        #expect(backend.library.first?.name == "Again")

        // The original A finishes last. Both its web result and native content
        // must continue to show the newest accepted read.
        transport.complete(1, with: staleJSON)
        await Task.yield()
        #expect(backend.library.first?.name == "Again")
        #expect(transport.count == 5)
        #expect(transport.invocations.map(\.command) ==
                ["snapshot", "refreshPage", "cancel", "refreshPage", "refreshPage"])
        #expect(!backend.hasTransientError)
    }

    @Test func cancelledSharedWaiterCannotReturnSuccessAfterSiblingFinishes() async {
        let (backend, _, transport) = makeBackend()
        await seed(backend, transport)

        let toolbar = Task { await backend.refresh(.library) }
        await waitUntil({ transport.count == 2 }, "the toolbar read did not start")
        let creation = Task {
            try await backend.refreshLibrarySnapshot(accountID: "fixture-account")
        }
        // Let the creation caller join the already-active shared read.
        for _ in 0..<100 { await Task.yield() }
        creation.cancel()
        await Task.yield()
        #expect(transport.count == 2)

        // The toolbar waiter keeps the shared task alive; the cancelled caller
        // must still fail instead of returning that success.
        transport.complete(1, with: refreshedJSON)
        await toolbar.value
        do {
            _ = try await creation.value
            Issue.record("a cancelled shared waiter returned success")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(backend.library.first?.name == "Refreshed")
    }

    @Test func navigationTraceCorrelatesBridgePhasesAndPublication() async throws {
        let transport = ControllableBridgeTransport()
        let diagnostics = SamplyDiagnostics(isEnabled: true)
        let session = SamplyWebSession(diagnostics: diagnostics, transport: transport)
        let backend = SamplyBackend(tokens: MemoryTokenStore(), diagnostics: diagnostics,
                                    web: session)
        let seedTask = Task { await backend.recover(.library) }
        await waitUntil({ transport.count == 1 }, "the seed read did not start")
        transport.complete(0, with: seedJSON)
        await seedTask.value
        let item = try #require(backend.library.first)

        backend.select(item)
        await waitUntil({ transport.count == 2 }, "the browse did not start")
        let rawID = try #require(transport.invocations[1].arguments["requestID"] as? Int)
        transport.complete(1, with: browseTimedJSON)
        await waitUntil({
            if case .loaded = backend.albumLoadState { return true }
            return false
        }, "the browse did not publish")

        let operation = diagnostics.loadingTrace.operation(id: UInt64(rawID))
        #expect(operation?.stages.contains(where: { $0.stage == .bridgeStarted }) == true)
        #expect(operation?.stages.contains(where: { $0.stage == .payloadDecoded }) == true)
        #expect(operation?.stages.contains(where: { $0.stage == .selection }) == true)
        #expect(operation?.stages.contains(where: { $0.stage == .contentPublished }) == true)
        let router = operation?.stages.first { $0.stage == .routerSettled }
        let boxes = operation?.stages.first { $0.stage == .boxesReady }
        let response = operation?.stages.first { $0.stage == .responseBuilt }
        #expect(abs((router?.duration ?? 0) - 0.03) < 0.0001)
        #expect(abs((boxes?.duration ?? 0) - 0.07) < 0.0001)
        #expect(abs((response?.duration ?? 0) - 0.004) < 0.0001)
        #expect(backend.boxes.map(\.id) == ["track-a"])
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
