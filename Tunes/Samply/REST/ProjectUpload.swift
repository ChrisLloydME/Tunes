import Foundation

enum UploadKind: Equatable, Sendable {
    case originalFile
    case artwork
}

struct UploadTicketIdentity: Equatable, Sendable {
    let boxID: String
    let projectID: String
    let fileName: String
    let kind: UploadKind
}

/// The last known boundary of an upload. A cancellation before `.ticketRequested`
/// has not contacted Samply; every later phase may already have created remote
/// state and must not be described as safely retryable.
enum UploadPhase: Equatable, Sendable {
    case waiting
    case ticketRequested
    case ticketReceived
    case putStarted
    case submitted
}

enum UploadDisposition: Equatable, Sendable {
    case cancelled
    case failed(String)
    case uncertain(String)
    case submitted
}

/// Structured result carrying the ticket identity and the last confirmed phase.
/// A successful storage response is retained even when the surrounding task was
/// cancelled while the response was in flight.
struct UploadOutcome: Equatable, Sendable {
    let disposition: UploadDisposition
    let phase: UploadPhase
    let ticket: UploadTicketIdentity?

    static func cancelled(_ phase: UploadPhase,
                          ticket: UploadTicketIdentity? = nil) -> UploadOutcome {
        UploadOutcome(disposition: .cancelled, phase: phase, ticket: ticket)
    }

    static func failed(_ message: String, phase: UploadPhase,
                       ticket: UploadTicketIdentity? = nil) -> UploadOutcome {
        UploadOutcome(disposition: .failed(message), phase: phase, ticket: ticket)
    }

    static func uncertain(_ message: String, phase: UploadPhase,
                          ticket: UploadTicketIdentity? = nil) -> UploadOutcome {
        UploadOutcome(disposition: .uncertain(message), phase: phase, ticket: ticket)
    }

    static func submitted(_ ticket: UploadTicketIdentity) -> UploadOutcome {
        UploadOutcome(disposition: .submitted, phase: .submitted, ticket: ticket)
    }

    var confirmedBoxID: String? {
        guard case .submitted = disposition else { return nil }
        return ticket?.boxID
    }

    /// Only a definite outcome before any ticket request can be retried without
    /// risking duplicate remote resources.
    var isSafelyRetryable: Bool {
        guard phase == .waiting, ticket == nil else { return false }
        switch disposition {
        case .cancelled, .failed: return true
        case .uncertain, .submitted: return false
        }
    }
}

/// Captures the verified credential and the only validity check an upload may
/// use. Every mutation boundary asks this closure again rather than rereading the
/// token store.
@MainActor
struct UploadAuthorization {
    let credential: VerifiedProjectCredential
    let context: MutationContext
    let isValid: @MainActor () -> Bool

    var isCurrent: Bool { isValid() }
}

@MainActor
protocol ProjectAssetUploading: AnyObject {
    func performUpload(file: URL, projectID: String, parentID: String?,
                       authorization: UploadAuthorization,
                       progress: @escaping @MainActor @Sendable (Double) -> Void) async -> UploadOutcome

    func performArtworkUpload(payload: ProjectArtworkPayload, projectID: String,
                              authorization: UploadAuthorization) async -> UploadOutcome
}
