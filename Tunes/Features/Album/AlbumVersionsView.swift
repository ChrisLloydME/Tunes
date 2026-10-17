import SwiftUI

/// Alternate recordings stay behind a track menu instead of occupying the album page.
struct AlbumVersionsView: View {
    @Bindable var backend: SamplyBackend
    let track: WebBox
    @Environment(\.dismiss) private var dismiss
    @State private var versions: [WebBox] = []
    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Other Versions").font(.title2.weight(.semibold))
                    Text(track.name).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if isLoading {
                ProgressView("Loading versions…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                ContentUnavailableView("Versions Unavailable", systemImage: "music.note",
                                       description: Text(error))
            } else if versions.isEmpty {
                ContentUnavailableView("No Other Versions", systemImage: "music.note")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(versions.enumerated()), id: \.element.id) { index, version in
                            AlbumTrackRow(
                                track: version, index: index,
                                subtitle: version.isProcessing ? "Processing…" : version.versionName,
                                isCurrent: backend.playback.state.fileID == (version.activeID ?? version.id),
                                isPlaying: backend.playback.state.playing,
                                onPlay: {
                                    backend.play(version)
                                    dismiss()
                                }, menu: { EmptyView() }
                            )
                            if index < versions.count - 1 { Divider().padding(.leading, 40) }
                        }
                    }
                    .disabled(backend.isPlayingSelection)
                }
            }
        }
        .padding(24)
        .frame(width: 540, height: 380)
        .task(id: track.id) {
            do {
                versions = try await backend.versions(for: track)
            } catch is CancellationError {
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            isLoading = false
        }
    }
}
