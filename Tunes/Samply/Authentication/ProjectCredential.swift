import Foundation
import Observation

/// Identifies one mutation flow. Read-only work (refresh, browse, open) uses a
/// separate navigation generation and must not invalidate credential proof.
struct MutationContext: Equatable, Sendable {
    let operationID: UUID
    let sessionGeneration: UInt64
    let accountID: String
    let credentialRevision: UInt64
}

/// A credential captured for one mutation flow. The token is never reread after
/// the flow starts, so replacing the saved token cannot change an operation
/// halfway through an upload queue.
struct VerifiedProjectCredential: Sendable {
    let token: String
    let accountID: String
    let sessionGeneration: UInt64
    let credentialRevision: UInt64
}

enum ProjectCredentialState: Equatable, Sendable {
    case absent
    case validating
    case verified(accountID: String, sessionGeneration: UInt64, credentialRevision: UInt64)
    case rejected(String)
    case identityUnverifiable(String)
}

enum ProjectCredentialError: LocalizedError, Equatable {
    case notSignedIn
    case invalidToken
    case identityUnverifiable(String)
    case network
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            "Sign in to Samply before adding a personal access token."
        case .invalidToken:
            "Samply rejected this personal access token. Your saved token was not changed."
        case .identityUnverifiable(let message):
            message
        case .network:
            "Tunes could not verify this token because Samply or the signed-in web session was unavailable. Your saved token was not changed."
        case .cancelled:
            "Token verification was interrupted. Your saved token was not changed."
        }
    }
}

struct ProjectOwnershipProof: Equatable, Sendable {
    let accountID: String
    let projectID: String
    let ownerID: String?
    let exists: Bool
}

@MainActor
protocol ProjectOwnershipReading: AnyObject {
    var accountID: String? { get }
    var isSigningOut: Bool { get }
    func projectOwnership(projectID: String) async throws -> ProjectOwnershipProof
}

@MainActor
protocol ProjectCredentialProviding: AnyObject {
    var state: ProjectCredentialState { get }
    var accountID: String? { get }
    var sessionGeneration: UInt64 { get }
    var credentialRevision: UInt64 { get }
    var hasStoredToken: Bool { get }
    func verifiedCredential() -> VerifiedProjectCredential?
    func isCurrent(_ context: MutationContext) -> Bool
}

/// Validates a PAT against the signed-in web account without writing a project.
///
/// Samply's documented API has no identity endpoint, so proof uses two reads:
/// the PAT's documented owned-project list and an authenticated web read showing
/// that the same project is currently owned by the signed-in UID. An empty list
/// cannot establish token identity and is reported as unverifiable rather than
/// guessed, because creating a disposable project to discover ownership is not
/// allowed. `creator.uid` alone is deliberately not accepted as proof.
@MainActor
@Observable
final class ProjectCredentialAuthority: ProjectCredentialProviding {
    private(set) var state: ProjectCredentialState = .absent
    private(set) var accountID: String?
    private(set) var sessionGeneration: UInt64 = 0
    private(set) var credentialRevision: UInt64 = 0
    private(set) var hasStoredToken = false
    @ObservationIgnored private var verified: VerifiedProjectCredential?
    @ObservationIgnored private var storedToken: String?
    @ObservationIgnored private var validationTask: Task<Void, Never>?
    @ObservationIgnored private var validationID = UUID()
    @ObservationIgnored private let tokens: any TokenStore
    @ObservationIgnored private let api: SamplyAPI
    @ObservationIgnored private let ownership: any ProjectOwnershipReading

    init(tokens: any TokenStore, api: SamplyAPI, ownership: any ProjectOwnershipReading) {
        self.tokens = tokens
        self.api = api
        self.ownership = ownership
    }

    /// Starts a new account/session generation, restores only that account's
    /// credential, and revalidates it before reporting any verified state.
    func activate(accountID newAccountID: String?, generation: UInt64) {
        validationTask?.cancel()
        validationTask = nil
        validationID = UUID()
        credentialRevision &+= 1
        accountID = newAccountID
        sessionGeneration = generation
        verified = nil
        storedToken = nil
        hasStoredToken = false
        guard let newAccountID else {
            state = .absent
            do { try tokens.restore(for: nil) }
            catch { state = .rejected(error.localizedDescription) }
            return
        }

        do {
            try tokens.restore(for: newAccountID)
            guard let token = try tokens.read(), !token.isEmpty else {
                state = .absent
                return
            }
            storedToken = token
            hasStoredToken = true
            state = .validating
            let revision = credentialRevision
            let id = validationID
            validationTask = Task { [weak self] in
                await self?.validateRestoredToken(token, accountID: newAccountID,
                                                 generation: generation,
                                                 revision: revision, id: id)
            }
        } catch {
            state = .rejected(error.localizedDescription)
        }
    }

