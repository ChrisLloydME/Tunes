// Adapted directly from Kaset PlaylistTrackRow.swift (album branch), MIT license.
// Removed thumbnails, explicit badges, likes, and artist navigation. Samply supplies state/actions.
// See Docs/ThirdPartyNotices.md.
import SwiftUI

struct AlbumTrackRow<Menu: View>: View {
    let track: WebBox
    let index: Int
    let subtitle: String?
    let isCurrent: Bool
    let isPlaying: Bool
    let onPlay: () -> Void
    @ViewBuilder let menu: () -> Menu

    @State private var isHovered: Bool = false

    var body: some View {
        self.rowContent
            .background { self.playbackButton }
            .onHover { hovering in self.isHovered = hovering }
            .contextMenu { self.menu() }
    }

    private var rowContent: some View {
        return HStack(spacing: 12) {
            Group {
                if isCurrent {
                    NowPlayingIndicator(isPlaying: self.isPlaying, size: 14)
                } else {
                    Text("\(self.index + 1)")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 28, alignment: .trailing)
            .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(self.track.name)
                        .font(.system(size: 14))
                        .foregroundStyle(isCurrent ? .red : .primary)
                        .lineLimit(1)
                        .accessibilityHidden(true)
                }
                .allowsHitTesting(false)
                if let subtitle = self.subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(AlbumContents.durationText(self.track.duration))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 45, alignment: .trailing)
                .allowsHitTesting(false)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .opacity(self.isPlayable ? 1 : 0.5)
    }

    private var playbackButton: some View {
        Button(action: self.onPlay) {
            Color.clear
                .contentShape(Rectangle())
        }
        // The row's own `.onHover` drives the highlight: a second hover tracker per row
        // is enough to push long playlists past the frame budget while scrolling.
        // Unplayable rows never highlight, since their button is disabled.
        .buttonStyle(.interactiveRow(cornerRadius: 6, isHovered: self.isHovered && self.isPlayable))
        .disabled(!self.isPlayable)
        .accessibilityLabel(Text(verbatim: self.playbackAccessibilityLabel))
        .accessibilityHint(Text(String(localized: "Play")))
    }

    private var playbackAccessibilityLabel: String {
        guard let subtitle = self.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !subtitle.isEmpty
        else { return self.track.name }

        return "\(self.track.name), \(subtitle)"
    }

    private var isPlayable: Bool { self.track.isAudio && !self.track.isProcessing }
}
