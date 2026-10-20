import AppKit
import Foundation
import Observation

/// Composition root for the current web-session and REST integration.
@MainActor
@Observable
final class SamplyBackend {
    let web: SamplyWebSession
    let api: SamplyAPI
    let playback: PlaybackController
    let uploader: SamplyUploader
    let projectCreation: ProjectCreationCoordinator
    private(set) var library: [LibraryItem] = []
    private(set) var boxes: [WebBox] = []
    private(set) var selectedItem: LibraryItem?
    private(set) var folderPath: [WebBox] = []
    private(set) var isBrowsing = false
    private(set) var albumLoadState: AlbumLoadState = .idle
    private(set) var isPlayingSelection = false
    private(set) var isRefreshing = false
    private(set) var isOpeningSamply = false
    private(set) var hasToken = false
    private(set) var error: String?
    private(set) var hasTransientError = false
    @ObservationIgnored private let tokens: any TokenStore
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private var browseTask: Task<Void, Never>?
    @ObservationIgnored private var playTask: Task<Void, Never>?
    @ObservationIgnored private var selectionGeneration = 0
    @ObservationIgnored private var accountID: String?
    @ObservationIgnored private var hasResolvedTokenAccount = false

    init(tokens: (any TokenStore)? = nil) {
        let tokens = tokens ?? FileTokenStore.applicationStore()
        self.tokens = tokens
        let web = SamplyWebSession()
        self.web = web
        let api = SamplyAPI(tokens: tokens)
        self.api = api
        playback = PlaybackController(web: web)
        uploader = SamplyUploader(api: api)
        projectCreation = ProjectCreationCoordinator(api: api, web: web, fileUploader: uploader)
        do { hasToken = try tokens.read() != nil }
        catch { recordFailure(error) }
        projectCreation.onLibraryRefreshed = { [weak self] items in
            self?.library = items
        }
        projectCreation.onProjectOpened = { [weak self] item, snapshot in
            self?.acceptCreatedProject(item, snapshot)
        }
    }

    var isConnected: Bool { web.snapshot?.account != nil && !web.isSigningOut }
    var isCheckingSession: Bool { web.authenticationState == .checking }
    var libraryReady: Bool { web.snapshot?.libraryReady == true }

