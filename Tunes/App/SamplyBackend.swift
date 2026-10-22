import AppKit
import Foundation
import Observation

struct ProjectCreationNotice: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let canRetryUploads: Bool
    let canRetryArtwork: Bool
    let canRefreshLibrary: Bool
    let canOpenProject: Bool
    let canStartNewProject: Bool
}

/// Composition root for the current web-session and REST integration.
@MainActor
@Observable
final class SamplyBackend {
    let web: SamplyWebSession
    let api: SamplyAPI
    let playback: PlaybackController
    let uploader: SamplyUploader
    let credentials: ProjectCredentialAuthority
    let projectCreation: ProjectCreationCoordinator
    private(set) var content = SamplyContentAcceptance()
    var library: [LibraryItem] { content.library }
    var boxes: [WebBox] { content.boxes }
    private(set) var selectedItem: LibraryItem?
    private(set) var folderPath: [WebBox] = []
    private(set) var isBrowsing = false
    private(set) var albumLoadState: AlbumLoadState = .idle
    private(set) var isPlayingSelection = false
    private(set) var isRefreshing = false
    private(set) var isOpeningSamply = false
    private(set) var error: String?
    private(set) var hasTransientError = false
    private(set) var projectCreationNotice: ProjectCreationNotice?
    @ObservationIgnored private let tokens: any TokenStore
    @ObservationIgnored let diagnostics: SamplyDiagnostics
    @ObservationIgnored private let clock: any MonotonicClock
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private var browseTask: Task<Void, Never>?
    @ObservationIgnored private var playTask: Task<Void, Never>?
    @ObservationIgnored private var selectionGeneration = 0
    @ObservationIgnored private var sessionGeneration: UInt64 = 0
    @ObservationIgnored private var accountID: String?
    @ObservationIgnored private var hasResolvedTokenAccount = false
    @ObservationIgnored private var sessionStartedAt: TimeInterval?
    @ObservationIgnored private var hasRecordedSessionRestoration = false
    @ObservationIgnored private var hasRecordedLibraryAcceptance = false
    @ObservationIgnored private var pollSchedule = SamplyPollSchedule()
    @ObservationIgnored private var lastRuntimeIdentity: RuntimeIdentity?

    init(tokens: (any TokenStore)? = nil, diagnostics: SamplyDiagnostics? = nil,
         clock: (any MonotonicClock)? = nil) {
        let tokens = tokens ?? FileTokenStore.applicationStore()
        self.tokens = tokens
        self.diagnostics = diagnostics ?? .shared
        self.clock = clock ?? SystemMonotonicClock()
        let web = SamplyWebSession(diagnostics: diagnostics)
        self.web = web
        let api = SamplyAPI(tokens: tokens)
        self.api = api
        playback = PlaybackController(web: web)
        uploader = SamplyUploader(api: api)
        let credentials = ProjectCredentialAuthority(tokens: tokens, api: api, ownership: web)
        self.credentials = credentials
        projectCreation = ProjectCreationCoordinator(api: api, web: web, uploader: uploader,
                                                     credentials: credentials)
        projectCreation.onLibraryRefreshed = { [weak self] items in
            guard let self else { return }
            self.content.acceptLibrary(items)
            self.noteFullContentAccepted()
        }
        projectCreation.onProjectOpened = { [weak self] item, snapshot in
            self?.acceptCreatedProject(item, snapshot)
        }
        projectCreation.onBackgroundOutcome = { [weak self] in
            self?.refreshProjectCreationNotice()
        }
    }

    var isConnected: Bool { web.account != nil && !web.isSigningOut }
    var isCheckingSession: Bool { web.authenticationState == .checking }
    var libraryReady: Bool { web.snapshot?.libraryReady == true }
    var hasToken: Bool { credentials.hasStoredToken }
    var credentialState: ProjectCredentialState { credentials.state }
    var isCredentialVerified: Bool { credentials.verifiedCredential() != nil }

