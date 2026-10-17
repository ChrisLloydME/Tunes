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
                    Button { Task { await backend.refreshLibrary() } } label: {
                        Label("Refresh Library", systemImage: "arrow.clockwise")
                            .labelStyle(.iconOnly)
                            .font(.system(size: 20, weight: .semibold))
                            .imageScale(.small)
                            .frame(width: 24, height: 24)
                    }
                    .help("Refresh Library")
                    .accessibilityLabel("Refresh Library")
                    Button { backend.web.showWindow() } label: {
                        Label("Open in Samply", systemImage: "arrow.up.forward.app")
                            .labelStyle(.iconOnly)
                            .font(.system(size: 20, weight: .medium))
                            .imageScale(.medium)
                            .frame(width: 24, height: 24)
                    }
                    .help("Open in Samply")
                    .accessibilityLabel("Open in Samply")
                    .accessibilityIdentifier("openInSamply")
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
        if backend.isCheckingSession {
            ProgressView("Loading your Samply session…")
        } else if !backend.isConnected {
            ContentUnavailableView {
                Label("Connect to Samply", systemImage: "waveform")
            } description: {
                Text("Sign in to listen to your music.")
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
            AlbumDetailView(backend: backend, item: item) {
                if backend.hasToken { backend.chooseUpload() } else { showConnection = true }
            }
        } else if !backend.libraryReady {
            ProgressView("Loading your Samply library…")
        } else {
            LibraryView(items: backend.library, isOpeningProject: backend.isPlayingSelection) { item in
                backend.select(item)
                showsProject = true
            }
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

}
