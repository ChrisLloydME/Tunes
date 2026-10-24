import Foundation
import Testing
@testable import Tunes

private final class AcceptanceNotificationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

@MainActor
private final class AcceptanceObservationProbe {
    enum Field { case library, boxes }

    private let backend: SamplyBackend
    private let field: Field
    private let counter: AcceptanceNotificationCounter

    init(backend: SamplyBackend, field: Field, counter: AcceptanceNotificationCounter) {
        self.backend = backend
        self.field = field
        self.counter = counter
    }

    func observe() {
        let counter = self.counter
        withObservationTracking {
            switch field {
            case .library: _ = backend.library
            case .boxes: _ = backend.boxes
            }
        } onChange: { [weak self] in
            counter.increment()
            Task { @MainActor [weak self] in self?.observe() }
        }
    }
}

@MainActor
struct StateAcceptanceTests {
    private func item(_ id: String, name: String = "Album", artwork: String? = nil,
                      canUpload: Bool = false, isOwned: Bool = true) -> LibraryItem {
        LibraryItem(id: id, name: name, projectID: "project-\(id)", playerID: "player-\(id)",
                    shareID: "share-\(id)", artist: "Artist", artwork: artwork,
                    canUpload: canUpload, isOwned: isOwned)
    }

    private func box(_ id: String, kind: String = "file", processing: Bool = false,
                     version: String? = nil) -> WebBox {
        WebBox(id: id, name: "Box \(id)", kind: kind, activeID: id, duration: 60,
               isAudio: kind == "file", isProcessing: processing,
               versionName: version, childIDs: [])
    }

    private func makeBackend() -> SamplyBackend {
        SamplyBackend(tokens: MemoryTokenStore(), diagnostics: nil,
                      web: SamplyWebSession(diagnostics: nil,
                                            transport: ControllableBridgeTransport()))
    }

