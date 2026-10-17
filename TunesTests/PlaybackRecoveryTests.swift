import Testing
@testable import Tunes

@MainActor
struct PlaybackRecoveryTests {
    @Test func healthySnapshotClearsTransientCommandFailureWithoutChangingPlayback() {
        let controller = PlaybackController(web: SamplyWebSession())
        var state = WebPlayback.empty
        state.fileID = "fixture-track"
        state.playing = true
        state.position = 42
        controller.apply(state)
        controller.recordCommandFailure(SamplyBridgeError.executionFailed)
        #expect(controller.error != nil)
        #expect(controller.hasTransientError)
        controller.apply(state)
        #expect(controller.error == nil)
        #expect(!controller.hasTransientError)
        #expect(controller.state.fileID == "fixture-track")
        #expect(controller.state.playing)
        #expect(controller.state.position == 42)
    }

    @Test func rejectedCommandIsNotMistakenForRecoveryWhenOnlyAReadSucceeds() {
        let controller = PlaybackController(web: SamplyWebSession())
        controller.recordCommandFailure(SamplyBridgeError.operationFailed)
        controller.apply(.empty)
        #expect(controller.error != nil)
        #expect(!controller.hasTransientError)
    }

    @Test func resolvedPlayerErrorClearsItsOldMessage() {
        let controller = PlaybackController(web: SamplyWebSession())
        var state = WebPlayback.empty
        state.error = "Fixture playback failure"
        controller.apply(state)
        #expect(controller.error != nil)
        controller.apply(.empty)
        #expect(controller.error == nil)
    }
}
