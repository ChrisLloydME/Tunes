import Foundation
import Observation

@MainActor
protocol ProjectCreatingAPI: AnyObject {
    func createProject(name: String,
                       credential: VerifiedProjectCredential) async throws -> SamplyProject
}

@MainActor
protocol ProjectCreationWebSession: AnyObject {
    var accountID: String? { get }
    var isSigningOut: Bool { get }
    func call<T: Decodable>(_ command: String, arguments: [String: Any]) async throws -> T
}

/// Owns the one in-flight project creation and the confirmed result that survives
/// Library refresh or navigation failures. Samply's POST /projects can create a
/// project even when its response is lost, so this type never retries it and never
/// treats an ambiguous outcome as proof that no project exists.
@MainActor
@Observable
final class ProjectCreationCoordinator {
    struct PlayerRoute: Equatable, Sendable {
        let pathID: String
        let token: String?
    }

    struct InitialFile: Identifiable, Equatable, Sendable {
        enum Status: Equatable, Sendable {
            case waiting
            case uploading
            case uploaded(boxID: String)
            case failed(message: String, retryable: Bool)
            case cancelled(retryable: Bool, boxID: String?)
            case uncertain(message: String, boxID: String?)
        }

        let id = UUID()
        let url: URL
        let fileName: String
        var status: Status = .waiting
        var progress: Double = 0

        var isRetryable: Bool {
            switch status {
            case .failed(_, true), .cancelled(true, _): return true
            default: return false
            }
        }

        var boxID: String? {
            switch status {
            case .uploaded(let boxID): return boxID
            case .cancelled(_, let boxID), .uncertain(_, let boxID): return boxID
            case .waiting, .uploading, .failed: return nil
            }
        }
    }

    struct CreatedProject: Equatable, Sendable {
        let accountID: String
        let project: SamplyProject
        let playerURL: URL?
        let playerRoute: PlayerRoute?
        var libraryItem: LibraryItem?

        var routeID: String? { playerRoute?.pathID }

        var openItem: LibraryItem? {
            if let libraryItem { return libraryItem }
            // A documented player URL can carry a share token separately from
            // its path identity. Do not invent a share ID from that path; the
            // adapter resolves the token and reports the live share route.
            guard let routeID else { return nil }
            return LibraryItem(id: project.id, name: project.name, projectID: project.id,
                               playerID: nil,
                               shareID: playerRoute?.token == nil ? routeID : nil,
                               artist: nil, artwork: project.artwork,
                               canUpload: true, isOwned: true)
        }
    }

    enum Stage: Equatable, Sendable {
        case refreshing
        case visible
        case opening
        case opened
        case delayed
        case refreshFailed(String)
        case openFailed(String)
        case quarantined(String)

        var isBusy: Bool { self == .refreshing || self == .opening }
    }

    enum ArtworkState: Equatable, Sendable {
        case none
        case pending
        /// Bytes were accepted by storage, but the server has not exposed a
        /// supported relationship proving which box now owns the artwork.
        case submitted(boxID: String)
        /// Reserved for a future authoritative read that exposes the exact box
        /// relationship. No current documented read is allowed to produce this.
        case confirmedAssigned(boxID: String)
        /// A ticket, PUT, or assignment may exist remotely but is unresolved.
        case unresolved(boxID: String?, message: String)
        /// Definite failure before any storage submission.
        case failed(message: String, retryable: Bool)

        var isBusy: Bool { self == .pending }
    }

    enum State: Equatable, Sendable {
        case idle
        case creating
        case created(CreatedProject, Stage)
        case failed(String)
        case uncertain(String, canStartOver: Bool)
    }

    private struct OpenDestination {
        let routeID: String
        let token: String?
        let item: LibraryItem
        let projectID: String
    }

    private(set) var state: State = .idle
    private(set) var artworkState: ArtworkState = .none
    private(set) var initialFiles: [InitialFile] = []
    private(set) var isRefreshingAfterUncertain = false
    @ObservationIgnored private let api: any ProjectCreatingAPI
    @ObservationIgnored private let web: any ProjectCreationWebSession
    @ObservationIgnored private let uploader: any ProjectAssetUploading
    @ObservationIgnored private let credentials: any ProjectCredentialProviding
    @ObservationIgnored private var operation = UUID()
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    @ObservationIgnored private var artworkRunID: UUID?
    @ObservationIgnored private var artworkPayload: ProjectArtworkPayload?
    @ObservationIgnored private var initialUploadTask: Task<Void, Never>?
    @ObservationIgnored private var initialUploadRunID: UUID?
    @ObservationIgnored var onLibraryRefreshed: (([LibraryItem]) -> Void)?
    @ObservationIgnored var onProjectOpened: ((LibraryItem, WebSnapshot) -> Void)?
    @ObservationIgnored var onBackgroundOutcome: (() -> Void)?

    init(api: any ProjectCreatingAPI, web: any ProjectCreationWebSession,
         uploader: any ProjectAssetUploading,
         credentials: any ProjectCredentialProviding) {
        self.api = api
        self.web = web
        self.uploader = uploader
        self.credentials = credentials
    }

