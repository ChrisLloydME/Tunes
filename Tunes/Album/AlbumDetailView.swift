// Adapted directly from Kaset PlaylistDetailView.swift's album branch and
// PlaylistDetailView+HeaderActions.swift, revision 83513f6 (MIT).
// Removed playlist editing, likes, AI refinement, pinning, queue management,
// and artist navigation. Data, playback, folders, and optional uploads use Samply.
// See Docs/ThirdPartyNotices.md.
import SwiftUI

struct AlbumDetailView: View {
    @Bindable var backend: SamplyBackend
    let item: LibraryItem
    let requestUpload: () -> Void
    @State private var versionTrack: WebBox?

    private var contents: AlbumContents { AlbumContents(boxes: backend.boxes) }

    var body: some View {
        ScrollView {
            // Kaset keeps the header and track list in a single lazy scroll stack.
            LazyVStack(alignment: .leading, spacing: 0) {
                self.headerView()
                    .padding(.bottom, 24)

                Divider()
                    .padding(.bottom, 24)

                if backend.isBrowsing {
                    ProgressView("Loading album…")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 48)
                } else {
                    self.trackRows
                    self.folderRows
                    if contents.tracks.isEmpty, contents.folders.isEmpty {
                        ContentUnavailableView("No Songs Yet", systemImage: "music.note",
                                               description: Text("Songs in this album will appear here."))
                    }
                }
            }
            .padding(.vertical, 24)
            .detailScrollContentInset()
        }
        .topFade(style: .contentMask)
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .accentBackground(from: item.artwork.flatMap(URL.init(string:)))
        .toolbarBackgroundVisibility(.hidden, for: .automatic)
        .tint(Color("PlayerAccent"))
        .disabled(backend.isPlayingSelection)
        .sheet(item: $versionTrack) { track in
            AlbumVersionsView(backend: backend, track: track)
        }
    }

    private func headerView() -> some View {
        HStack(alignment: .top, spacing: 20) {
            // Thumbnail
            AsyncImage(url: self.item.artwork.flatMap(URL.init(string:))) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                Rectangle()
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                    }
            }
            .frame(width: 180, height: 180)
            .clipShape(.rect(cornerRadius: 8))

            // Info
            VStack(alignment: .leading, spacing: 8) {
                Text(self.backend.folderPath.isEmpty ? "Album" : "Folder")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                Text(self.backend.folderPath.last?.name ?? self.item.name)
                    .font(.title)
                    .fontWeight(.bold)

                if let artist = self.item.artist, !artist.isEmpty {
                    Text(artist)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(self.backend.isBrowsing ? "Loading…" : self.contents.metadataText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)

                Spacer(minLength: 24)

                self.headerButtons
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }


    private var headerButtons: some View {
        HStack(spacing: 16) {
            Button {
                if let track = contents.firstPlayableTrack { backend.play(track) }
            } label: {
                Label("Play", systemImage: "play.fill")
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(backend.isBrowsing || contents.firstPlayableTrack == nil)
            .accessibilityIdentifier("playAlbum")

            Menu {
                if item.canUpload {
                    Button("Upload File…", systemImage: "square.and.arrow.up", action: requestUpload)
                        .disabled(backend.uploader.isRunning || backend.isBrowsing)
                    Divider()
                }
                Button("Open in Samply", systemImage: "macwindow") { backend.web.showWindow() }
            } label: {
                Image(systemName: "ellipsis")
                    .accessibilityLabel("Album Actions")
            }
            .menuIndicator(.hidden)
            .buttonStyle(.bordered)
            .controlSize(.large)
            .fixedSize()
            .accessibilityIdentifier("albumActions")
        }
    }

    private var trackRows: some View {
        ForEach(Array(contents.tracks.enumerated()), id: \.element.id) { index, track in
            // Kaset groups each album row with its inset divider in one lazy element.
            VStack(spacing: 0) {
                AlbumTrackRow(
                    track: track,
                    index: index,
                    subtitle: track.isProcessing ? "Processing…" : item.artist,
                    isCurrent: backend.playback.state.fileID == (track.activeID ?? track.id),
                    isPlaying: backend.playback.state.playing,
                    onPlay: { backend.play(track) }
                ) {
                    Button("Play", systemImage: "play.fill") { backend.play(track) }
                        .disabled(!track.isAudio || track.isProcessing)
                    if track.kind == "stack", !track.childIDs.isEmpty {
                        Divider()
                        Button("Other Versions…") { versionTrack = track }
                    }
                }
                if index < contents.tracks.count - 1 {
                    Divider().padding(.leading, 40)
                }
            }
        }
    }

    @ViewBuilder private var folderRows: some View {
        if !contents.folders.isEmpty {
            Text("Folders")
                .font(.headline)
                .padding(.top, contents.tracks.isEmpty ? 0 : 24)
                .padding(.bottom, 12)
            ForEach(contents.folders) { folder in
                Button { backend.openFolder(folder) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "folder")
                            .frame(width: 28, alignment: .trailing)
                        Text(folder.name).lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }
                    .font(.system(size: 14))
                    .padding(.vertical, 12)
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.interactiveRow(cornerRadius: 6))
                .accessibilityHint("Open Folder")
            }
        }
    }
}