    /// Validates a candidate before it replaces a working saved token. The
    /// candidate stays in memory and is never written after a rejection.
    func saveCandidate(_ token: String) async throws {
        guard let accountID, !accountID.isEmpty else { throw ProjectCredentialError.notSignedIn }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\n"), !trimmed.contains("\r") else {
            throw ProjectCredentialError.invalidToken
        }
        let generation = sessionGeneration
        let revision = credentialRevision
        let id = UUID()
        validationID = id
        validationTask?.cancel()
        validationTask = nil
        let previousState = state
        let previousVerified = verified
        let previousStoredToken = storedToken
        // Candidate validation must not suspend the active credential or its
        // captured mutation contexts. Only a successful replacement changes it.
        if previousVerified == nil { state = .validating }
        do {
            try await verifyIdentity(token: trimmed, accountID: accountID,
                                     generation: generation, revision: revision)
            try ensureCurrent(accountID: accountID, generation: generation,
                              revision: revision, id: id)
            try tokens.save(trimmed)
            credentialRevision &+= 1
            storedToken = trimmed
            hasStoredToken = true
            verified = VerifiedProjectCredential(
                token: trimmed, accountID: accountID,
                sessionGeneration: generation, credentialRevision: credentialRevision)
            state = .verified(accountID: accountID, sessionGeneration: generation,
                              credentialRevision: credentialRevision)
        } catch {
            guard isSameSession(accountID: accountID, generation: generation),
                  credentialRevision == revision, validationID == id else {
                throw ProjectCredentialError.cancelled
            }
            let publicError = Self.publicError(from: error)
            validationID = UUID()
            verified = previousVerified
            storedToken = previousStoredToken
            hasStoredToken = previousStoredToken != nil
            if let previousStoredToken {
                storedToken = previousStoredToken
                hasStoredToken = true
                if case .validating = previousState {
                    // The candidate interrupted a restored-token validation.
                    // Re-run it rather than leaving a stale validating state.
                    state = .validating
                    let id = UUID()
                    validationID = id
                    let generation = sessionGeneration
                    let revision = credentialRevision
                    validationTask = Task { [weak self] in
                        await self?.validateRestoredToken(previousStoredToken,
                                                          accountID: accountID,
                                                          generation: generation,
                                                          revision: revision, id: id)
                    }
                } else {
                    state = previousState
                }
            } else {
                switch publicError {
                case .invalidToken:
                    state = .rejected(ProjectCredentialError.invalidToken.localizedDescription)
                case .identityUnverifiable(let message):
                    state = .identityUnverifiable(message)
                case .notSignedIn, .network, .cancelled:
                    state = .identityUnverifiable(ProjectCredentialError.network.localizedDescription)
                }
            }
            throw publicError
        }
    }

    func remove() throws {
        validationTask?.cancel()
        validationTask = nil
        validationID = UUID()
        credentialRevision &+= 1
        verified = nil
        storedToken = nil
        hasStoredToken = false
        state = .absent
        try tokens.remove()
    }

    func verifiedCredential() -> VerifiedProjectCredential? {
        guard let verified, hasStoredToken,
              case .verified(let accountID, let generation, let revision) = state,
              accountID == self.accountID,
              generation == sessionGeneration,
              revision == credentialRevision else { return nil }
        return verified
    }

    func isCurrent(_ context: MutationContext) -> Bool {
        guard context.accountID == accountID,
              context.sessionGeneration == sessionGeneration,
              context.credentialRevision == credentialRevision,
              let verified = verifiedCredential() else { return false }
        return verified.accountID == context.accountID &&
            verified.sessionGeneration == context.sessionGeneration &&
            verified.credentialRevision == context.credentialRevision
    }

    private func validateRestoredToken(_ token: String, accountID: String,
                                       generation: UInt64, revision: UInt64,
                                       id: UUID) async {
        do {
            try await verifyIdentity(token: token, accountID: accountID,
                                     generation: generation, revision: revision)
            try ensureCurrent(accountID: accountID, generation: generation,
                              revision: revision, id: id)
            storedToken = token
            hasStoredToken = true
            verified = VerifiedProjectCredential(
                token: token, accountID: accountID,
                sessionGeneration: generation, credentialRevision: revision)
            state = .verified(accountID: accountID, sessionGeneration: generation,
                              credentialRevision: revision)
        } catch {
            guard isSameSession(accountID: accountID, generation: generation),
                  validationID == id, credentialRevision == revision else { return }
            verified = nil
            hasStoredToken = storedToken != nil
            switch Self.publicError(from: error) {
            case .invalidToken:
                state = .rejected(ProjectCredentialError.invalidToken.localizedDescription)
            case .identityUnverifiable(let message):
                state = .identityUnverifiable(message)
            case .notSignedIn, .network, .cancelled:
                state = .identityUnverifiable(ProjectCredentialError.network.localizedDescription)
            }
        }
    }

    private func verifyIdentity(token: String, accountID: String,
                                generation: UInt64, revision: UInt64) async throws {
        let projects: [SamplyProject]
        do {
            projects = try await api.projects(token: token)
        } catch let error as SamplyError {
            switch error {
            case .invalidToken:
                throw ProjectCredentialError.invalidToken
            case .noToken:
                throw ProjectCredentialError.notSignedIn
            default:
                throw ProjectCredentialError.network
            }
        } catch is CancellationError {
            throw ProjectCredentialError.cancelled
        } catch {
            throw ProjectCredentialError.network
        }
        try ensureSameSession(accountID: accountID, generation: generation,
                              revision: revision)
        guard !projects.isEmpty else {
            throw ProjectCredentialError.identityUnverifiable(Self.emptyProjectListMessage)
        }

        var readFailed = false
        var sawDifferentOwner = false
        let candidates = projects
            .sorted { ($0.timeModified ?? 0) > ($1.timeModified ?? 0) }
            .prefix(20)
        for project in candidates {
            try ensureSameSession(accountID: accountID, generation: generation,
                                  revision: revision)
            do {
                let proof = try await ownership.projectOwnership(projectID: project.id)
                try ensureSameSession(accountID: accountID, generation: generation,
                                      revision: revision)
                guard ownership.accountID == accountID,
                      proof.accountID == accountID,
                      proof.projectID == project.id else {
                    throw ProjectCredentialError.cancelled
                }
                guard proof.exists else { continue }
                guard proof.ownerID == accountID else {
                    sawDifferentOwner = true
                    continue
                }
                return
            } catch let error as ProjectCredentialError {
                throw error
            } catch is CancellationError {
                throw ProjectCredentialError.cancelled
            } catch {
                readFailed = true
                continue
            }
        }
        if sawDifferentOwner {
            throw ProjectCredentialError.identityUnverifiable(Self.otherOwnerMessage)
        }
        if readFailed {
            throw ProjectCredentialError.identityUnverifiable(Self.ownershipReadUnavailableMessage)
        }
        throw ProjectCredentialError.identityUnverifiable(Self.otherOwnerMessage)
    }

    private func ensureCurrent(accountID: String, generation: UInt64,
                               revision: UInt64, id: UUID) throws {
        guard isSameSession(accountID: accountID, generation: generation),
              credentialRevision == revision, validationID == id else {
            throw ProjectCredentialError.cancelled
        }
    }

    private func ensureSameSession(accountID: String, generation: UInt64,
                                   revision: UInt64) throws {
        guard isSameSession(accountID: accountID, generation: generation),
              credentialRevision == revision else {
            throw ProjectCredentialError.cancelled
        }
    }

    private func isSameSession(accountID: String, generation: UInt64) -> Bool {
        self.accountID == accountID && sessionGeneration == generation &&
            ownership.accountID == accountID && !ownership.isSigningOut
    }

    private static func publicError(from error: Error) -> ProjectCredentialError {
        if let credential = error as? ProjectCredentialError { return credential }
        if error is CancellationError { return .cancelled }
        return .network
    }

    private static let emptyProjectListMessage =
        "Your token works, but this account has no owned project that Tunes can use to prove the token matches the signed-in Samply account. Samply does not document an identity endpoint, and Tunes will not create a disposable project to discover token ownership. Create a first project in Samply's website, then verify the token again. Project creation in Tunes is blocked until identity can be verified."

    private static let otherOwnerMessage =
        "The token works, but its owned projects belong to a different Samply account than the one signed in here. Tunes did not replace your saved token."

    private static let ownershipReadUnavailableMessage =
        "The token works, but Tunes could not complete the authenticated project read needed to prove it belongs to the signed-in account. Keep the Samply window available and try again."
}
