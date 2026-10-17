import Foundation
import Testing
@testable import Tunes

struct AlbumContentsTests {
    private func box(_ id: String, kind: String = "file", duration: Double? = nil,
                     isAudio: Bool = false, processing: Bool = false) -> WebBox {
        WebBox(id: id, name: id, kind: kind, duration: duration,
               isAudio: isAudio, isProcessing: processing, childIDs: [])
    }

    @Test func albumsCountSongsWithoutCountingFoldersDocumentsOrStackVersions() {
        let contents = AlbumContents(boxes: [
            box("folder", kind: "folder"),
            box("notes.pdf"),
            box("song.wav", duration: 120, isAudio: true),
            WebBox(id: "stack", name: "Mix", kind: "stack", activeID: "v2", duration: 180,
                   isAudio: true, isProcessing: false, childIDs: ["v1", "v2"])
        ])
        #expect(contents.tracks.map(\.id) == ["song.wav", "stack"])
        #expect(contents.folders.map(\.id) == ["folder"])
        #expect(contents.metadataText == "2 songs • 5 min")
    }

    @Test func playStartsWithTheFirstReadySongInTheOriginalOrder() {
        let ready = box("ready", duration: 90, isAudio: true)
        let contents = AlbumContents(boxes: [
            box("folder", kind: "folder"),
            box("processing", kind: "stack", isAudio: true, processing: true),
            box("unavailable", kind: "stack"),
            ready,
            box("next", duration: 120, isAudio: true)
        ])
        #expect(contents.firstPlayableTrack?.id == ready.id)
        #expect(AlbumContents(boxes: [box("pending", kind: "stack", processing: true)])
            .firstPlayableTrack == nil)
    }

    @Test func incompleteDurationsDoNotClaimACompleteAlbumRunningTime() {
        for duration: Double? in [nil, 0, -.infinity, .nan, .infinity] {
            let contents = AlbumContents(boxes: [box("track", duration: duration, isAudio: true)])
            #expect(contents.metadataText == "1 song")
        }
        #expect(AlbumContents(boxes: []).metadataText == "0 songs")
        #expect(AlbumContents.durationText(nil) == "—")
        #expect(AlbumContents.durationText(.nan) == "—")
        #expect(AlbumContents.durationText(3661) == "1:01:01")
    }
}
