import SwiftUI

struct ContentView: View {
    @Bindable var backend: SamplyBackend
    @State private var showConnection = false
    @State private var showsProject = false
    @State private var showsIssueDetails = false

    private var issue: String? { backend.error ?? backend.playback.error ?? backend.web.connectionError }

    private var currentPage: SamplyPage {
        if showsProject, let item = backend.selectedItem {
            return .album(routeID: item.routeID, groupID: backend.folderPath.last?.id)
        }
        return .library
    }

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
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let account = backend.web.profile.account {
                    SidebarProfileView(account: account, avatarData: backend.web.profile.avatarData)
                        .id(account.uid)
                }
            }
            .onKeyPress(.return) {
                showsProject = false
                return .handled
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 260)
        } detail: {
            VStack(spacing: 0) {
                mainContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                uploadStatus
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                PlayerBar(playback: backend.playback, isSelectingTrack: backend.isPlayingSelection)
            }
            .navigationTitle(showsProject ? backend.selectedItem?.name ?? "Library" : "Library")
            .toolbar {
                ToolbarItem {
                    if let issue {
                        Button { showsIssueDetails.toggle() } label: {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 16, weight: .medium))
                        }
                        .help(issue)
                        .accessibilityLabel("Samply needs attention")
                        .accessibilityIdentifier("samplyIssue")
                        .popover(isPresented: $showsIssueDetails) {
                            VStack(alignment: .leading, spacing: 16) {
                                Text("Samply needs attention").font(.headline)
                                Text(issue).font(.callout).textSelection(.enabled)
                                if backend.needsActionRecovery {
                                    Text("Trying to reconnect automatically…").font(.caption).foregroundStyle(.secondary)
                                }
                                HStack {
                                    Button("Try Again") { Task { await backend.recover(currentPage, forcePageRefresh: true) } }
                                        .disabled(backend.isRefreshing || backend.isBrowsing || backend.isPlayingSelection)
                                    Button("Open in Samply") { Task { await backend.openInSamply(currentPage) } }
                                        .disabled(backend.isOpeningSamply)
                                }
                            }
                            .padding(20)
                            .frame(width: 340, alignment: .leading)
                        }
                    }
                }
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
                    Button { Task { await backend.refresh(currentPage) } } label: {
                        Label(currentPage.refreshLabel, systemImage: "arrow.clockwise")
                            .labelStyle(.iconOnly)
                            .font(.system(size: 20, weight: .semibold))
                            .imageScale(.small)
                            .frame(width: 24, height: 24)
                    }
                    .help(currentPage.refreshLabel)
                    .accessibilityLabel(currentPage.refreshLabel)
                    .disabled(!backend.isConnected || backend.isRefreshing || backend.isBrowsing || backend.isPlayingSelection || backend.isOpeningSamply)
                    Button { Task { await backend.openInSamply(currentPage) } } label: {
                        Label("Open in Samply", systemImage: "arrow.up.forward.app")
                            .labelStyle(.iconOnly)
                            .font(.system(size: 20, weight: .medium))
                            .imageScale(.medium)
                            .frame(width: 24, height: 24)
                    }
                    .help("Open in Samply")
                    .accessibilityLabel("Open in Samply")
                    .accessibilityIdentifier("openInSamply")
                    .disabled(backend.isOpeningSamply || backend.isBrowsing || backend.isPlayingSelection || backend.isRefreshing)
                }
            }
        }
        .sheet(isPresented: $showConnection) { ConnectionView(backend: backend) }
        .focusedSceneValue(\.samplyPage, currentPage)
        .frame(minWidth: 860, minHeight: 560)
        .task { backend.start() }
        .task(id: "\(currentPage)/\(backend.needsActionRecovery)") {
            guard backend.needsActionRecovery else { return }
            let page = currentPage
            var delay = 250
            while backend.needsActionRecovery, !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(delay)) }
                catch { return }
                guard !Task.isCancelled else { return }
                await backend.recover(page)
                delay = min(delay * 2, 2000)
            }
        }
        .onChange(of: issue) { _, value in
            if value == nil { showsIssueDetails = false }
        }
        .onChange(of: backend.selectedItem?.id) { _, id in
            if id == nil { showsProject = false }
        }
    }

    @ViewBuilder private var mainContent: some View {
        if backend.isCheckingSession {
            ProgressView("Loading your Samply session…")
        } else if !backend.isConnected {
            ScrollView {
                VStack(spacing: 28) {
                    VStack(spacing: 12) {
                        Image(systemName: "waveform")
                            .font(.system(size: 40, weight: .medium))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                            .padding(.bottom, 8)
                        Text("Your music starts here")
                            .font(.largeTitle.weight(.semibold))
                        Text("Connect to Samply to browse your library and listen.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.center)

                    Button { backend.web.showSignIn() } label: {
                        Text("Sign In to Samply")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("connectSamply")
                }
                .frame(maxWidth: 400)
                .padding(40)
                .frame(maxWidth: .infinity, minHeight: 440)
            }
            .defaultScrollAnchor(.center)
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
