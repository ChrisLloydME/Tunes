import SwiftUI

struct ContentView: View {
    @Bindable var backend: SamplyBackend
    @State private var showConnection = false
    @State private var showsProject = false

    var body: some View {
        NavigationSplitView {
            List(selection: Binding<String?>(
                get: { "library" },
                set: { _ in showsProject = false }
            )) {
                Label("Library", systemImage: "square.stack")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .tag("library")
                    .accessibilityIdentifier("libraryNavigation")
                    .simultaneousGesture(TapGesture().onEnded { showsProject = false })
                    .accessibilityAction { showsProject = false }
            }
            .listStyle(.sidebar)
            .onKeyPress(.return) {
                showsProject = false
                return .handled
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 260)
        } detail: {
            VStack(spacing: 0) {
                mainContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                PlayerBar(playback: backend.playback, isSelectingTrack: backend.isPlayingSelection)
            }
            .navigationTitle(showsProject ? backend.selectedItem?.name ?? "Library" : "Library")
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    if showsProject {
                        Button {
                            if backend.folderPath.isEmpty { showsProject = false }
                            else { backend.goUp() }
                        } label: { Image(systemName: "chevron.left") }
                        .help(backend.folderPath.isEmpty ? "Back to Library" : "Go Up")
                        .accessibilityLabel(backend.folderPath.isEmpty ? "Back to Library" : "Go Up")
                        .disabled(backend.isPlayingSelection)
                    }
                }
                ToolbarItemGroup {
                    Button { Task { await backend.refreshLibrary() } } label: { Image(systemName: "arrow.clockwise") }
                        .help("Refresh Library")
                        .accessibilityLabel("Refresh Library")
                    Button("Samply Window", systemImage: "macwindow") { backend.web.showWindow() }
                    Button("Connection Settings", systemImage: "gearshape") { showConnection = true }
                }
            }
        }
        .sheet(isPresented: $showConnection) { ConnectionView(backend: backend) }
        .frame(minWidth: 860, minHeight: 560)
        .task { backend.start() }
        .onChange(of: backend.selectedItem?.id) { _, id in
            if id == nil { showsProject = false }
        }
    }

    @ViewBuilder private var mainContent: some View {
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
        } else if showsProject, let item = backend.selectedItem {
            projectContent(item)
        } else if !backend.libraryReady {
            ProgressView("Loading your Samply library…")
        } else {
            LibraryView(items: backend.library, isOpeningProject: backend.isPlayingSelection) { item in
                backend.select(item)
                showsProject = true
            }
        }
    }

    private func projectContent(_ item: LibraryItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom, spacing: 24) {
                ProjectArtwork(artwork: item.artwork, size: 160)
                VStack(alignment: .leading, spacing: 8) {
                    Text(backend.folderPath.last?.name ?? item.name)
                        .font(.system(size: 28, weight: .bold)).lineLimit(3)
                        .textSelection(.enabled)
                    if let artist = item.artist, !artist.isEmpty {
                        Text(artist).font(.title3).foregroundStyle(.secondary)
                    }
                    if !backend.folderPath.isEmpty {
                        Text(item.name).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if item.canUpload {
                        Button("Upload File", systemImage: "square.and.arrow.up") {
                            if backend.hasToken { backend.chooseUpload() } else { showConnection = true }
                        }
                        .padding(.top, 8)
                        .disabled(backend.uploader.isRunning || backend.isBrowsing)
                    }
                }
                Spacer(minLength: 0)
            }.padding(24)
            Divider().padding(.horizontal, 24)
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

    private func time(_ value: Double) -> String {
        let seconds = value.isFinite ? Int(max(0, min(value, 864000))) : 0
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
