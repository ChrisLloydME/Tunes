import Foundation
import Testing
@testable import Tunes

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

    @Test func repeatedIdenticalLibraryAndBoxArraysCauseOneAssignment() {
        var acceptance = SamplyContentAcceptance()
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
        var acceptance = SamplyContentAcceptance()
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
        var acceptance = SamplyContentAcceptance()
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
        var acceptance = SamplyContentAcceptance()
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