    func start() {
        // Hosted unit tests must not load an existing real beta account or contact Samply.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              NSClassFromString("XCTestCase") == nil else { return }
        guard monitor == nil else { return }
        web.start()
        playback.registerMediaKeys()
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let refreshed = await self.web.refresh()
                if refreshed, !self.web.isSigningOut { self.acceptSnapshot() }
                try? await Task.sleep(for: self.web.pollInterval)
            }
        }
    }

    private func acceptSnapshot() {
        guard let state = web.snapshot, state.authenticationState != .checking else { return }
        let newAccount = state.account?.uid
        if !hasResolvedTokenAccount || newAccount != accountID {
            projectCreation.invalidate()
            invalidateSelection()
            library = []
            playback.clear()
            uploader.reset()
            // Restore only after identity resolves; never reuse account A's PAT for B.
            hasToken = false
            do {
                try tokens.restore(for: newAccount)
                hasToken = try tokens.read() != nil
            } catch { recordFailure(error) }
            accountID = newAccount
            hasResolvedTokenAccount = true
        }
        guard newAccount != nil else { return }
        if state.libraryReady { library = state.library }
        playback.applySnapshot(state)
        if !isBrowsing, let selectedItem,
           state.hasLoadedBoxes(for: selectedItem, groupID: folderPath.last?.id,
                                expectedProjectID: selectedItem.projectID) {
            boxes = state.boxes
            albumLoadState = .loaded
        }
    }

    var needsActionRecovery: Bool { hasTransientError || playback.hasTransientError }

    func recover(_ page: SamplyPage, forcePageRefresh: Bool = false) async {
        // Retry reads only. Never replay play/pause/seek/upload commands or reload the WebView.
        let needsPageRefresh = forcePageRefresh || hasTransientError
        if await web.refresh() { acceptSnapshot() }
        if needsPageRefresh { await refresh(page) }
    }

    private func recordFailure(_ failure: Error) {
        error = failure.localizedDescription
        hasTransientError = (failure as? SamplyBridgeError)?.isTransient == true
    }

    func select(_ item: LibraryItem) {
        invalidateSelection()
        selectedItem = item
        browse(item: item, groupID: nil)
    }

    func openFolder(_ box: WebBox) {
        guard box.kind == "folder", let item = selectedItem else { return }
        folderPath.append(box)
        browse(item: item, groupID: box.id)
    }

    func goUp() {
        guard !folderPath.isEmpty, let item = selectedItem else { return }
        folderPath.removeLast()
        browse(item: item, groupID: folderPath.last?.id)
    }

    private func browse(item: LibraryItem, groupID: String?) {
        browseTask?.cancel()
        selectionGeneration += 1
        let generation = selectionGeneration
        boxes = []
        isBrowsing = true
        albumLoadState = .loading
        error = nil
        hasTransientError = false
        browseTask = Task { [weak self] in
            guard let self else { return }
            do {
                var args: [String: Any] = ["routeID": item.routeID]
                if let projectID = item.projectID { args["projectID"] = projectID }
                if let groupID { args["groupID"] = groupID }
                let state: WebSnapshot = try await web.call("browse", arguments: args)
                try Task.checkCancellation()
                guard generation == selectionGeneration else { return }
                if state.hasLoadedBoxes(for: item, groupID: groupID,
                                        expectedProjectID: item.projectID) {
                    boxes = state.boxes
                    albumLoadState = .loaded
                }
                isBrowsing = false
            } catch {
                guard generation == selectionGeneration else { return }
                isBrowsing = false
                albumLoadState = .failed
                if !Task.isCancelled { recordFailure(error) }
            }
        }
    }

    func versions(for box: WebBox) async throws -> [WebBox] {
        let generation = selectionGeneration
        let items: [WebBox] = try await web.call("versions", arguments: ["fileID": box.id])
        try Task.checkCancellation()
        guard generation == selectionGeneration else { throw CancellationError() }
        return items
    }

    func play(_ box: WebBox) {
        guard albumLoadState == .loaded, !isBrowsing, !isPlayingSelection, box.isAudio, !box.isProcessing,
              let selectedItem else { return }
        let generation = selectionGeneration
        isPlayingSelection = true
        error = nil
        hasTransientError = false
        playTask = Task { [weak self] in
            guard let self else { return }
            do {
                let state: WebSnapshot = try await web.call("playBox", arguments: [
                    "fileID": box.id, "routeID": selectedItem.routeID
                ])
                try Task.checkCancellation()
                guard generation == selectionGeneration else { return }
                playback.apply(state.playback, libraryItem: selectedItem)
            } catch {
                if generation == selectionGeneration, !Task.isCancelled { recordFailure(error) }
            }
            if generation == selectionGeneration { isPlayingSelection = false }
        }
    }

    func saveToken(_ token: String) async throws {
        guard isConnected, accountID != nil else { throw SamplyError.noAccount }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\n"), !trimmed.contains("\r") else { throw SamplyError.invalidToken }
        // Validate before replacing a working credential. Never retain a rejected token.
        let account = accountID
        let generation = selectionGeneration
        _ = try await api.projects(token: trimmed)
        guard account == accountID, generation == selectionGeneration, !web.isSigningOut else {
            throw CancellationError()
        }
        try tokens.save(trimmed)
        hasToken = true
    }

    func removeToken() throws {
        uploader.reset()
        hasToken = false
        try tokens.remove()
    }

    func chooseUpload() {
        guard hasToken, let item = selectedItem, item.canUpload, let projectID = item.projectID else { return }
        let parentID = folderPath.last?.id
        let generation = selectionGeneration
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Upload the original file to \(item.name)"
        panel.prompt = "Upload"
        panel.begin { [weak self] response in
            guard response == .OK, let file = panel.url else { return }
            Task { @MainActor in
                guard let self, self.selectedItem?.id == item.id, self.selectionGeneration == generation, self.hasToken else { return }
                self.uploader.upload(file: file, projectID: projectID, parentID: parentID)
            }
        }
    }

    func refresh(_ page: SamplyPage) async {
        guard isConnected, !isRefreshing, !isBrowsing, !isPlayingSelection else { return }
        let generation = selectionGeneration
        let account = web.snapshot?.account?.uid
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let state: WebSnapshot = try await web.call("refreshPage", arguments: page.arguments)
            try Task.checkCancellation()
            guard state.version == 1 else { throw SamplyError.invalidResponse }
            guard account == web.snapshot?.account?.uid, state.account?.uid == account,
                  !web.isSigningOut else { return }
            switch page {
            case .library:
                guard state.libraryReady else { throw SamplyError.invalidResponse }
                library = state.library
            case .album(let routeID, let groupID):
                guard generation == selectionGeneration, let selectedItem,
                      selectedItem.routeID == routeID, folderPath.last?.id == groupID else { return }
                guard state.hasLoadedBoxes(for: selectedItem, groupID: groupID,
                                           expectedProjectID: selectedItem.projectID) else {
                    throw SamplyError.invalidResponse
                }
                boxes = state.boxes
                albumLoadState = .loaded
            }
            // Refresh only updates page data. The media engine and native playback stay intact.
            error = nil
            hasTransientError = false
        } catch is CancellationError { }
        catch {
            if generation == selectionGeneration, account == web.snapshot?.account?.uid {
                recordFailure(error)
            }
        }
    }

    func openInSamply(_ page: SamplyPage) async {
        guard !isOpeningSamply else { return }
        guard isConnected else { web.showWindow(); return }
        isOpeningSamply = true
        defer { isOpeningSamply = false }
        do {
            let _: Bool = try await web.call("navigatePage", arguments: page.arguments)
            error = nil
            hasTransientError = false
            web.showWindow()
        } catch is CancellationError { }
        catch { recordFailure(error) }
    }

    func signOut() async {
        projectCreation.invalidate()
        invalidateSelection()
        library = []
        playback.clear()
        uploader.reset()
        hasToken = false
        do { try tokens.remove() }
        catch { recordFailure(error) }
        accountID = nil
        await web.signOut()
    }

    /// Applies a project opened through the adapter after REST creation. The
    /// complete Library was already refreshed, so a delayed history entry is not
    /// fabricated into the native grid.
    private func acceptCreatedProject(_ item: LibraryItem, _ snapshot: WebSnapshot) {
        guard web.snapshot?.account?.uid == snapshot.account?.uid else { return }
        var opened = item
        if let routeID = snapshot.routeID, !routeID.isEmpty { opened.shareID = routeID }
        if let projectID = snapshot.projectID { opened.projectID = projectID }
        invalidateSelection()
        selectedItem = opened
        boxes = snapshot.boxes
        albumLoadState = .loaded
        if let index = library.firstIndex(where: { $0.id == opened.id }) {
            library[index] = opened
        }
    }

    private func invalidateSelection() {
        if hasTransientError {
            error = nil
            hasTransientError = false
        }
        selectionGeneration += 1
        browseTask?.cancel()
        playTask?.cancel()
        selectedItem = nil
        boxes = []
        folderPath = []
        isBrowsing = false
        albumLoadState = .idle
        isPlayingSelection = false
    }
}