    var isCreating: Bool {
        if case .creating = state { return true }
        return false
    }

    /// Closing the sheet is allowed once the one creation POST has finished. A
    /// confirmed project, including one still refreshing or waiting for Library,
    /// stays in backend-owned state.
    var blocksDismissal: Bool { isCreating }

    var isBackgroundWorkRunning: Bool {
        initialUploadTask != nil || artworkTask != nil ||
            initialFiles.contains { $0.status == .waiting || $0.status == .uploading } ||
            artworkState.isBusy || createdStage?.isBusy == true
    }

    var isUploadingInitialFiles: Bool {
        initialUploadTask != nil || initialFiles.contains {
            $0.status == .waiting || $0.status == .uploading
        }
    }

    var hasAppearedInLibrary: Bool {
        guard let created = createdProject else { return false }
        if created.libraryItem != nil { return true }
        if case .opened = createdStage { return true }
        return false
    }

    var canCloseSheet: Bool { !isCreating }

    var canRetryInitialFiles: Bool {
        createdProject != nil && !isUploadingInitialFiles &&
            credentials.verifiedCredential() != nil &&
            initialFiles.contains(where: \.isRetryable)
    }

    var hasUncertainInitialFiles: Bool {
        initialFiles.contains {
            switch $0.status {
            case .uncertain, .cancelled(false, _), .failed(_, false): return true
            default: return false
            }
        }
    }

    var hasUnresolvedInitialFiles: Bool {
        initialFiles.contains {
            switch $0.status {
            case .failed, .uncertain, .cancelled: return true
            default: return false
            }
        }
    }

    var hasUnresolvedArtwork: Bool {
        switch artworkState {
        case .submitted, .unresolved, .failed: return true
        default: return false
        }
    }

    var hasUnresolvedCreatedWork: Bool {
        hasUnresolvedInitialFiles || hasUnresolvedArtwork
    }

    /// True when no optional transfer is running and no optional outcome remains
    /// unresolved. It does not mean the confirmed project can be discarded; use
    /// `canAbandonConfirmedCreation` for that explicit action.
    var canFinishCreatedProject: Bool {
        guard case .created = state else { return false }
        return !isBackgroundWorkRunning && !hasUnresolvedCreatedWork
    }

    /// Local abandonment is deliberate and safe only after the confirmed project
    /// has appeared in Library and no refresh/open recovery is still pending.
    var canAbandonConfirmedCreation: Bool {
        guard case .created(_, let stage) = state, !isBackgroundWorkRunning else { return false }
        switch stage {
        case .visible, .opened, .openFailed: return true
        case .refreshing, .opening, .delayed, .refreshFailed, .quarantined: return false
        }
    }

    var canRetryArtwork: Bool {
        guard artworkPayload != nil, credentials.verifiedCredential() != nil else { return false }
        if case .failed(_, true) = artworkState { return true }
        return false
    }

    var createdProject: CreatedProject? {
        if case .created(let project, _) = state { return project }
        return nil
    }

    var createdStage: Stage? {
        if case .created(_, let stage) = state { return stage }
        return nil
    }

    var canOpenCreatedProject: Bool {
        guard let created = createdProject, let stage = createdStage,
              !stage.isBusy, canOpenWithoutQuarantine else { return false }
        return created.openItem != nil
    }

    var canRefreshCreatedProject: Bool {
        guard let stage = createdStage else { return false }
        switch stage {
        case .refreshing, .opening: return false
        case .visible, .opened, .delayed, .refreshFailed, .openFailed, .quarantined: return true
        }
    }

    var isQuarantined: Bool {
        if case .quarantined = createdStage { return true }
        return false
    }

    /// Starts exactly one POST /projects request. A blank name after trimming is
    /// rejected before any account or network work, and an unverified credential
    /// is rejected before the request as well.
    func create(name: String, artwork: ProjectArtworkPayload? = nil,
                files: [URL] = []) async {
        guard !isCreating else { return }
        if case .created = state { return }
        if case .uncertain = state { return }

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            state = .failed("Enter a project name.")
            return
        }
        guard let accountID = web.accountID, !web.isSigningOut else {
            state = .failed("Sign in to Samply before creating a project.")
            return
        }
        guard let credential = credentials.verifiedCredential(),
              credential.accountID == accountID else {
            state = .failed(Self.credentialMessage(for: credentials.state))
            return
        }
        guard !Task.isCancelled else { return }

        artworkTask?.cancel()
        artworkTask = nil
        artworkRunID = nil
        artworkPayload = nil
        artworkState = .none
        initialUploadTask?.cancel()
        initialUploadTask = nil
        initialUploadRunID = nil
        initialFiles = []

        let ticket = UUID()
        operation = ticket
        state = .creating
        let context = MutationContext(
            operationID: ticket, sessionGeneration: credential.sessionGeneration,
            accountID: accountID, credentialRevision: credential.credentialRevision)
        guard credentials.isCurrent(context) else {
            state = .failed(Self.credentialMessage(for: credentials.state))
            return
        }