    private func waitUntil(_ condition: @escaping () -> Bool, _ message: String) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record(Comment(rawValue: message))
    }

    @Test func equalContentDoesNotNotifyBackendObservers() async {
        let backend = makeBackend()
        let libraryCounter = AcceptanceNotificationCounter()
        let boxCounter = AcceptanceNotificationCounter()
        let libraryProbe = AcceptanceObservationProbe(backend: backend, field: .library,
                                                      counter: libraryCounter)
        let boxProbe = AcceptanceObservationProbe(backend: backend, field: .boxes,
                                                  counter: boxCounter)
        libraryProbe.observe()
        boxProbe.observe()

        let library = [item("a"), item("b")]
        backend.content.acceptLibrary(library)
        await waitUntil({ libraryCounter.count == 1 }, "the Library change did not notify")
        #expect(boxCounter.count == 0)
        backend.content.acceptLibrary(library)
        await Task.yield()
        #expect(libraryCounter.count == 1)

        let boxes = [box("one"), box("two")]
        backend.content.acceptBoxes(boxes)
        await waitUntil({ boxCounter.count == 1 }, "the box change did not notify")
        #expect(libraryCounter.count == 1)
        backend.content.acceptBoxes(boxes)
        await Task.yield()
        #expect(boxCounter.count == 1)

        backend.content.acceptLibrary([item("a", name: "Renamed"), item("b")])
        await waitUntil({ libraryCounter.count == 2 }, "the rename did not notify")
        backend.content.acceptBoxes([box("one", processing: true), box("two")])
        await waitUntil({ boxCounter.count == 2 }, "the processing change did not notify")
        #expect(libraryCounter.count == 2)

        #expect(!backend.content.replaceLibraryItem(item("a", name: "Renamed")))
        await Task.yield()
        #expect(libraryCounter.count == 2)
        #expect(backend.content.replaceLibraryItem(
            item("a", name: "Renamed", artwork: "https://x/new.png")))
        await waitUntil({ libraryCounter.count == 3 }, "the in-place update did not notify")
    }

    @Test func clearingLoadedContentNotifiesBothObserversOnce() async {
        let backend = makeBackend()
        backend.content.acceptLibrary([item("a")])
        backend.content.acceptBoxes([box("one")])
        let libraryCounter = AcceptanceNotificationCounter()
        let boxCounter = AcceptanceNotificationCounter()
        let libraryProbe = AcceptanceObservationProbe(backend: backend, field: .library,
                                                      counter: libraryCounter)
        let boxProbe = AcceptanceObservationProbe(backend: backend, field: .boxes,
                                                  counter: boxCounter)
        libraryProbe.observe()
        boxProbe.observe()

        backend.content.clear()
        await waitUntil({ libraryCounter.count == 1 }, "clear did not notify the Library")
        #expect(boxCounter.count == 1)
        backend.content.clear()
        await Task.yield()
        #expect(libraryCounter.count == 1)
        #expect(boxCounter.count == 1)
    }

    @Test func repeatedIdenticalLibraryAndBoxArraysCauseOneAssignment() {
        let acceptance = SamplyContentAcceptance()
        let library = [item("a"), item("b")]
        let boxes = [box("one"), box("two")]
        let firstLibrary = acceptance.acceptLibrary(library)
        let duplicateLibrary = acceptance.acceptLibrary(library)
        #expect(firstLibrary)
        #expect(!duplicateLibrary)
        #expect(acceptance.libraryAssignmentCount == 1)
        let firstBoxes = acceptance.acceptBoxes(boxes)
        let duplicateBoxes = acceptance.acceptBoxes(boxes)
        #expect(firstBoxes)
        #expect(!duplicateBoxes)
        #expect(acceptance.boxAssignmentCount == 1)
    }

    @Test func fieldAndOrderChangesAreStillAccepted() {
        let acceptance = SamplyContentAcceptance()
        _ = acceptance.acceptLibrary([item("a"), item("b")])

        let renamed = acceptance.acceptLibrary([item("a", name: "Renamed"), item("b")])
        #expect(renamed)
        let artwork = acceptance.acceptLibrary([item("a", name: "Renamed",
                                                     artwork: "https://x/a.png"), item("b")])
        #expect(artwork)
        let permission = acceptance.acceptLibrary([
            item("a", name: "Renamed", artwork: "https://x/a.png", canUpload: true), item("b")
        ])
        #expect(permission)
        let ownership = acceptance.acceptLibrary([
            item("a", name: "Renamed", artwork: "https://x/a.png", canUpload: true,
                 isOwned: false), item("b")
        ])
        #expect(ownership)
        // Same identities in a different order are different content.
        let reorderedItems = [item("b"), item("a", name: "Renamed", artwork: "https://x/a.png",
                                             canUpload: true, isOwned: false)]
        let reordered = acceptance.acceptLibrary(reorderedItems)
        #expect(reordered)
        #expect(acceptance.library.map(\.id) == ["b", "a"])

        _ = acceptance.acceptBoxes([box("one", kind: "file", processing: false)])
        let processing = acceptance.acceptBoxes([box("one", kind: "file", processing: true)])
        #expect(processing)
        let version = acceptance.acceptBoxes([box("one", kind: "stack", processing: true, version: "V2")])
        #expect(version)
        let duplicate = acceptance.acceptBoxes([box("one", kind: "stack", processing: true, version: "V2")])
        #expect(!duplicate)
    }

    @Test func confirmedEmptyBoxReadIsAnExplicitAssignment() {
        let acceptance = SamplyContentAcceptance()
        _ = acceptance.acceptBoxes([box("one")])
        let cleared = acceptance.acceptBoxes([])
        #expect(cleared)
        #expect(acceptance.boxes.isEmpty)
        #expect(acceptance.boxAssignmentCount == 2)
        // A second confirmed empty read performs no additional assignment.
        let duplicate = acceptance.acceptBoxes([])
        #expect(!duplicate)
        #expect(acceptance.boxAssignmentCount == 2)
    }

    @Test func createdProjectReplacementRequiresIdentityAndChange() {
        let original = item("a")
        let acceptance = SamplyContentAcceptance()
        _ = acceptance.acceptLibrary([original, item("b")])
        let unchanged = acceptance.replaceLibraryItem(original)
        let missing = acceptance.replaceLibraryItem(item("missing"))
        #expect(!unchanged)
        #expect(!missing)
        #expect(acceptance.libraryAssignmentCount == 1)

        let updated = item("a", name: "Updated", canUpload: true)
        let replaced = acceptance.replaceLibraryItem(updated)
        #expect(replaced)
        #expect(acceptance.library.count == 2)
        #expect(acceptance.library.first?.name == "Updated")
        #expect(acceptance.library.last?.id == "b")
    }

    @Test func identicalPlaybackStateAndBindingCauseNoAssignments() {
        let controller = PlaybackController(web: SamplyWebSession())
        var playback = WebPlayback.empty
        playback.fileID = "track-a"
        playback.playing = true
        playback.position = 10
        let album = item("album", artwork: "https://x/art.png")

        controller.apply(playback, libraryItem: album)
        #expect(controller.stateAssignmentCount == 1)
        #expect(controller.libraryItemAssignmentCount == 1)
        controller.apply(playback, libraryItem: album)
        #expect(controller.stateAssignmentCount == 1)
        #expect(controller.libraryItemAssignmentCount == 1)
    }

    @Test func clockAndSeekUpdatesStillReachPlaybackState() {
        let controller = PlaybackController(web: SamplyWebSession())
        var playback = WebPlayback.empty
        playback.fileID = "track-a"
        playback.playing = true
        controller.apply(playback, libraryItem: item("album"))
        playback.position = 12.5
        controller.apply(playback)
        #expect(controller.state.position == 12.5)
        #expect(controller.stateAssignmentCount == 2)
        #expect(controller.state.playing)
    }

    @Test func identicalSnapshotDoesNotReacceptContentOrPlayback() {
        let controller = PlaybackController(web: SamplyWebSession())
        var playback = WebPlayback.empty
        playback.fileID = "track-a"
        playback.position = 5
        let album = item("album")
        let snapshot = WebSnapshot(
            version: 1, account: .init(uid: "fixture-account"), libraryReady: true,
            library: [album], routeID: album.routeID, projectID: album.projectID,
            boxesReady: true, boxes: [box("track-a")], playback: playback,
            capabilities: ["library", "boxes", "playback"])

        controller.applySnapshot(snapshot)
        let stateAssignments = controller.stateAssignmentCount
        let itemAssignments = controller.libraryItemAssignmentCount
        controller.applySnapshot(snapshot)
        #expect(controller.stateAssignmentCount == stateAssignments)
        #expect(controller.libraryItemAssignmentCount == itemAssignments)
    }

    @Test func libraryArtworkUpdateRefreshesBindingWithoutReplacingPlayback() {
        let controller = PlaybackController(web: SamplyWebSession())
        var playback = WebPlayback.empty
        playback.fileID = "track-a"
        let album = item("album", artwork: "https://x/old.png")
        func snapshot(_ library: [LibraryItem]) -> WebSnapshot {
            WebSnapshot(version: 1, account: .init(uid: "fixture-account"), libraryReady: true,
                        library: library, routeID: album.routeID, projectID: album.projectID,
                        boxesReady: true, boxes: [box("track-a")], playback: playback,
                        capabilities: ["library", "boxes"])
        }
        controller.applySnapshot(snapshot([album]))
        let stateAssignments = controller.stateAssignmentCount
        let itemAssignments = controller.libraryItemAssignmentCount

        controller.applySnapshot(snapshot([item("album", artwork: "https://x/new.png")]))
        #expect(controller.artwork == "https://x/new.png")
        #expect(controller.stateAssignmentCount == stateAssignments)
        #expect(controller.libraryItemAssignmentCount == itemAssignments + 1)
    }

    @Test func repeatedIdenticalProfileAcceptanceDoesNotReassignAccount() throws {
        let storage = try #require(UserDefaults(suiteName: "TunesProfileAcceptance." + UUID().uuidString))
        let cache = SamplyProfileCache(defaults: storage)
        let account = WebSnapshot.Account(uid: "fixture-user", name: "Fixture")
        cache.accept(account, authentication: .signedIn)
        #expect(cache.accountAssignmentCount == 1)
        cache.accept(account, authentication: .signedIn)
        #expect(cache.accountAssignmentCount == 1)
        cache.accept(WebSnapshot.Account(uid: "fixture-user", name: "Renamed"),
                     authentication: .signedIn)
        #expect(cache.accountAssignmentCount == 2)
        #expect(cache.account?.name == "Renamed")
        cache.clear()
    }
}
