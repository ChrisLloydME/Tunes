// Adapted directly from Kaset PlayerBar.swift, revision 83513f6.
// Removed YouTube account actions, AirPlay, shuffle/repeat, lyrics, queue, video,
// mini player, and artist/album resolution. Playback data/actions use Samply.
// MIT license: see Docs/ThirdPartyNotices.md and Resources/Kaset-LICENSE.txt.
import SwiftUI

struct PlayerBar: View {
    private static let brandAccent = Color("PlayerAccent")
    private static let fullSongInfoWidth: CGFloat = 234
    private static let compactSongInfoWidth: CGFloat = 116

    @Bindable var playback: PlaybackController
    let isSelectingTrack: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Namespace private var playerNamespace
    @State private var seekValue: Double = 0
    @State private var isSeeking = false
    @State private var seekHold = PlayerBarSeekHold()
    @State private var volumeValue: Double = 1
    @State private var isAdjustingVolume = false
    @State private var showsVolumeOverlay = false
    @State private var formattedProgress = "0:00"
    @State private var formattedRemaining = "-0:00"
    @State private var lastProgressSecond = -1
    private var state: WebPlayback { playback.state }

    var body: some View {
        CompatGlassContainer(spacing: 0) {
            GeometryReader { proxy in
                let usesCompactDetails = proxy.size.width <= 736

                HStack(spacing: 10) {
                    self.songInfoSection(usesCompactDetails: usesCompactDetails)
                        .frame(
                            width: usesCompactDetails ? Self.compactSongInfoWidth : Self.fullSongInfoWidth,
                            height: 52
                        )

                    self.progressSection
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)

                    self.playbackOptionsSection
                        .frame(width: 142, height: 52)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .compatGlass(interactive: true, in: .capsule)
            .compatGlassID("playerBar", in: self.playerNamespace)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .background(alignment: .bottom) {
            self.playerAreaFade
        }
        .zIndex(1)
        .onChange(of: self.state.position) { _, newValue in
            self.seekHold.reconcile(observedProgress: newValue)
            let displayProgress = self.displayProgress(observedProgress: newValue)

            if !self.isSeeking, !self.seekHold.isActive, self.state.duration > 0 {
                self.seekValue = displayProgress / self.state.duration
            }

            let currentSecond = displayProgress.isFinite ? Int(min(max(0, displayProgress), 864000)) : 0
            if currentSecond != self.lastProgressSecond {
                self.lastProgressSecond = currentSecond
                self.updateFormattedTimes(progress: displayProgress, duration: self.state.duration)
            }
        }
        .onChange(of: self.state.duration) { _, newValue in
            self.seekHold.reconcile(observedProgress: self.state.position)
            let displayProgress = self.displayedPlaybackProgress
            if !self.isSeeking, !self.seekHold.isActive, newValue > 0 {
                self.seekValue = displayProgress / newValue
            }
            self.updateFormattedTimes(progress: displayProgress, duration: newValue)
        }
        .onChange(of: self.currentSeekIdentity) { _, _ in
            self.clearSeekHold()
        }
        .onChange(of: self.state.volume) { _, newValue in
            if !self.isAdjustingVolume {
                self.volumeValue = newValue
            }
        }
        .onAppear {
            self.volumeValue = self.state.volume
            self.clearSeekHold()
            if self.state.duration > 0 {
                self.seekValue = self.state.position / self.state.duration
            }
        }
        .onDisappear { self.showsVolumeOverlay = false }
    }

    private var playerAreaFade: some View {
        LinearGradient(
            colors: [
                Color(nsColor: .windowBackgroundColor).opacity(0),
                Color(nsColor: .windowBackgroundColor).opacity(0.22),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 44)
        .frame(maxWidth: .infinity)
        .padding(.bottom, -8)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func songInfoSection(usesCompactDetails: Bool) -> some View {
        HStack(spacing: 8) {
            self.thumbnailView

            if !usesCompactDetails {
                self.songDetailsView
                    .frame(width: 110, alignment: .leading)
            }
        }
        .padding(.leading, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var thumbnailView: some View {
        PlayerBarArtworkView(
            width: 32,
            height: 32,
            cornerRadius: 6,
            glowSources: self.state.artwork.flatMap(URL.init(string:)).map { [$0] } ?? [],
            glowIdentity: self.state.fileID,
            glowTargetSize: CGSize(width: 64, height: 64),
            showsHoverOverlay: false
        ) {
            ProjectArtwork(artwork: self.state.artwork, size: 32, cornerRadius: 6)
        }
        .accessibilityIdentifier("playerBar.thumbnail")
    }

    private var songDetailsView: some View {
        VStack(alignment: .leading, spacing: 4) {
            PlayerBarMarqueeText(
                text: self.state.title ?? String(localized: "Not Playing"),
                font: .systemFont(ofSize: 13),
                color: .labelColor,
                height: 13,
                reduceMotion: self.reduceMotion
            )
            .id(self.currentTitleIdentity)
            .accessibilityIdentifier("playerBar.trackTitle")

            PlayerBarMetadataButton(
                text: self.artistName,
                isEnabled: false,
                isLoading: false,
                accessibilityIdentifier: "playerBar.trackArtist",
                action: {}
            )
        }
        .frame(height: 29, alignment: .leading)
    }

    private var currentTitleIdentity: String {
        [
            self.state.fileID ?? "none",
            self.state.title ?? "none",
        ].joined(separator: "|")
    }

    private var progressSection: some View {
        ZStack(alignment: .top) {
            PlayerBarProgressLane(
                fraction: self.displayFraction,
                accent: Self.brandAccent,
                elapsedText: self.isSeeking
                    ? self.formatTime(self.seekValue * self.state.duration)
                    : self.formattedProgress,
                remainingText: self.isSeeking
                    ? "-\(self.formatTime(max(0, self.state.duration - self.seekValue * self.state.duration)))"
                    : self.formattedRemaining,
                isLive: false,
                canSeek: self.canSeek,
                isLoading: self.isProgressLoading,
                onScrub: { fraction in
                    self.isSeeking = true
                    self.seekValue = fraction
                },
                onCommit: {
                    self.performSeek()
                }
            )
            .padding(.top, 18)
            .zIndex(1)
            .focusable(self.canSeek)
            .focusEffectDisabled()
            .onKeyPress(.leftArrow) { self.seekByKeyboard(-5) }
            .onKeyPress(.rightArrow) { self.seekByKeyboard(5) }

            self.progressActionButtons
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var progressActionButtons: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                PlayerBarIconButton(
                    action: self.previousTrack,
                    accessibilityID: "playerBar.previousButton",
                    accessibilityLabel: String(localized: "Previous track")
                ) {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 13, weight: .regular))
                        .frame(width: 8, height: 13)
                        .foregroundStyle(.primary)
                }
                .disabled(!self.state.canGoPrevious)

                PlayerBarIconButton(
                    action: self.playPause,
                    accessibilityID: "playerBar.playPauseButton",
                    accessibilityLabel: self.state.playing ? String(localized: "Pause") : String(localized: "Play")
                ) {
                    Image(systemName: self.state.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 20, weight: .regular))
                        .frame(width: 12, height: 20)
                        .foregroundStyle(.primary)
                        .contentTransition(.symbolEffect(.replace))
                }
                .compatGlassID("playPause", in: self.playerNamespace)

                PlayerBarIconButton(
                    action: self.nextTrack,
                    accessibilityID: "playerBar.nextButton",
                    accessibilityLabel: String(localized: "Next track")
                ) {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 13, weight: .regular))
                        .frame(width: 8, height: 13)
                        .foregroundStyle(.primary)
                }
                .disabled(!self.state.canGoNext)
            }

            PlayerBarIconButton(
                action: self.toggleVolumePopover,
                accessibilityLabel: String(localized: "Volume"),
                accessibilityValue: "\(Int(self.displayedVolume * 100))%"
            ) {
                Image(systemName: self.volumeIcon)
                    .font(.system(size: 15, weight: .regular))
                    .frame(width: 10, height: 15)
                    .foregroundStyle(.primary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .playerBarVolumeOverlay(isPresented: self.$showsVolumeOverlay) {
                self.volumeOverlay
            }
        }
        .disabled(self.state.fileID == nil || self.isSelectingTrack)
    }

    private var volumeOverlay: some View {
        CompatGlassContainer(spacing: 0) {
            VStack(spacing: 10) {
                Image(systemName: self.volumeIcon)
                    .font(.system(size: 15, weight: .regular))
                    .frame(width: 16, height: 16)
                    .foregroundStyle(.primary)

                PlayerBarVerticalSlider(
                    value: self.$volumeValue,
                    accent: Self.brandAccent,
                    accessibilityIdentifier: "playerBar.volumeSlider",
                    accessibilityLabel: String(localized: "Volume"),
                    onEditingChanged: { editing in
                        self.isAdjustingVolume = editing
                        if !editing {
                            self.perform("volume", value: self.volumeValue)
                        }
                    },
                    onValueChanged: { _, newValue in
                        if self.isAdjustingVolume {
                            self.perform("volume", value: newValue)
                        }
                    }
                )
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 16)
            .frame(width: 46, height: 168)
            .background {
                Capsule()
                    .fill(self.volumeOverlayFill)
            }
            .compatGlass(interactive: true, tint: self.volumeOverlayTint, in: .capsule)
            .shadow(color: self.volumeOverlayShadow, radius: 14, y: 5)
        }
    }

    private var volumeOverlayFill: Color {
        self.colorScheme == .dark ? .black.opacity(0.22) : .white.opacity(0.72)
    }

    private var volumeOverlayTint: Color {
        self.colorScheme == .dark ? .white.opacity(0.10) : .black.opacity(0.06)
    }

    private var volumeOverlayShadow: Color {
        self.colorScheme == .dark ? .black.opacity(0.36) : .black.opacity(0.18)
    }

    private var artistName: String { self.state.artist ?? self.state.album ?? "Samply" }
    private var canSeek: Bool {
        self.state.fileID != nil && self.state.duration > 0 && !self.isSelectingTrack
    }
    private var isProgressLoading: Bool {
        self.state.loading || self.state.buffering || self.isSelectingTrack
    }
    private func perform(_ command: String, value: Any? = nil) {
        Task { await self.playback.perform(command, value: value) }
    }
    private func previousTrack() { self.perform("previous") }
    private func playPause() { self.perform("toggle") }
    private func nextTrack() { self.perform("next") }

    private func seekByKeyboard(_ delta: Double) -> KeyPress.Result {
        guard self.canSeek else { return .ignored }
        self.seekValue = min(max(0, self.displayedPlaybackProgress + delta), self.state.duration) / self.state.duration
        self.isSeeking = true
        self.performSeek()
        return .handled
    }


    private var displayFraction: Double {
        if self.isSeeking {
            return min(max(0, self.seekValue), 1)
        }
        guard self.state.duration > 0 else { return 0 }
        return min(max(0, self.displayedPlaybackProgress / self.state.duration), 1)
    }

    private var displayedPlaybackProgress: TimeInterval {
        self.displayProgress(observedProgress: self.state.position)
    }

    private func displayProgress(observedProgress: TimeInterval) -> TimeInterval {
        self.seekHold.displayProgress(observedProgress: observedProgress)
    }

    private var currentSeekIdentity: String {
        self.state.fileID ?? "none"
    }

    private var playbackOptionsSection: some View {
        HStack(spacing: 6) {
            PlayerBarIconMenu(accessibilityLabel: "Audio Quality") {
                Button("AAC") { self.perform("quality", value: "compressed") }
                Button("Lossless") { self.perform("quality", value: "lossless") }
            } icon: {
                Image(systemName: "waveform")
                    .font(.system(size: 16, weight: .regular))
                    .frame(width: 16, height: 16)
                    .foregroundStyle(.primary)
            }
            .help("Audio Quality: \(self.state.quality == "lossless" ? "Lossless" : "AAC")")
            .accessibilityValue(self.state.quality == "lossless" ? "Lossless" : "AAC")
            .disabled(self.state.fileID == nil || self.isSelectingTrack)
        }
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
    }

    private func toggleVolumePopover() {
        withAnimation(.easeOut(duration: 0.15)) {
            self.showsVolumeOverlay.toggle()
        }
    }

    private func performSeek() {
        guard self.isSeeking, self.canSeek else { return }
        let seekTime = self.seekValue * self.state.duration
        let holdID = self.seekHold.begin(target: seekTime)
        self.updateFormattedTimes(progress: seekTime, duration: self.state.duration)
        self.isSeeking = false

        Task {
            await self.playback.perform("seek", value: seekTime)
        }
        Task { @MainActor in
            try? await Task.sleep(for: PlayerBarSeekHold.timeout)
            if self.seekHold.clearIfCurrent(holdID) {
                self.syncSeekValueFromDisplayedProgress()
                self.updateFormattedTimes(
                    progress: self.displayedPlaybackProgress,
                    duration: self.state.duration
                )
            }
        }
    }

    private func clearSeekHold() {
        self.seekHold.clear()
        self.isSeeking = false
        self.syncSeekValueFromDisplayedProgress()
        self.updateFormattedTimes(
            progress: self.displayedPlaybackProgress,
            duration: self.state.duration
        )
    }

    private func syncSeekValueFromDisplayedProgress() {
        if self.state.duration > 0 {
            self.seekValue = self.displayedPlaybackProgress / self.state.duration
        } else {
            self.seekValue = 0
        }
    }

    private func updateFormattedTimes(progress: TimeInterval, duration: TimeInterval) {
        self.formattedProgress = self.formatTime(progress)
        self.formattedRemaining = "-\(self.formatTime(max(0, duration - progress)))"
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let totalSeconds = Int(min(seconds, 864000))
        let hours = totalSeconds / 3600
        let mins = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, mins, secs)
        } else {
            return String(format: "%d:%02d", mins, secs)
        }
    }

    private var volumeIcon: String {
        if self.displayedVolume == 0 {
            "speaker.slash.fill"
        } else if self.displayedVolume < 0.5 {
            "speaker.wave.1.fill"
        } else {
            "speaker.wave.2.fill"
        }
    }

    private var displayedVolume: Double {
        self.isAdjustingVolume ? self.volumeValue : self.state.volume
    }
}
