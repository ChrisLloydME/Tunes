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
    private(set) var library: [LibraryItem] = []
    private(set) var boxes: [WebBox] = []
    private(set) var versions: [WebBox] = []
    private(set) var selectedItem: LibraryItem?
    private(set) var folderPath: [WebBox] = []
    private(set) var isBrowsing = false
    private(set) var isPlayingSelection = false
    private(set) var hasToken = false
    private(set) var error: String?
    @ObservationIgnored private let tokens: any TokenStore
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private var browseTask: Task<Void, Never>?
    @ObservationIgnored private var playTask: Task<Void, Never>?
    @ObservationIgnored private var selectionGeneration = 0
    @ObservationIgnored private var accountID: String?

    init(tokens: (any TokenStore)? = nil) {
        let tokens = tokens ?? MemoryTokenStore()
        self.tokens = tokens
        let web = SamplyWebSession()
        self.web = web
        let api = SamplyAPI(tokens: tokens)
        self.api = api
        playback = PlaybackController(web: web)
        uploader = SamplyUploader(api: api)
        do { hasToken = try tokens.read() != nil }
        catch { self.error = error.localizedDescription }
    }

    var isConnected: Bool { web.snapshot?.account != nil && !web.isSigningOut }
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
                await self.web.refresh()
                if !self.web.isSigningOut { self.acceptSnapshot() }
                try? await Task.sleep(for: .milliseconds(700))
            }
        }
    }

    private func acceptSnapshot() {
        guard let state = web.snapshot else { return }
        let newAccount = state.account?.uid
        if newAccount != accountID {
            invalidateSelection()
            library = []
            playback.clear()
            uploader.reset()
            // A PAT is a separate credential. Do not silently reuse account A's PAT for B.
            if accountID != nil {
                do { try tokens.remove(); hasToken = false }
                catch { self.error = error.localizedDescription }
            }
            accountID = newAccount
        }
        guard newAccount != nil else { return }
        if state.libraryReady { library = state.library }
        playback.apply(state.playback)
        if !isBrowsing, let selectedItem, state.routeID == selectedItem.routeID,
           state.levelID == folderPath.last?.id, state.boxesReady { boxes = state.boxes }
    }

    func select(_ item: LibraryItem) {
        invalidateSelection()
        selectedItem = item
        browse(item: item, groupID: nil)
    }

    func openFolder(_ box: WebBox) {
        guard box.kind == "folder", let item = selectedItem else { return }
        folderPath.append(box)
        versions = []
        browse(item: item, groupID: box.id)
    }

    func goUp() {
        guard !folderPath.isEmpty, let item = selectedItem else { return }
        folderPath.removeLast()
        versions = []
        browse(item: item, groupID: folderPath.last?.id)
    }

    private func browse(item: LibraryItem, groupID: String?) {
        browseTask?.cancel()
        selectionGeneration += 1
        let generation = selectionGeneration
        boxes = []
        isBrowsing = true
        error = nil
        browseTask = Task { [weak self] in
            guard let self else { return }
            do {
                var args: [String: Any] = ["routeID": item.routeID]
                if let groupID { args["groupID"] = groupID }
                let state: WebSnapshot = try await web.call("browse", arguments: args)
                try Task.checkCancellation()
                guard generation == selectionGeneration else { return }
                boxes = state.boxes
                isBrowsing = false
            } catch {
                guard generation == selectionGeneration else { return }
                isBrowsing = false
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    func showVersions(_ box: WebBox) async {
        let generation = selectionGeneration
        do {
            let items: [WebBox] = try await web.call("versions", arguments: ["fileID": box.id])
            guard generation == selectionGeneration else { return }
            versions = items
        } catch { self.error = error.localizedDescription }
    }

    func play(_ box: WebBox) {
        guard !isBrowsing, !isPlayingSelection, box.isAudio, !box.isProcessing,
              let selectedItem else { return }
        let generation = selectionGeneration
        isPlayingSelection = true
        error = nil
        playTask = Task { [weak self] in
            guard let self else { return }
            do {
                let state: WebSnapshot = try await web.call("playBox", arguments: [
                    "fileID": box.id, "routeID": selectedItem.routeID
                ])
                try Task.checkCancellation()
                guard generation == selectionGeneration else { return }
                playback.apply(state.playback)
            } catch {
                if generation == selectionGeneration, !Task.isCancelled { self.error = error.localizedDescription }
            }
            if generation == selectionGeneration { isPlayingSelection = false }
        }
    }

    func saveToken(_ token: String) async throws {
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
        try tokens.remove()
        hasToken = false
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

    func refreshLibrary() async {
        await web.refresh()
        acceptSnapshot()
    }

    func signOut() async {
        invalidateSelection()
        library = []
        playback.clear()
        uploader.reset()
        do { try tokens.remove(); hasToken = false }
        catch { self.error = error.localizedDescription }
        accountID = nil
        await web.signOut()
    }

    private func invalidateSelection() {
        selectionGeneration += 1
        browseTask?.cancel()
        playTask?.cancel()
        selectedItem = nil
        boxes = []
        versions = []
        folderPath = []
        isBrowsing = false
        isPlayingSelection = false
    }
}
