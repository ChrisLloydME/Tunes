import Foundation
import MediaPlayer
import Observation

@MainActor
@Observable
final class PlaybackController {
    private(set) var state = WebPlayback.empty
    private(set) var libraryItem: LibraryItem?
    var artwork: String? { libraryItem?.artwork }
    private(set) var error: String?
    private(set) var hasTransientError = false
    @ObservationIgnored private let web: SamplyWebSession
    @ObservationIgnored private var libraryItemFileID: String?
    @ObservationIgnored private var remoteTargets: [(MPRemoteCommand, Any)] = []

    init(web: SamplyWebSession) { self.web = web }

    func apply(_ state: WebPlayback?, libraryItem: LibraryItem? = nil) {
        let hadPlayerError = self.state.error != nil
        self.state = state ?? .empty
        if self.state.fileID == nil {
            self.libraryItem = nil
            libraryItemFileID = nil
        } else if let libraryItem {
            self.libraryItem = libraryItem
            libraryItemFileID = self.state.fileID
        }
        if let failure = state?.error {
            error = failure
            hasTransientError = false
        } else if state != nil, hasTransientError || hadPlayerError {
            error = nil
            hasTransientError = false
        }
        updateNowPlaying()
    }

    func applySnapshot(_ snapshot: WebSnapshot) {
        libraryItem = libraryItem.map { current in
            snapshot.library.first { $0.id == current.id } ?? current
        }
        var resolvedItem: LibraryItem?
        // Navigation alone must not replace the playing album. Resolve a new origin
        // only for an unbound/new track that actually belongs to the loaded route.
        if libraryItem == nil || snapshot.playback?.fileID != libraryItemFileID,
           let fileID = snapshot.playback?.fileID, snapshot.boxesReady,
           snapshot.boxes.contains(where: {
               $0.id == fileID || $0.activeID == fileID || $0.childIDs.contains(fileID)
           }),
           let routeID = snapshot.routeID,
           let match = snapshot.library.first(where: { $0.routeID == routeID }) {
            resolvedItem = match
        }
        apply(snapshot.playback, libraryItem: resolvedItem)
    }

    func clear() {
        state = .empty
        libraryItem = nil
        libraryItemFileID = nil
        error = nil
        hasTransientError = false
        updateNowPlaying()
    }

    func perform(_ command: String, value: Any? = nil) async {
        do {
            let snapshot: WebSnapshot = try await web.call(command, arguments: value.map { ["value": $0] } ?? [:])
            applySnapshot(snapshot)
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
