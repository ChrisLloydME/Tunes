import Foundation
import Testing
@testable import Tunes

@MainActor
struct PlaybackRuntimeTests {
    private func item(_ id: String, artwork: String? = nil) -> LibraryItem {
        LibraryItem(id: id, name: "Album \(id)", projectID: "project-\(id)",
                    playerID: "player-\(id)", shareID: "share-\(id)",
                    artist: "Artist", artwork: artwork)
    }

    private func box(_ id: String) -> WebBox {
        WebBox(id: id, name: "Track", kind: "file", duration: 120,
               isAudio: true, isProcessing: false, childIDs: [])
    }

    private func playback(_ fileID: String, position: Double = 1) -> WebPlayback {
        var state = WebPlayback.empty
        state.fileID = fileID
        state.playing = true
        state.position = position
        return state
    }

    @Test func runtimeSampleUpdatesClockWithoutReplacingThePlayingAlbum() {
        let controller = PlaybackController(web: SamplyWebSession())
        let album = item("a", artwork: "https://x/a.png")
        controller.apply(playback("track-a"), libraryItem: album)
        let assignments = controller.stateAssignmentCount

        controller.applyRuntime(playback("track-a", position: 42),
                                routeID: album.routeID,
                                trustedLibrary: [album], trustedBoxes: [box("track-a")])
        #expect(controller.state.position == 42)
        #expect(controller.artwork == album.artwork)
        #expect(controller.stateAssignmentCount == assignments + 1)
    }

    @Test func unboundTrackResolvesFromTrustedBoxesForItsRoute() {
        let controller = PlaybackController(web: SamplyWebSession())
        let album = item("a", artwork: "https://x/a.png")
        controller.applyRuntime(playback("track-b"), routeID: album.routeID,
                                trustedLibrary: [album], trustedBoxes: [box("track-b")])
        #expect(controller.artwork == album.artwork)
        #expect(controller.libraryItem?.id == album.id)
    }

    @Test func unboundTrackStaysUnresolvedUntilAFullSnapshotProvidesEvidence() {
        let controller = PlaybackController(web: SamplyWebSession())
        let album = item("a", artwork: "https://x/a.png")
        controller.applyRuntime(playback("track-b"), routeID: album.routeID,
                                trustedLibrary: [album], trustedBoxes: [])
        #expect(controller.libraryItem == nil)
        #expect(controller.artwork == nil)
        #expect(controller.state.fileID == "track-b")

        let snapshot = WebSnapshot(
            version: 1, account: .init(uid: "fixture-account"), libraryReady: true,
            library: [album], routeID: album.routeID, projectID: album.projectID,
            boxesReady: true, boxes: [box("track-b")], playback: playback("track-b"),
            capabilities: ["library", "boxes", "playback"])
        controller.applySnapshot(snapshot)
        #expect(controller.artwork == album.artwork)
    }

    @Test func browsingAnotherAlbumDoesNotBorrowTheDisplayedAlbumCover() {
        let albumA = item("a", artwork: "https://x/a.png")
        let albumB = item("b", artwork: "https://x/b.png")

        let bound = PlaybackController(web: SamplyWebSession())
        bound.apply(playback("track-a"), libraryItem: albumA)
        bound.applyRuntime(playback("track-b"), routeID: albumB.routeID,
                           trustedLibrary: [albumA, albumB], trustedBoxes: [])
        #expect(bound.artwork == albumA.artwork)

        let unbound = PlaybackController(web: SamplyWebSession())
        unbound.applyRuntime(playback("track-b"), routeID: albumB.routeID,
                             trustedLibrary: [albumA, albumB], trustedBoxes: [])
        #expect(unbound.artwork == nil)
    }
}
