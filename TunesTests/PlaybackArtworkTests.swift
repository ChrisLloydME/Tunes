import Testing
@testable import Tunes

@MainActor
struct PlaybackArtworkTests {
    private let albumA = LibraryItem(id: "album-a", name: "Album A", shareID: "route-a",
                                     artwork: "https://example.test/library-a.png")
    private let albumB = LibraryItem(id: "album-b", name: "Album B", shareID: "route-b",
                                     artwork: "https://example.test/library-b.png")

    private func playback(_ fileID: String) -> WebPlayback {
        var state = WebPlayback.empty
        state.fileID = fileID
        state.artwork = "https://example.test/embedded-track-art.png"
        return state
    }

    private func snapshot(fileID: String, route: LibraryItem, visibleFileID: String,
                          library: [LibraryItem]? = nil) -> WebSnapshot {
        WebSnapshot(
            version: 1, account: .init(uid: "fixture-account"), libraryReady: true,
            library: library ?? [albumA, albumB], routeID: route.routeID, boxesReady: true,
            boxes: [WebBox(id: visibleFileID, name: "Track", kind: "file",
                           isAudio: true, isProcessing: false, childIDs: [])],
            playback: playback(fileID), capabilities: ["library", "boxes", "playback"]
        )
    }

    @Test func playerUsesThePlayingLibraryArtworkInsteadOfEmbeddedTrackArtwork() {
        let controller = PlaybackController(web: SamplyWebSession())
        controller.apply(playback("track-a"), libraryItem: albumA)
        #expect(controller.artwork == albumA.artwork)
        #expect(controller.artwork != controller.state.artwork)
    }

    @Test func browsingAnotherAlbumAndAdvancingTheQueuePreservesThePlayingCover() {
        let controller = PlaybackController(web: SamplyWebSession())
        controller.apply(playback("track-a"), libraryItem: albumA)
        controller.applySnapshot(snapshot(fileID: "track-a", route: albumB, visibleFileID: "track-b"))
        #expect(controller.artwork == albumA.artwork)
        controller.applySnapshot(snapshot(fileID: "track-a-next", route: albumB, visibleFileID: "track-b"))
        #expect(controller.artwork == albumA.artwork)

        controller.applySnapshot(snapshot(fileID: "track-b", route: albumB, visibleFileID: "track-b"))
        #expect(controller.artwork == albumB.artwork)
    }

    @Test func restoredPlaybackResolvesItsLibraryEntryAndTracksArtworkUpdates() {
        let controller = PlaybackController(web: SamplyWebSession())
        controller.applySnapshot(snapshot(fileID: "track-a", route: albumA, visibleFileID: "track-a"))
        #expect(controller.artwork == albumA.artwork)

        var updated = albumA
        updated.artwork = "https://example.test/updated-library-a.png"
        controller.applySnapshot(snapshot(fileID: "track-a", route: albumB, visibleFileID: "track-b",
                                          library: [updated, albumB]))
        #expect(controller.artwork == updated.artwork)
    }

    @Test func explicitSelectionCanChangeTheLibraryOriginEvenForTheSameSharedTrack() {
        let controller = PlaybackController(web: SamplyWebSession())
        controller.apply(playback("shared-track"), libraryItem: albumA)
        controller.apply(playback("shared-track"), libraryItem: albumB)
        #expect(controller.artwork == albumB.artwork)
    }

    @Test func delayedAlbumDataCanResolveANewPlayingTrackOnALaterSnapshot() {
        let controller = PlaybackController(web: SamplyWebSession())
        controller.apply(playback("track-a"), libraryItem: albumA)
        var loading = snapshot(fileID: "track-b", route: albumB, visibleFileID: "track-b")
        loading = WebSnapshot(version: loading.version, account: loading.account,
                              libraryReady: true, library: loading.library, routeID: loading.routeID,
                              boxesReady: false, boxes: [], playback: loading.playback, capabilities: [])
        controller.applySnapshot(loading)
        controller.applySnapshot(snapshot(fileID: "track-b", route: albumB, visibleFileID: "track-b"))
        #expect(controller.artwork == albumB.artwork)
    }

    @Test func missingLibraryArtworkAndClearedPlaybackDoNotReuseAnUnrelatedCover() {
        let controller = PlaybackController(web: SamplyWebSession())
        controller.apply(playback("track-a"), libraryItem: albumA)
        var noArtwork = albumB
        noArtwork.artwork = nil
        controller.apply(playback("track-b"), libraryItem: noArtwork)
        #expect(controller.artwork == nil)
        controller.clear()
        #expect(controller.libraryItem == nil)
        #expect(controller.artwork == nil)

        controller.apply(playback("track-a"), libraryItem: albumA)
        controller.apply(.empty)
        #expect(controller.libraryItem == nil)
        #expect(controller.artwork == nil)
    }
}
