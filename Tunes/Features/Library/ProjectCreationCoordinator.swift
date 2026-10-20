import Foundation
import Observation

@MainActor
protocol ProjectCreatingAPI: AnyObject {
    func createProject(name: String) async throws -> SamplyProject
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
    struct CreatedProject: Equatable, Sendable {
        let accountID: String
        let project: SamplyProject
        let playerURL: URL?
        let routeID: String?
        var libraryItem: LibraryItem?

        var openItem: LibraryItem? {
            if let libraryItem { return libraryItem }
            // The documented player URL uses the existing /p/<shareid> route.
            // Its derived identity lets the user open a project before the
            // complete web Library has propagated the new history entry.
            guard let routeID else { return nil }
            return LibraryItem(id: project.id, name: project.name, projectID: project.id,
                               playerID: nil, shareID: routeID, artist: nil,
                               artwork: project.artwork, canUpload: true, isOwned: true)
        }
    }

    enum Stage: Equatable, Sendable {
        case refreshing
        case opening
        case opened
        case delayed
        case refreshFailed(String)
        case openFailed(String)

        var isBusy: Bool { self == .refreshing || self == .opening }
    }

    enum State: Equatable, Sendable {
        case idle
        case creating
        case created(CreatedProject, Stage)
        case failed(String)
        case uncertain(String, canStartOver: Bool)
    }

    private(set) var state: State = .idle
    @ObservationIgnored private let api: any ProjectCreatingAPI
    @ObservationIgnored private let web: any ProjectCreationWebSession
    @ObservationIgnored private var operation = UUID()
    @ObservationIgnored var onLibraryRefreshed: (([LibraryItem]) -> Void)?
    @ObservationIgnored var onProjectOpened: ((LibraryItem, WebSnapshot) -> Void)?

    init(api: any ProjectCreatingAPI, web: any ProjectCreationWebSession) {
        self.api = api
        self.web = web
    }

    var isCreating: Bool {
        if case .creating = state { return true }
        return false
    }

    var blocksDismissal: Bool { isCreating }

    var createdProject: CreatedProject? {
        if case .created(let project, _) = state { return project }
        return nil
    }

    var createdStage: Stage? {
        if case .created(_, let stage) = state { return stage }
        return nil
    }

    /// Starts exactly one POST /projects request. A blank name after trimming is
    /// rejected before any account or network work.
    func create(name: String) async {
        guard !isCreating else { return }
        if case .created = state { return }

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            state = .failed("Enter a project name.")
            return
        }
        guard let accountID = web.accountID, !web.isSigningOut else {
            state = .failed("Sign in to Samply before creating a project.")
            return
        }
        guard !Task.isCancelled else { return }

        let ticket = UUID()
        operation = ticket
        state = .creating