    func start() {
        // Hosted unit tests must not load an existing real beta account or contact Samply.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              NSClassFromString("XCTestCase") == nil else { return }
        guard monitor == nil else { return }
        sessionStartedAt = clock.now()
        web.start()
        playback.registerMediaKeys()
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.poll()
                let delay = self.pollSchedule.nextPollDelay(
                    at: self.clock.now(), interactive: self.isInteractive)
                do { try await Task.sleep(for: delay) }
                catch { return }
            }
        }
    }

    /// True while a user action owns the bridge. Background full reads wait; the
    /// runtime clock continues so playback stays current.
    private var isInteractive: Bool {
        isBrowsing || isRefreshing || isPlayingSelection || isOpeningSamply
    }

    /// The single polling owner: one runtime sample per tick, plus a complete
    /// content read when it is due or invalidated.
    private func poll() async {
        if await web.refreshRuntime(), !web.isSigningOut {
            acceptRuntimeSnapshot()
        }
        guard !isInteractive, pollSchedule.shouldReadFullContent(at: clock.now()) else { return }
        let generation = pollSchedule.invalidationGeneration
        let refreshed = await web.refresh()
        if refreshed, !web.isSigningOut {
            acceptSnapshot()
            pollSchedule.recordFullRead(at: clock.now(), succeeded: true,
                                        generation: generation)
        } else {
            pollSchedule.recordFullRead(at: clock.now(), succeeded: false,
                                        generation: generation)
        }
    }

    @discardableResult
    private func acceptIdentity(_ account: WebSnapshot.Account?) -> Bool {
        let newAccount = account?.uid
        guard !hasResolvedTokenAccount || newAccount != accountID else { return false }
        sessionGeneration &+= 1
        projectCreation.invalidate()
        invalidateSelection()
        content.acceptLibrary([])
        playback.clear()
        uploader.reset()
        // Restore and revalidate only after identity resolves; never reuse
        // account A's PAT for B, and never treat the stored account ID as proof.
        credentials.activate(accountID: newAccount, generation: sessionGeneration)
        accountID = newAccount
        hasResolvedTokenAccount = true
        return true
    }

    /// Applies identity, route/readiness, capabilities, and playback without
    /// substituting an empty Library or box array. Full content arrives through
    /// `acceptSnapshot` when the schedule says it is due.
    private func acceptRuntimeSnapshot() {
        guard let runtime = web.runtimeSnapshot,
              runtime.authenticationState != .checking else { return }
        let identityChanged = acceptIdentity(runtime.account)
        guard runtime.account != nil else { return }

        let identity = RuntimeIdentity(routeID: runtime.routeID,
                                       projectID: runtime.projectID,
                                       levelID: runtime.levelID,
                                       boxesReady: runtime.boxesReady)
        if identity != lastRuntimeIdentity {
            lastRuntimeIdentity = identity
            pollSchedule.markFullContentNeeded()
        } else if identityChanged || web.snapshot == nil {
            pollSchedule.markFullContentNeeded()
        }

        // Box evidence is valid only when the sampled route is the accepted
        // displayed route. Otherwise a new track stays unresolved until the
        // next full snapshot rather than borrowing the displayed album.
        let trustedBoxes: [WebBox]
        if runtime.routeID == selectedItem?.routeID, albumLoadState == .loaded {
            trustedBoxes = boxes
        } else {
            trustedBoxes = []
        }
        playback.applyRuntime(runtime.playback, routeID: runtime.routeID,
                              trustedLibrary: library, trustedBoxes: trustedBoxes)
    }

    private func acceptSnapshot() {
        guard let state = web.snapshot, state.authenticationState != .checking else { return }
        let identityChanged = acceptIdentity(state.account)
        guard state.account != nil else { return }
        if identityChanged { pollSchedule.markFullContentNeeded() }
        if !hasRecordedSessionRestoration, let sessionStartedAt {
            record(.sessionRestoration, since: sessionStartedAt)
            hasRecordedSessionRestoration = true
        }
        if state.libraryReady {
            if !hasRecordedLibraryAcceptance, let sessionStartedAt {
                record(.libraryAcceptance, since: sessionStartedAt,
                       itemCount: state.library.count)
                hasRecordedLibraryAcceptance = true
            }
            content.acceptLibrary(state.library)
        }
        playback.applySnapshot(state)
        if !isBrowsing, let selectedItem,
           state.hasLoadedBoxes(for: selectedItem, groupID: folderPath.last?.id,
                                expectedProjectID: selectedItem.projectID) {
            content.acceptBoxes(state.boxes)
            albumLoadState = .loaded
        }
    }

    /// Explicit command results and accepted content reads count as a fresh
    /// full read for cadence purposes; they must not be repeated immediately by
    /// the background poll.
    private func noteFullContentAccepted() {
        pollSchedule.recordFullRead(at: clock.now(), succeeded: true,
                                    generation: pollSchedule.invalidationGeneration)
    }

    /// Diagnostics carry only fixed stages and counts; never names, URLs, or IDs.
    private func record(_ stage: SamplyDiagnosticStage, since start: TimeInterval,
                        itemCount: Int = 0, outcome: SamplyDiagnosticOutcome = .success) {
        guard diagnostics.isEnabled else { return }
        diagnostics.record(SamplyDiagnosticSample(
            stage: stage, operationID: diagnostics.nextOperationID(),
            duration: clock.now() - start, itemCount: itemCount, outcome: outcome))
    }

    var needsActionRecovery: Bool { hasTransientError || playback.hasTransientError }

    func recover(_ page: SamplyPage, forcePageRefresh: Bool = false) async {
        // Retry reads only. Never replay play/pause/seek/upload commands or reload the WebView.
        let needsPageRefresh = forcePageRefresh || hasTransientError
        if await web.refresh() {
            acceptSnapshot()
            noteFullContentAccepted()
        }
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
        let startedAt = clock.now()
        content.acceptBoxes([])
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
                try state.validateVersion()
                try Task.checkCancellation()
                guard generation == selectionGeneration else { return }
                if state.hasLoadedBoxes(for: item, groupID: groupID,
                                        expectedProjectID: item.projectID) {
                    content.acceptBoxes(state.boxes)
                    albumLoadState = .loaded
                    noteFullContentAccepted()
                    record(.selection, since: startedAt, itemCount: state.boxes.count)
                } else {
                    albumLoadState = .failed
                    record(.selection, since: startedAt, outcome: .failure)
                    recordFailure(SamplyError.invalidResponse)
                }
                isBrowsing = false
            } catch {
                guard generation == selectionGeneration else { return }
                isBrowsing = false
                albumLoadState = .failed
                if !Task.isCancelled {
                    record(.selection, since: startedAt, outcome: SamplyDiagnosticOutcome(error))
                    recordFailure(error)
                }
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
        let startedAt = clock.now()
        isPlayingSelection = true
        error = nil
        hasTransientError = false
        playTask = Task { [weak self] in
            guard let self else { return }
            do {
                let state: WebSnapshot = try await web.call("playBox", arguments: [
                    "fileID": box.id, "routeID": selectedItem.routeID
                ])
                try state.validateVersion()
                try Task.checkCancellation()
                guard generation == selectionGeneration else { return }
                playback.apply(state.playback, libraryItem: selectedItem)
                let reachedRequestedTrack = playback.state.fileID == box.id && !playback.state.loading
                record(.playbackStart, since: startedAt, itemCount: reachedRequestedTrack ? 1 : 0,
                       outcome: reachedRequestedTrack ? .success : .failure)
            } catch {
                if generation == selectionGeneration, !Task.isCancelled {
                    record(.playbackStart, since: startedAt, outcome: SamplyDiagnosticOutcome(error))
                    recordFailure(error)
                }
            }
            if generation == selectionGeneration { isPlayingSelection = false }
        }
    }

    func saveToken(_ token: String) async throws {
        guard isConnected, accountID != nil else { throw SamplyError.noAccount }
        try await credentials.saveCandidate(token)
        // A replacement invalidates every in-flight operation's captured revision.
        projectCreation.credentialChanged()
        uploader.reset()
    }

    func removeToken() throws {
        uploader.reset()
        projectCreation.credentialChanged()
        try credentials.remove()
    }

    func retryProjectUploads() {
        projectCreation.retryFailedInitialFiles()
    }

    func retryProjectArtwork() {
        projectCreation.retryArtwork()
    }

    func dismissProjectCreationNotice() {
        projectCreationNotice = nil
    }

    func refreshCreatedProject() async {
        await projectCreation.refreshLibrary()
    }

    func openCreatedProject() async {
        await projectCreation.openCreatedProject()
    }

    func abandonCreatedProject() {
        projectCreation.discardConfirmedCreation()
        if projectCreation.createdProject == nil {
            projectCreationNotice = nil
        }
    }

    private func refreshProjectCreationNotice() {
        projectCreationNotice = Self.creationNotice(for: projectCreation)
    }

    static func creationNotice(for projectCreation: ProjectCreationCoordinator) -> ProjectCreationNotice? {
        guard let created = projectCreation.createdProject else {
            return nil
        }
        let name = created.project.name
        var parts: [String] = []
        let failedFiles = projectCreation.initialFiles.filter {
            switch $0.status {
            case .failed(_, true), .cancelled(true, _): return true
            default: return false
            }
        }.count
        let uncertainFiles = projectCreation.initialFiles.filter {
            switch $0.status {
            case .uncertain, .cancelled(false, _), .failed(_, false): return true
            default: return false
            }
        }.count
        if failedFiles > 0 {
            parts.append("\(failedFiles) file\(failedFiles == 1 ? "" : "s") from “\(name)” did not upload.")
        }
        if uncertainFiles > 0 {
            parts.append("\(uncertainFiles) upload\(uncertainFiles == 1 ? "" : "s") for “\(name)” could not be confirmed and may already be in the project.")
        }
        switch projectCreation.artworkState {
        case .failed(let message, _):
            parts.append("Artwork for “\(name)” was not submitted. \(message)")
        case .submitted:
            parts.append("Artwork for “\(name)” was submitted; confirmation is pending.")
        case .unresolved(_, let message):
            parts.append("Artwork for “\(name)” is unresolved. \(message)")
        default:
            break
        }
        switch projectCreation.createdStage {
        case .refreshing:
            parts.append("“\(name)” was created. Refreshing the complete Library…")
        case .delayed:
            parts.append("“\(name)” was created but has not appeared in the Library yet.")
        case .refreshFailed(let message):
            parts.append(message)
        case .quarantined(let message):
            parts.append(message)
        case .openFailed(let message):
            parts.append(message)
        default:
            break
        }
        guard !parts.isEmpty else {
            return nil
        }
        return ProjectCreationNotice(
            message: parts.joined(separator: " "),
            canRetryUploads: projectCreation.canRetryInitialFiles,
            canRetryArtwork: projectCreation.canRetryArtwork,
            canRefreshLibrary: projectCreation.canRefreshCreatedProject,
            canOpenProject: projectCreation.canOpenCreatedProject,
            canStartNewProject: projectCreation.canAbandonConfirmedCreation)
    }

    func chooseUpload() {
        guard credentials.verifiedCredential() != nil,
              let item = selectedItem, item.canUpload, let projectID = item.projectID else { return }
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
                guard let self, self.selectedItem?.id == item.id,
                      self.selectionGeneration == generation,
                      let credential = self.credentials.verifiedCredential() else { return }
                self.uploader.upload(file: file, projectID: projectID, parentID: parentID,
                                     token: credential.token)
            }
        }
    }

    func refresh(_ page: SamplyPage) async {
        guard isConnected, !isRefreshing, !isBrowsing, !isPlayingSelection else { return }
        let generation = selectionGeneration
        let account = web.account?.uid
        let startedAt = clock.now()
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let state: WebSnapshot = try await web.call("refreshPage", arguments: page.arguments)
            try Task.checkCancellation()
            try state.validateVersion()
            guard account == web.account?.uid, state.account?.uid == account,
                  !web.isSigningOut else { return }
            switch page {
            case .library:
                guard state.libraryReady else { throw SamplyError.invalidResponse }
                content.acceptLibrary(state.library)
                noteFullContentAccepted()
                record(.serverRefresh, since: startedAt, itemCount: state.library.count)
            case .album(let routeID, let groupID):
                guard generation == selectionGeneration, let selectedItem,
                      selectedItem.routeID == routeID, folderPath.last?.id == groupID else { return }
                guard state.hasLoadedBoxes(for: selectedItem, groupID: groupID,
                                           expectedProjectID: selectedItem.projectID) else {
                    throw SamplyError.invalidResponse
                }
                content.acceptBoxes(state.boxes)
                albumLoadState = .loaded
                noteFullContentAccepted()
                record(.serverRefresh, since: startedAt, itemCount: state.boxes.count)
            }
            // Refresh only updates page data. The media engine and native playback stay intact.
            error = nil
            hasTransientError = false
        } catch is CancellationError { }
        catch {
            if generation == selectionGeneration, account == web.account?.uid {
                record(.serverRefresh, since: startedAt, outcome: SamplyDiagnosticOutcome(error))
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
        content.acceptLibrary([])
        playback.clear()
        uploader.reset()
        sessionGeneration &+= 1
        credentials.activate(accountID: nil, generation: sessionGeneration)
        do { try tokens.remove() }
        catch { recordFailure(error) }
        accountID = nil
        await web.signOut()
    }

    /// Applies a project opened through the adapter after REST creation. The
    /// complete Library was already refreshed, so a delayed history entry is not
    /// fabricated into the native grid.
    private func acceptCreatedProject(_ item: LibraryItem, _ snapshot: WebSnapshot) {
        guard web.account?.uid == snapshot.account?.uid else { return }
        var opened = item
        if let routeID = snapshot.routeID, !routeID.isEmpty { opened.shareID = routeID }
        if let projectID = snapshot.projectID { opened.projectID = projectID }
        opened.canUpload = true
        invalidateSelection()
        selectedItem = opened
        content.acceptBoxes(snapshot.boxes)
        albumLoadState = .loaded
        content.replaceLibraryItem(opened)
        noteFullContentAccepted()
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
        content.acceptBoxes([])
        folderPath = []
        isBrowsing = false
        albumLoadState = .idle
        isPlayingSelection = false
    }
}

/// Route/level/readiness identity used to invalidate the next full content read.
private struct RuntimeIdentity: Equatable {
    let routeID: String?
    let projectID: String?
    let levelID: String?
    let boxesReady: Bool
}
