import Foundation
import MediaPlayer
import Observation

@MainActor
@Observable
final class PlaybackController {
    private(set) var state = WebPlayback.empty
    private(set) var error: String?
    private(set) var hasTransientError = false
    @ObservationIgnored private let web: SamplyWebSession
    @ObservationIgnored private var remoteTargets: [(MPRemoteCommand, Any)] = []

    init(web: SamplyWebSession) { self.web = web }

    func apply(_ state: WebPlayback?) {
        let hadPlayerError = self.state.error != nil
        self.state = state ?? .empty
        if let failure = state?.error {
            error = failure
            hasTransientError = false
        } else if state != nil, hasTransientError || hadPlayerError {
            error = nil
            hasTransientError = false
        }
        updateNowPlaying()
    }

    func clear() {
        state = .empty
        error = nil
        hasTransientError = false
        updateNowPlaying()
    }

    func perform(_ command: String, value: Any? = nil) async {
        do {
            let snapshot: WebSnapshot = try await web.call(command, arguments: value.map { ["value": $0] } ?? [:])
            apply(snapshot.playback)
            error = nil
            hasTransientError = false
        } catch is CancellationError { }
        catch { recordCommandFailure(error) }
    }

    func recordCommandFailure(_ failure: Error) {
        error = failure.localizedDescription
        hasTransientError = (failure as? SamplyBridgeError)?.isTransient == true
    }

    func registerMediaKeys() {
        guard remoteTargets.isEmpty else { return }
        let center = MPRemoteCommandCenter.shared()
        for (command, name) in [(center.playCommand, "play"), (center.pauseCommand, "pause"),
                                (center.togglePlayPauseCommand, "toggle"), (center.nextTrackCommand, "next"),
                                (center.previousTrackCommand, "previous")] {
            let target = command.addTarget { [weak self] _ in
                Task { @MainActor in await self?.perform(name) }
                return .success
            }
            remoteTargets.append((command, target))
        }
        let seek = center.changePlaybackPositionCommand
        let target = seek.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            Task { @MainActor in await self?.perform("seek", value: position) }
            return .success
        }
        remoteTargets.append((seek, target))
        updateNowPlaying()
    }

    private func updateNowPlaying() {
        let center = MPRemoteCommandCenter.shared()
        let ready = state.fileID != nil
        center.playCommand.isEnabled = ready
        center.pauseCommand.isEnabled = ready
        center.togglePlayPauseCommand.isEnabled = ready
        center.nextTrackCommand.isEnabled = ready && state.canGoNext
        center.previousTrackCommand.isEnabled = ready && state.canGoPrevious
        center.changePlaybackPositionCommand.isEnabled = ready && state.duration > 0
        let info = MPNowPlayingInfoCenter.default()
        guard ready else {
            info.nowPlayingInfo = nil
            info.playbackState = .stopped
            return
        }
        info.nowPlayingInfo = [
            MPMediaItemPropertyTitle: state.title ?? "Samply",
            MPMediaItemPropertyArtist: state.artist ?? "",
            MPMediaItemPropertyAlbumTitle: state.album ?? "",
            MPMediaItemPropertyPlaybackDuration: state.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: state.position,
            MPNowPlayingInfoPropertyPlaybackRate: state.playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]
        info.playbackState = state.playing ? .playing : .paused
    }
}
