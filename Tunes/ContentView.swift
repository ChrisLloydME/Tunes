import SwiftUI

struct ContentView: View {
    @Bindable var backend: SamplyBackend
    @State private var query = ""
    @State private var showConnection = false
    @State private var seekPosition: Double = 0
    @State private var isSeeking = false

    private var items: [LibraryItem] {
        backend.library.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) ||
            ($0.artist?.localizedCaseInsensitiveContains(query) ?? false) }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { backend.selectedItem?.id }, set: { id in
                if let item = backend.library.first(where: { $0.id == id }) { backend.select(item) }
            })) {
                Section("Library") {
                    ForEach(items) { item in
                        Label {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.name).lineLimit(1)
                                if let artist = item.artist, !artist.isEmpty {
                                    Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        } icon: {
                            Image(systemName: item.isOwned ? "square.stack" : "person.2")
                        }
                        .tag(item.id)
                    }
                }
            }
            .disabled(backend.isPlayingSelection || !backend.isConnected)
            .searchable(text: $query, prompt: "Search Library")
            .navigationSplitViewColumnWidth(min: 220, ideal: 265)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Image(systemName: backend.isConnected ? "person.crop.circle.fill" : "person.crop.circle")
                    Text(backend.web.snapshot?.account?.name ?? (backend.isConnected ? "Connected to Samply" : "Not Connected"))
                        .lineLimit(1)
                    Spacer()
                    Button { showConnection = true } label: { Image(systemName: "gearshape") }
                        .buttonStyle(.borderless).help("Connection Settings")
                }
                .font(.callout).padding()
            }
        } detail: {
            VStack(spacing: 0) {
                if !backend.isConnected {
                    ContentUnavailableView {
                        Label("Connect to Samply", systemImage: "waveform")
                    } description: {
                        Text("Sign in to browse your projects and shared music.")
                    } actions: {
                        VStack(spacing: 20) {
                            Button("Sign In to Samply") { backend.web.showWindow() }
                                .buttonStyle(.borderedProminent)
                                .accessibilityIdentifier("connectSamply")
                            EmailSignInLinkView(session: backend.web)
                                .frame(maxWidth: 440)
                        }
                    }
                } else if let item = backend.selectedItem {
                    projectContent(item)
                } else if !backend.libraryReady {
                    ProgressView("Loading your Samply library…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView(backend.library.isEmpty ? "Your Library Is Empty" : "Select a Project",
                                           systemImage: "square.stack", description: Text("Your projects and shared music appear in the sidebar."))
                }
                if let error = backend.error ?? backend.playback.error ?? backend.web.connectionError {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.triangle")
                        Text(error).textSelection(.enabled).font(.caption)
                        Spacer()
                        Button("Open Samply") { backend.web.showWindow() }
                    }
                    .padding(12).background(.quaternary)
                }
                uploadStatus
                Divider()
                playerBar
            }
            .navigationTitle(backend.selectedItem?.name ?? "Tunes")
            .toolbar {
                ToolbarItemGroup {
                    Button { Task { await backend.refreshLibrary() } } label: { Image(systemName: "arrow.clockwise") }
                        .help("Refresh Library")
                    Button("Samply Window", systemImage: "macwindow") { backend.web.showWindow() }
                    Button("Connection Settings", systemImage: "gearshape") { showConnection = true }
                }
            }
        }
        .sheet(isPresented: $showConnection) { ConnectionView(backend: backend) }
        .frame(minWidth: 860, minHeight: 560)
        .task { backend.start() }
    }

    private func projectContent(_ item: LibraryItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if !backend.folderPath.isEmpty {
                    Button { backend.goUp() } label: { Image(systemName: "chevron.left") }.help("Go Up")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(backend.folderPath.last?.name ?? item.name).font(.title2.weight(.semibold))
                    if let artist = item.artist { Text(artist).foregroundStyle(.secondary) }
                }
                Spacer()
                if item.canUpload {
                    Button("Upload File", systemImage: "square.and.arrow.up") {
                        if backend.hasToken { backend.chooseUpload() } else { showConnection = true }
                    }.disabled(backend.uploader.isRunning || backend.isBrowsing)
                }
            }.padding(20)
            Divider()
            if backend.isBrowsing {
                ProgressView("Loading project…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if backend.boxes.isEmpty {
                ContentUnavailableView("No Files to Display", systemImage: "folder",
                                       description: Text("Open the Samply window to check access to this project."))
            } else {
                List {
                    ForEach(backend.boxes) { box in boxRow(box, isVersion: false) }
                    if !backend.versions.isEmpty {
                        Section("Versions") {
                            ForEach(backend.versions) { box in boxRow(box, isVersion: true) }
                        }
                    }
                }.listStyle(.inset)
            }
        }
        .disabled(backend.isPlayingSelection)
    }

    private func boxRow(_ box: WebBox, isVersion: Bool) -> some View {
        HStack(spacing: 12) {
            Button {
                if box.kind == "folder" { backend.openFolder(box) }
                else { backend.play(box) }
            } label: {
                Image(systemName: box.kind == "folder" ? "folder" : box.kind == "stack" ? "square.stack" : box.isAudio ? "play.fill" : "doc")
                    .frame(width: 24)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(box.kind == "folder" ? "Open Folder" : "Play")
            .disabled(box.kind != "folder" && (!box.isAudio || box.isProcessing))
            VStack(alignment: .leading, spacing: 3) {
                Text(box.name).lineLimit(1)
                if box.isProcessing { Text("Processing in Samply…").font(.caption).foregroundStyle(.secondary) }
                else if isVersion, let name = box.versionName { Text(name).font(.caption).foregroundStyle(.secondary) }
            }
            if backend.playback.state.fileID == (box.activeID ?? box.id) {
                Image(systemName: "waveform").foregroundStyle(.tint).accessibilityLabel("Current Track")
            }
            Spacer()
            if let duration = box.duration { Text(time(duration)).monospacedDigit().foregroundStyle(.secondary) }
            if box.kind == "stack", !box.childIDs.isEmpty {
                Button("Versions (\(box.childIDs.count))") { Task { await backend.showVersions(box) } }
                    .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if box.kind == "folder" { backend.openFolder(box) }
            else { backend.play(box) }
        }
    }

    @ViewBuilder private var uploadStatus: some View {
        switch backend.uploader.status {
        case .idle: EmptyView()
        case .preparing, .uploading:
            HStack {
                VStack(alignment: .leading) {
                    Text("Uploading \(backend.uploader.fileName)").font(.caption)
                    ProgressView(value: backend.uploader.progress)
                }
                Button("Cancel") { backend.uploader.cancel() }
            }.padding()
        case .completed:
            Text("\(backend.uploader.fileName) uploaded. Waiting for Samply to process it.")
                .font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding()
        case .cancelled:
            Text("Upload cancelled").font(.caption).padding()
        case .failed(let error):
            Text("Upload failed: \(error)").font(.caption).textSelection(.enabled).padding()
        }
    }

    private var playerBar: some View {
        let state = backend.playback.state
        return VStack(spacing: 8) {
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(state.title ?? "Not Playing").fontWeight(.medium).lineLimit(1)
                    Text(state.album ?? "Samply").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Button { Task { await backend.playback.perform("previous") } } label: { Image(systemName: "backward.end.fill") }
                    .help("Previous Track").accessibilityLabel("Previous Track")
                    .disabled(!state.canGoPrevious)
                Button { Task { await backend.playback.perform("toggle") } } label: {
                    Image(systemName: state.playing ? "pause.fill" : "play.fill").font(.title3).frame(width: 24)
                }.help(state.playing ? "Pause" : "Play")
                    .accessibilityLabel(state.playing ? "Pause" : "Play")
                    .disabled(state.fileID == nil)
                Button { Task { await backend.playback.perform("next") } } label: { Image(systemName: "forward.end.fill") }
                    .help("Next Track").accessibilityLabel("Next Track")
                    .disabled(!state.canGoNext)
                if state.loading || state.buffering || backend.isPlayingSelection { ProgressView().controlSize(.small) }
                Menu(state.quality == "lossless" ? "Lossless" : "AAC") {
                    Button("AAC") { Task { await backend.playback.perform("quality", value: "compressed") } }
                    Button("Lossless") { Task { await backend.playback.perform("quality", value: "lossless") } }
                }.frame(width: 90).help("Audio Quality").disabled(state.fileID == nil)
                Image(systemName: "speaker.wave.2")
                Slider(value: Binding(get: { state.volume }, set: { value in
                    Task { await backend.playback.perform("volume", value: value) }
                }), in: 0...1).frame(width: 90).accessibilityLabel("Volume")
                    .disabled(state.fileID == nil)
            }.buttonStyle(.borderless)
            HStack {
                Text(time(isSeeking ? seekPosition : state.position)).monospacedDigit()
                Slider(value: Binding(get: { isSeeking ? seekPosition : min(state.position, max(state.duration, 1)) }, set: {
                    seekPosition = $0
                }), in: 0...max(state.duration, 1), onEditingChanged: { editing in
                    if editing { seekPosition = state.position }
                    isSeeking = editing
                    if !editing { Task { await backend.playback.perform("seek", value: seekPosition) } }
                })
                .disabled(state.duration <= 0).accessibilityLabel("Playback Position")
                Text(time(state.duration)).monospacedDigit()
            }.font(.caption).foregroundStyle(.secondary)
        }.padding(16)
    }

    private func time(_ value: Double) -> String {
        let seconds = value.isFinite ? Int(max(0, min(value, 864000))) : 0
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