        do {
            let project = try await api.createProject(name: trimmed)
            guard isCurrent(ticket, accountID: accountID) else { return }

            let created = CreatedProject(accountID: accountID, project: project,
                                         playerURL: project.playerUrl,
                                         routeID: Self.routeID(from: project.playerUrl))
            state = .created(created, .refreshing)
            await refreshAndOpen(created, ticket: ticket)
        } catch {
            guard isCurrent(ticket, accountID: accountID) else { return }
            if Self.isAmbiguous(error) {
                state = .uncertain(Self.uncertainMessage(error), canStartOver: false)
            } else {
                state = .failed(Self.failureMessage(error))
            }
        }
    }

    /// Read-only refresh for a confirmed creation whose Library update or
    /// navigation failed. It never calls POST /projects again.
    func refreshLibrary() async {
        switch state {
        case .created(var created, let stage):
            guard !stage.isBusy else { return }
            guard isCurrentAccount(created.accountID) else {
                invalidate()
                return
            }
            let ticket = UUID()
            operation = ticket
            state = .created(created, .refreshing)
            do {
                guard let snapshot = try await completeLibrary(ticket: ticket,
                                                               accountID: created.accountID) else { return }
                if let item = Self.item(for: created.project.id, in: snapshot.library) {
                    created.libraryItem = item
                    state = .created(created, .opening)
                    do {
                        guard let opened = try await open(item: item, ticket: ticket,
                                                          accountID: created.accountID) else { return }
                        state = .created(created, .opened)
                        onProjectOpened?(item, opened)
                    } catch is CancellationError {
                        return
                    } catch {
                        guard isCurrent(ticket, accountID: created.accountID) else { return }
                        state = .created(created, .openFailed(Self.openFailureMessage(error)))
                    }
                } else {
                    state = .created(created, .delayed)
                }
            } catch is CancellationError {
                return
            } catch {
                guard isCurrent(ticket, accountID: created.accountID) else { return }
                state = .created(created, .refreshFailed(Self.refreshFailureMessage(error)))
            }

        case .uncertain:
            await refreshAfterUncertainOutcome()

        default:
            return
        }
    }

    /// Opens the confirmed project through the adapter's existing browse command.
    /// The refreshed Library item is preferred; the documented player URL is used
    /// only when Library propagation is delayed.
    func openCreatedProject() async {
        guard case .created(let created, let stage) = state, !stage.isBusy else { return }
        guard isCurrentAccount(created.accountID) else {
            invalidate()
            return
        }
        guard let item = created.openItem else {
            state = .created(created, .openFailed(
                "Samply did not provide a player link for this project. Refresh Library and open it there."))
            return
        }
        let ticket = UUID()
        operation = ticket
        state = .created(created, .opening)
        do {
            guard let opened = try await open(item: item, ticket: ticket,
                                              accountID: created.accountID) else { return }
            state = .created(created, .opened)
            onProjectOpened?(item, opened)
        } catch is CancellationError {
            return
        } catch {
            guard isCurrent(ticket, accountID: created.accountID) else { return }
            state = .created(created, .openFailed(Self.openFailureMessage(error)))
        }
    }

    /// After an explicit read-only refresh, the user can start over only when the
    /// uncertain creation flow has been checked against the complete Library.
    func startOverAfterUncertainOutcome() {
        guard case .uncertain(_, let canStartOver) = state, canStartOver else { return }
        operation = UUID()
        state = .idle
    }

    /// Clears a failed or completed sheet without touching an in-flight POST.
    func reset() {
        guard !isCreating else { return }
        invalidate()
    }

    /// Invalidates every in-flight result after sign-out or an account change.
    func invalidate() {
        operation = UUID()
        state = .idle
    }

    private func refreshAndOpen(_ created: CreatedProject, ticket: UUID) async {
        do {
            guard let snapshot = try await completeLibrary(ticket: ticket,
                                                           accountID: created.accountID) else { return }
            if let item = Self.item(for: created.project.id, in: snapshot.library) {
                var updated = created
                updated.libraryItem = item
                state = .created(updated, .opening)
                do {
                    guard let opened = try await open(item: item, ticket: ticket,
                                                      accountID: created.accountID) else { return }
                    state = .created(updated, .opened)
                    onProjectOpened?(item, opened)
                } catch is CancellationError {
                    return
                } catch {
                    guard isCurrent(ticket, accountID: created.accountID) else { return }
                    state = .created(updated, .openFailed(Self.openFailureMessage(error)))
                }
            } else {
                state = .created(created, .delayed)
            }
        } catch is CancellationError {
            return
        } catch {
            guard isCurrent(ticket, accountID: created.accountID) else { return }
            state = .created(created, .refreshFailed(Self.refreshFailureMessage(error)))
        }
    }

    private func refreshAfterUncertainOutcome() async {
        guard let accountID = web.accountID, !web.isSigningOut else {
            state = .uncertain("Sign in to Samply to refresh the Library.", canStartOver: false)
            return
        }
        let ticket = UUID()
        operation = ticket
        state = .uncertain("Refreshing Library…", canStartOver: false)
        do {
            guard try await completeLibrary(ticket: ticket,
                                            accountID: accountID) != nil else { return }
            state = .uncertain("Library refreshed. Check the Library for the project before trying again.",
                               canStartOver: true)
        } catch is CancellationError {
            return
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

    private func open(item: LibraryItem, ticket: UUID,
                      accountID: String) async throws -> WebSnapshot? {
        let snapshot: WebSnapshot = try await web.call("browse",
                                                       arguments: ["routeID": item.routeID])
        guard isCurrent(ticket, accountID: accountID) else { return nil }
        guard snapshot.version == 1, snapshot.account?.uid == accountID,
              snapshot.hasLoadedBoxes(for: item, groupID: nil) else {
            throw SamplyError.invalidResponse
        }
        return snapshot
    }

    private func isCurrent(_ ticket: UUID, accountID: String) -> Bool {
        operation == ticket && !web.isSigningOut && web.accountID == accountID
    }

    private func isCurrentAccount(_ accountID: String) -> Bool {
        !web.isSigningOut && web.accountID == accountID
    }

    static func routeID(from playerURL: URL?) -> String? {
        guard let playerURL, playerURL.scheme?.lowercased() == "https",
              playerURL.host?.lowercased() == "samply.app", playerURL.port == nil,
              playerURL.user == nil, playerURL.password == nil else { return nil }
        let components = playerURL.pathComponents.filter { $0 != "/" }
        guard components.count == 2, components[0] == "p" else { return nil }
        let routeID = components[1]
        return routeID.isEmpty ? nil : routeID
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

    private static func failureMessage(_ error: Error) -> String {
        if let samply = error as? SamplyError {
            switch samply {
            case .noToken:
                return "Add a Samply Personal Access Token in Upload Settings before creating a project."
            case .invalidToken:
                return "Your Samply token is invalid or expired. Update it in Upload Settings."
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

extension SamplyAPI: ProjectCreatingAPI {}

extension SamplyWebSession: ProjectCreationWebSession {
    var accountID: String? { snapshot?.account?.uid }
}