        do {
            let project = try await api.createProject(name: trimmed, credential: credential)
            // The account/session must still own this operation. Credential
            // replacement is handled below so a confirmed server result is not
            // discarded and the sheet is never left stuck in `.creating`.
            guard isCreationResponseCurrent(ticket, accountID: accountID) else { return }

            let created = CreatedProject(accountID: accountID, project: project,
                                         playerURL: project.playerUrl,
                                         playerRoute: Self.playerRoute(from: project.playerUrl))
            let identityMatches = project.creator?.uid == accountID
            if identityMatches {
                state = .created(created, .refreshing)
                artworkPayload = artwork
                artworkState = artwork == nil ? .none : .pending
                initialFiles = files.map {
                    InitialFile(url: $0, fileName: $0.lastPathComponent)
                }
                // startOptionalWork rechecks the captured credential. If it was
                // replaced during the POST, no optional write starts and those
                // outcomes become retryable failures after revalidation.
                startOptionalWork(artwork: artwork, files: files, credential: credential)
                notifyBackgroundOutcome()
                await refreshAfterCreation(created, ticket: ticket)
            } else {
                // The documented creator UID is visible only after the POST. A
                // missing or mismatched identity is quarantined: the project may
                // exist remotely, but no artwork or file write may follow.
                state = .created(created, .quarantined(Self.quarantineMessage(project: project,
                                                                              accountID: accountID)))
                artworkPayload = nil
                artworkState = .none
                initialFiles = []
                notifyBackgroundOutcome()
            }
        } catch {
            guard isCreationResponseCurrent(ticket, accountID: accountID) else { return }
            if Self.isAmbiguous(error) {
                state = .uncertain(Self.uncertainMessage(error), canStartOver: false)
            } else {
                state = .failed(Self.failureMessage(error))
            }
        }
    }

    /// Read-only refresh for a confirmed creation whose Library update failed or
    /// is still propagating. It never calls POST /projects and never navigates.
    func refreshLibrary() async {
        switch state {
        case .created(let created, let stage):
            guard !stage.isBusy, canRefreshCreatedProject else { return }
            guard isCurrentAccount(created.accountID) else {
                invalidate()
                return
            }
            let ticket = UUID()
            operation = ticket
            let quarantineMessage: String? = {
                if case .quarantined(let message) = stage { return message }
                return nil
            }()
            let wasQuarantined = quarantineMessage != nil
            if !wasQuarantined { updateStage(.refreshing) }
            do {
                guard let snapshot = try await completeLibrary(ticket: ticket,
                                                               accountID: created.accountID) else { return }
                guard let current = createdProject else { return }
                if let item = Self.item(for: current.project.id, in: snapshot.library) {
                    var updated = current
                    updated.libraryItem = item
                    if wasQuarantined {
                        state = .created(updated, .quarantined(
                            Self.quarantineMessage(project: current.project,
                                                   accountID: created.accountID,
                                                   visibleInLibrary: true)))
                    } else {
                        state = .created(updated, .visible)
                    }
                } else if let quarantineMessage {
                    state = .created(current, .quarantined(
                        quarantineMessage + " The project is still not visible in the Library."))
                } else {
                    updateStage(.delayed)
                }
            } catch is CancellationError {
                guard isCurrent(ticket, accountID: created.accountID) else { return }
                if let quarantineMessage {
                    state = .created(created, .quarantined(
                        quarantineMessage + " The Library refresh was interrupted."))
                } else {
                    updateStage(.refreshFailed(Self.interruptedRefreshMessage))
                }
            } catch {
                guard isCurrent(ticket, accountID: created.accountID) else { return }
                if let quarantineMessage {
                    state = .created(created, .quarantined(
                        quarantineMessage + " The Library refresh failed: \(error.localizedDescription)"))
                } else {
                    updateStage(.refreshFailed(Self.refreshFailureMessage(error)))
                }
            }
            notifyBackgroundOutcome()

        case .uncertain:
            await refreshAfterUncertainOutcome()

        default:
            return
        }
    }

    /// Opens the confirmed project only through an explicit user action. The
    /// refreshed Library item is preferred; the documented player URL is used
    /// only when Library propagation is delayed.
    func openCreatedProject() async {
        guard case .created(let created, let stage) = state, !stage.isBusy,
              canOpenWithoutQuarantine else { return }
        guard isCurrentAccount(created.accountID) else {
            invalidate()
            return
        }
        guard let destination = openDestination(for: created) else {
            updateStage(.openFailed(
                "Samply did not provide a player link for this project. Refresh Library and open it there."))
            return
        }
        let ticket = UUID()
        operation = ticket
        updateStage(.opening)
        do {
            try await openDestination(destination, ticket: ticket,
                                      accountID: created.accountID)
        } catch is CancellationError {
            guard isCurrent(ticket, accountID: created.accountID) else { return }
            updateStage(.openFailed(Self.interruptedOpenMessage))
        } catch {
            guard isCurrent(ticket, accountID: created.accountID) else { return }
            updateStage(.openFailed(Self.openFailureMessage(error)))
        }
    }

    /// After an explicit read-only refresh, the user can start over only when the
    /// uncertain creation flow has been checked against the complete Library.
    func startOverAfterUncertainOutcome() {
        guard case .uncertain(_, let canStartOver) = state, canStartOver else { return }
        operation = UUID()
        state = .idle
    }

    /// Adds files to an already confirmed project without creating it again.
    /// Used by the post-creation file step.
    @discardableResult
    func addFiles(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty, case .created(let created, let stage) = state,
              !stage.isBusy, !isQuarantined, !isUploadingInitialFiles,
              isCurrentAccount(created.accountID),
              let credential = credentials.verifiedCredential(),
              credential.accountID == created.accountID else { return false }
        var seen = Set(initialFiles.map { $0.url.standardizedFileURL.path })
        var added = false
        for url in urls {
            let path = url.standardizedFileURL.path
            guard seen.insert(path).inserted else { continue }
            initialFiles.append(InitialFile(url: url, fileName: url.lastPathComponent))
            added = true
        }
        guard added else { return false }
        startInitialUploads(credential: credential)
        notifyBackgroundOutcome()
        return true
    }

    /// Abandons local tracking of a confirmed project without deleting or
    /// recreating anything in Samply. Used when the confirmed project has
    /// appeared in Library and no recovery is pending.
    func discardConfirmedCreation() {
        guard canAbandonConfirmedCreation else { return }
        invalidate()
    }

    /// Called when the sheet closes. A resolved project may be discarded; a
    /// project in `.refreshing`, `.delayed`, `.refreshFailed`, or `.quarantined`
    /// is retained for Library recovery.
    func sheetDidDisappear() {
        guard case .created(_, let stage) = state else {
            if case .idle = state { return }
            if case .failed = state { invalidate() }
            return
        }
        if canAutomaticallyDiscard(after: stage) { invalidate() }
    }

    /// Called when the user explicitly opens the New Project sheet. A fully
    /// resolved previous project is cleared so the sheet can start a new one;
    /// unresolved recovery stays visible.
    func prepareForPresentation() {
        guard case .created(_, let stage) = state else { return }
        if canAutomaticallyDiscard(after: stage) { invalidate() }
    }

    func cancelInitialUploads() {
        guard isUploadingInitialFiles else { return }
        initialUploadTask?.cancel()
        for index in initialFiles.indices where initialFiles[index].status == .waiting {
            initialFiles[index].status = .cancelled(retryable: true, boxID: nil)
            initialFiles[index].progress = 0
        }
        notifyBackgroundOutcome()
    }

    func retryFailedInitialFiles() {
        guard canRetryInitialFiles, let created = createdProject,
              isCurrentAccount(created.accountID),
              let credential = credentials.verifiedCredential(),
              credential.accountID == created.accountID else { return }
        var retried = false
        for index in initialFiles.indices where initialFiles[index].isRetryable {
            initialFiles[index].status = .waiting
            initialFiles[index].progress = 0
            retried = true
        }
        guard retried else { return }
        startInitialUploads(credential: credential)
        notifyBackgroundOutcome()
    }

    func retryArtwork() {
        guard canRetryArtwork, let payload = artworkPayload,
              let created = createdProject, isCurrentAccount(created.accountID),
              let credential = credentials.verifiedCredential(),
              credential.accountID == created.accountID else { return }
        artworkState = .pending
        startArtwork(payload, credential: credential)
        notifyBackgroundOutcome()
    }

    /// Stops pending submissions when a token is replaced or removed. A confirmed
    /// project and any already-submitted result remain; active transfers are
    /// cancelled where possible and classify themselves by phase.
    func credentialChanged() {
        initialUploadTask?.cancel()
        artworkTask?.cancel()
        for index in initialFiles.indices where initialFiles[index].status == .waiting {
            initialFiles[index].status = .cancelled(retryable: true, boxID: nil)
            initialFiles[index].progress = 0
        }
        notifyBackgroundOutcome()
    }

    /// Clears a failed sheet or a fully resolved confirmed project. Unresolved
    /// recovery and optional outcomes are retained.
    func reset() {
        switch state {
        case .idle, .failed:
            invalidate()
        case .created(_, let stage):
            if canAutomaticallyDiscard(after: stage) { invalidate() }
        default:
            return
        }
    }

    /// Invalidates every in-flight result after sign-out or an account change.
    func invalidate() {
        operation = UUID()
        artworkTask?.cancel()
        artworkTask = nil
        artworkRunID = nil
        artworkPayload = nil
        artworkState = .none
        initialUploadTask?.cancel()
        initialUploadTask = nil
        initialUploadRunID = nil
        initialFiles = []
        isRefreshingAfterUncertain = false
        state = .idle
        notifyBackgroundOutcome()
    }

    private var canOpenWithoutQuarantine: Bool {
        if case .quarantined = createdStage { return false }
        return true
    }

    private func canAutomaticallyDiscard(after stage: Stage) -> Bool {
        switch stage {
        case .visible, .opened:
            return !isBackgroundWorkRunning && !hasUnresolvedCreatedWork
        case .refreshing, .opening, .delayed, .refreshFailed, .openFailed, .quarantined:
            return false
        }
    }

    private func startOptionalWork(artwork: ProjectArtworkPayload?, files: [URL],
                                   credential: VerifiedProjectCredential) {
        guard let current = credentials.verifiedCredential(),
              current.accountID == credential.accountID,
              current.sessionGeneration == credential.sessionGeneration,
              current.credentialRevision == credential.credentialRevision else {
            if artwork != nil {
                artworkState = .failed(
                    message: "Artwork was not submitted because token verification changed.",
                    retryable: true)
            }
            if !files.isEmpty {
                initialFiles = initialFiles.map { file in
                    var file = file
                    file.status = .failed(
                        message: "Not uploaded because token verification changed.",
                        retryable: true)
                    return file
                }
            }
            return
        }
        if let artwork { startArtwork(artwork, credential: credential) }
        if !files.isEmpty { startInitialUploads(credential: credential) }
    }

    private func startArtwork(_ payload: ProjectArtworkPayload,
                              credential: VerifiedProjectCredential) {
        artworkTask?.cancel()
        let run = UUID()
        artworkRunID = run
        artworkTask = Task { [weak self] in
            await self?.submitArtwork(payload, credential: credential, run: run)
        }
    }

    private func submitArtwork(_ payload: ProjectArtworkPayload,
                               credential: VerifiedProjectCredential, run: UUID) async {
        defer {
            if artworkRunID == run {
                artworkTask = nil
                artworkRunID = nil
                notifyBackgroundOutcome()
            }
        }
        guard let created = createdProject, isCurrentAccount(created.accountID) else { return }
        let context = MutationContext(
            operationID: run, sessionGeneration: credential.sessionGeneration,
            accountID: created.accountID, credentialRevision: credential.credentialRevision)
        guard isMutationCurrent(context, projectID: created.project.id) else {
            artworkState = .failed(
                message: "Artwork was not submitted because the account or token changed.",
                retryable: true)
            return
        }
        artworkState = .pending
        let authorization = UploadAuthorization(credential: credential, context: context) { [weak self] in
            self?.isMutationCurrent(context, projectID: created.project.id) == true
        }
        let outcome = await uploader.performArtworkUpload(
            payload: payload, projectID: created.project.id, authorization: authorization)
        guard artworkRunID == run, let current = createdProject,
              current.project.id == created.project.id else { return }
        applyArtwork(outcome)
    }

    private func applyArtwork(_ outcome: UploadOutcome) {
        let boxID = outcome.ticket?.boxID
        switch outcome.disposition {
        case .submitted:
            guard let boxID else {
                artworkState = .unresolved(
                    boxID: nil,
                    message: "Samply accepted the artwork bytes but did not return an artwork box identity. Confirmation is pending.")
                return
            }
            // A successful PUT confirms bytes only. Exact assignment needs an
            // authoritative read that exposes this box ID as the project's
            // artwork; no documented read provides that relationship, so this
            // remains "submitted; confirmation pending" rather than success.
            artworkState = .submitted(boxID: boxID)
            artworkPayload = nil
        case .cancelled:
            if outcome.isSafelyRetryable {
                artworkState = .failed(message: "Artwork upload was cancelled before submission.",
                                       retryable: true)
            } else {
                artworkState = .unresolved(
                    boxID: boxID,
                    message: "Artwork upload was cancelled after a ticket or PUT began. Samply may have created an artwork resource; check the project before trying again.")
            }
        case .failed(let message):
            if outcome.isSafelyRetryable {
                artworkState = .failed(message: message, retryable: true)
            } else {
                artworkState = .unresolved(boxID: boxID, message: message)
            }
        case .uncertain(let message):
            artworkState = .unresolved(boxID: boxID, message: message)
        }
    }

    private func startInitialUploads(credential: VerifiedProjectCredential) {
        initialUploadTask?.cancel()
        let run = UUID()
        initialUploadRunID = run
        initialUploadTask = Task { [weak self] in
            await self?.uploadPendingFiles(credential: credential, run: run)
        }
    }

    private func uploadPendingFiles(credential: VerifiedProjectCredential, run: UUID) async {
        defer {
            if initialUploadRunID == run {
                initialUploadTask = nil
                initialUploadRunID = nil
                notifyBackgroundOutcome()
            }
        }
        guard let created = createdProject else { return }
        let context = MutationContext(
            operationID: run, sessionGeneration: credential.sessionGeneration,
            accountID: created.accountID, credentialRevision: credential.credentialRevision)
        while true {
            guard let index = initialFiles.firstIndex(where: { $0.status == .waiting }) else {
                return
            }
            guard !Task.isCancelled else {
                markWaitingFilesCancelled(retryable: true, boxID: nil)
                return
            }
            guard isMutationCurrent(context, projectID: created.project.id) else {
                markWaitingFilesCancelled(
                    retryable: true, boxID: nil,
                    message: "Not uploaded because the account or token changed. Verify the token before retrying.")
                return
            }
            let file = initialFiles[index]
            initialFiles[index].status = .uploading
            initialFiles[index].progress = 0
            let authorization = UploadAuthorization(credential: credential, context: context) { [weak self] in
                self?.isMutationCurrent(context, projectID: created.project.id) == true
            }
            let outcome = await uploader.performUpload(
                file: file.url, projectID: created.project.id, parentID: nil,
                authorization: authorization) { [weak self] value in
                    self?.updateInitialFileProgress(id: file.id, value: value)
                }
            guard initialUploadRunID == run,
                  let current = createdProject,
                  current.project.id == created.project.id,
                  let updatedIndex = initialFiles.firstIndex(where: { $0.id == file.id }) else {
                return
            }
            apply(outcome, at: updatedIndex)
            if !isMutationCurrent(context, projectID: created.project.id) {
                markWaitingFilesCancelled(
                    retryable: true, boxID: nil,
                    message: "Not uploaded because the account or token changed. Verify the token before retrying.")
                return
            }
            if case .cancelled = outcome.disposition, !outcome.isSafelyRetryable {
                markWaitingFilesCancelled(retryable: true, boxID: nil)
                return
            }
            if Task.isCancelled {
                markWaitingFilesCancelled(retryable: true, boxID: nil)
                return
            }
        }
    }

    private func apply(_ outcome: UploadOutcome, at index: Int) {
        let boxID = outcome.ticket?.boxID
        switch outcome.disposition {
        case .submitted:
            if let boxID {
                initialFiles[index].status = .uploaded(boxID: boxID)
                initialFiles[index].progress = 1
            } else {
                initialFiles[index].status = .uncertain(
                    message: "Samply accepted the upload but returned no box identity.",
                    boxID: nil)
                initialFiles[index].progress = 0
            }
        case .cancelled:
            initialFiles[index].status = .cancelled(retryable: outcome.isSafelyRetryable,
                                                    boxID: boxID)
            initialFiles[index].progress = 0
        case .failed(let message):
            initialFiles[index].status = .failed(message: message,
                                                 retryable: outcome.isSafelyRetryable)
            initialFiles[index].progress = 0
        case .uncertain(let message):
            initialFiles[index].status = .uncertain(message: message, boxID: boxID)
            initialFiles[index].progress = 0
        }
    }

    private func updateInitialFileProgress(id: UUID, value: Double) {
        guard let index = initialFiles.firstIndex(where: { $0.id == id }),
              initialFiles[index].status == .uploading else { return }
        initialFiles[index].progress = min(max(value, 0), 1)
    }

    private func markWaitingFilesCancelled(retryable: Bool, boxID: String?,
                                           message: String? = nil) {
        for index in initialFiles.indices where initialFiles[index].status == .waiting {
            if let message {
                initialFiles[index].status = .failed(message: message, retryable: retryable)
            } else {
                initialFiles[index].status = .cancelled(retryable: retryable, boxID: boxID)
            }
            initialFiles[index].progress = 0
        }
    }

    private func notifyBackgroundOutcome() {
        onBackgroundOutcome?()
    }

    /// Creation stays on the Library screen. Refresh its complete history in
    /// the background and retain the confirmed project without navigating to it.
    private func refreshAfterCreation(_ created: CreatedProject, ticket: UUID) async {
        do {
            guard let snapshot = try await completeLibrary(ticket: ticket,
                                                           accountID: created.accountID) else { return }
            guard let current = createdProject else { return }
            if let item = Self.item(for: current.project.id, in: snapshot.library) {
                var updated = current
                updated.libraryItem = item
                state = .created(updated, .visible)
            } else {
                updateStage(.delayed)
            }
        } catch is CancellationError {
            guard isCurrent(ticket, accountID: created.accountID) else { return }
            updateStage(.refreshFailed(Self.interruptedRefreshMessage))
        } catch {
            guard isCurrent(ticket, accountID: created.accountID) else { return }
            updateStage(.refreshFailed(Self.refreshFailureMessage(error)))
        }
        notifyBackgroundOutcome()
    }

    private func refreshAfterUncertainOutcome() async {
        guard !isRefreshingAfterUncertain else { return }
        guard let accountID = web.accountID, !web.isSigningOut else {
            state = .uncertain("Sign in to Samply to refresh the Library.", canStartOver: false)
            return
        }
        let ticket = UUID()
        operation = ticket
        isRefreshingAfterUncertain = true
        defer { isRefreshingAfterUncertain = false }
        state = .uncertain("Refreshing Library…", canStartOver: false)
        do {
            guard try await completeLibrary(ticket: ticket,
                                            accountID: accountID) != nil else { return }
            state = .uncertain("Library refreshed. Check the Library for the project before trying again.",
                               canStartOver: true)
        } catch is CancellationError {
            guard isCurrent(ticket, accountID: accountID) else { return }
            state = .uncertain("The Library refresh was interrupted. The project may already exist; refresh again before creating another.",
                               canStartOver: false)
        } catch {
            guard isCurrent(ticket, accountID: accountID) else { return }
            state = .uncertain(Self.refreshFailureMessage(error) +
                               " The project may already exist; refresh again before creating another.",
                               canStartOver: false)
        }
    }

    /// Rereads the complete authenticated web Library, including shared players.
    /// The owned-only REST project list is never substituted for this read.
    private func completeLibrary(ticket: UUID, accountID: String) async throws -> WebSnapshot? {
        let snapshot: WebSnapshot = try await web.call("refreshPage", arguments: ["page": "library"])
        guard isCurrent(ticket, accountID: accountID) else { return nil }
        guard snapshot.version == 1, snapshot.libraryReady,
              snapshot.account?.uid == accountID else {
            throw SamplyError.invalidResponse
        }
        onLibraryRefreshed?(snapshot.library)
        return snapshot
    }

    private func openDestination(for created: CreatedProject) -> OpenDestination? {
        let projectID = created.project.id
        let baseItem = created.libraryItem ?? created.openItem
        if let playerRoute = created.playerRoute, let baseItem {
            // The documented player URL is the authoritative link for a newly
            // created project. Its path can carry a project/player identity even
            // when the refreshed Library entry has not received its share ID yet.
            // If the URL has no share token, a refreshed Library share ID is the
            // safer existing route.
            if playerRoute.token == nil,
               let shareID = created.libraryItem?.shareID, !shareID.isEmpty {
                return OpenDestination(routeID: shareID, token: nil,
                                       item: baseItem, projectID: projectID)
            }
            return OpenDestination(routeID: playerRoute.pathID, token: playerRoute.token,
                                   item: baseItem, projectID: projectID)
        }
        if let shareID = created.libraryItem?.shareID, !shareID.isEmpty,
           let baseItem {
            return OpenDestination(routeID: shareID, token: nil,
                                   item: baseItem, projectID: projectID)
        }
        guard let baseItem, !baseItem.routeID.isEmpty else { return nil }
        return OpenDestination(routeID: baseItem.routeID, token: nil,
                               item: baseItem, projectID: projectID)
    }

    private func openDestination(_ destination: OpenDestination, ticket: UUID,
                                 accountID: String) async throws {
        guard let snapshot = try await open(destination, ticket: ticket,
                                            accountID: accountID) else { return }
        guard let item = openedItem(destination.item, snapshot: snapshot,
                                    projectID: destination.projectID) else { return }
        markOpened(item, snapshot: snapshot)
    }

    private func open(_ destination: OpenDestination, ticket: UUID,
                      accountID: String) async throws -> WebSnapshot? {
        var arguments: [String: Any] = [
            "routeID": destination.routeID,
            "projectID": destination.projectID
        ]
        if let token = destination.token { arguments["token"] = token }
        let snapshot: WebSnapshot = try await web.call("browse", arguments: arguments)
        guard isCurrent(ticket, accountID: accountID) else { return nil }
        guard snapshot.version == 1, snapshot.account?.uid == accountID,
              snapshot.projectID == destination.projectID,
              snapshot.hasLoadedBoxes(routeID: snapshot.routeID ?? "", groupID: nil,
                                      expectedProjectID: destination.projectID) else {
            throw SamplyError.invalidResponse
        }
        return snapshot
    }

    private func openedItem(_ item: LibraryItem, snapshot: WebSnapshot,
                            projectID: String) -> LibraryItem? {
        guard let routeID = snapshot.routeID, !routeID.isEmpty else { return nil }
        var opened = item
        opened.projectID = projectID
        opened.shareID = routeID
        // The account just created this project, so expose the existing upload
        // action even if the freshly propagated Library permission helper lags.
        // The upload endpoint still enforces Samply's server-side permissions.
        opened.canUpload = true
        return opened
    }

    private func markOpened(_ item: LibraryItem, snapshot: WebSnapshot) {
        guard var created = createdProject else { return }
        created.libraryItem = item
        state = .created(created, .opened)
        onProjectOpened?(item, snapshot)
    }

    private func updateStage(_ stage: Stage) {
        guard case .created(let created, _) = state else { return }
        state = .created(created, stage)
        notifyBackgroundOutcome()
    }

    private func isCreationResponseCurrent(_ ticket: UUID, accountID: String) -> Bool {
        operation == ticket && web.accountID == accountID && !web.isSigningOut
    }

    private func isMutationCurrent(_ context: MutationContext, projectID: String) -> Bool {
        guard credentials.isCurrent(context),
              web.accountID == context.accountID, !web.isSigningOut,
              case .created(let created, let stage) = state,
              created.accountID == context.accountID,
              created.project.id == projectID else { return false }
        if case .quarantined = stage { return false }
        return true
    }

    private func isCurrent(_ ticket: UUID, accountID: String) -> Bool {
        operation == ticket && isCurrentAccount(accountID)
    }

    private func isCurrentAccount(_ accountID: String) -> Bool {
        !web.isSigningOut && web.accountID == accountID
    }

    private static func credentialMessage(for state: ProjectCredentialState) -> String {
        switch state {
        case .absent:
            return "Add a Samply Personal Access Token in Settings > API Access before creating a project."
        case .validating:
            return "Tunes is verifying your Samply token. Project creation will be available after verification completes."
        case .rejected(let message), .identityUnverifiable(let message):
            return message
        case .verified:
            return "The Samply token is no longer verified. Add it again in Settings > API Access."
        }
    }

    static func playerRoute(from playerURL: URL?) -> PlayerRoute? {
        guard let playerURL, playerURL.scheme?.lowercased() == "https",
              playerURL.host?.lowercased() == "samply.app", playerURL.port == nil,
              playerURL.user == nil, playerURL.password == nil else { return nil }
        let components = playerURL.pathComponents.filter { $0 != "/" }
        guard components.count == 2, components[0] == "p" else { return nil }
        let pathID = components[1]
        guard !pathID.isEmpty else { return nil }
        let token = URLComponents(url: playerURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "token" })?.value
        return PlayerRoute(pathID: pathID,
                           token: token.flatMap { $0.isEmpty ? nil : $0 })
    }

    static func routeID(from playerURL: URL?) -> String? {
        playerRoute(from: playerURL)?.pathID
    }

    private static func item(for projectID: String, in library: [LibraryItem]) -> LibraryItem? {
        library.first { $0.projectID == projectID || $0.id == projectID }
    }

    private static func isAmbiguous(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled, .timedOut, .networkConnectionLost, .notConnectedToInternet,
                 .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
                 .secureConnectionFailed, .serverCertificateHasBadDate,
                 .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
                 .serverCertificateNotYetValid, .clientCertificateRejected,
                 .clientCertificateRequired:
                return true
            default:
                return false
            }
        }
        if error is CancellationError { return true }
        if let samply = error as? SamplyError {
            switch samply {
            case .invalidResponse:
                return true
            case .http(let code, _):
                return code == 408 || (500...599).contains(code)
            default:
                return false
            }
        }
        return false
    }

    private static func quarantineMessage(project: SamplyProject, accountID: String,
                                          visibleInLibrary: Bool = false) -> String {
        let detail: String
        if let creator = project.creator?.uid, !creator.isEmpty {
            detail = "Samply returned creator identity \(creator), which does not match the verified account \(accountID)."
        } else {
            detail = "Samply's creation response did not include a creator UID."
        }
        var message = "The project may exist in Samply, but its identity could not be verified. \(detail) Tunes stopped all artwork and file uploads. Check the account that owns this token in Samply."
        if visibleInLibrary {
            message += " The project is visible in the current web Library, but that visibility does not prove token ownership."
        }
        return message
    }

    private static let interruptedRefreshMessage =
        "Project created, but the Library refresh was interrupted. Refresh Library to try again."
    private static let interruptedOpenMessage =
        "Project created, but opening it was interrupted. Try opening it again."

    private static func failureMessage(_ error: Error) -> String {
        if let credential = error as? ProjectCredentialError {
            return credential.localizedDescription
        }
        if let samply = error as? SamplyError {
            switch samply {
            case .noToken:
                return "Add a Samply Personal Access Token in Settings > API Access before creating a project."
            case .invalidToken:
                return "Your Samply token is invalid or expired. Update it in Settings > API Access."
            case .http(403, _):
                return "Samply denied project creation. Check your account permissions."
            case .http(429, _):
                return "Samply is rate limiting requests. Wait a moment, then try again. Tunes did not retry automatically."
            case .http(let code, _):
                return "Samply rejected project creation (HTTP \(code))."
            default:
                break
            }
        }
        return "The project could not be created. Check your connection and try again."
    }

    private static func uncertainMessage(_ error: Error) -> String {
        if let urlError = error as? URLError, urlError.code == .timedOut {
            return "The request timed out before Samply confirmed the result. The project may already exist. Refresh your Library before trying again."
        }
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            return "The request was interrupted before Samply confirmed the result. The project may already exist. Refresh your Library before trying again."
        }
        if let samply = error as? SamplyError, case .http(let code, _) = samply {
            return "Samply reported an HTTP \(code) error. The project may already exist. Refresh your Library before trying again."
        }
        return "The connection was lost or Samply's response could not be read. The project may already exist. Refresh your Library before trying again."
    }

    private static func refreshFailureMessage(_ error: Error) -> String {
        "Project created, but Tunes could not refresh your Library: \(error.localizedDescription)"
    }

    private static func openFailureMessage(_ error: Error) -> String {
        "Project created, but Tunes could not open it: \(error.localizedDescription)"
    }
}

extension SamplyAPI: ProjectCreatingAPI {
    func createProject(name: String,
                       credential: VerifiedProjectCredential) async throws -> SamplyProject {
        try await createProject(name: name, token: credential.token)
    }
}

extension SamplyWebSession: ProjectCreationWebSession {
    var accountID: String? { snapshot?.account?.uid }
}

extension SamplyWebSession: ProjectOwnershipReading {
    func projectOwnership(projectID: String) async throws -> ProjectOwnershipProof {
        let value: WebProjectOwnership = try await call(
            "projectOwnership", arguments: ["projectID": projectID])
        guard let accountID = snapshot?.account?.uid,
              value.accountID == accountID,
              value.projectID == projectID else {
            throw SamplyError.invalidResponse
        }
        return ProjectOwnershipProof(accountID: value.accountID,
                                     projectID: value.projectID,
                                     ownerID: value.ownerID,
                                     exists: value.exists)
    }
}
