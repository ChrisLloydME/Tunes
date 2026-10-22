import Foundation

/// Background polling may race the page's initialization or a document replacement.
/// Require a sustained failure before interrupting the user; commands still fail immediately.
struct SamplyBridgeHealth {
    private var failureStartedAt: TimeInterval?

    mutating func recordFailure(at uptime: TimeInterval) -> Bool {
        if failureStartedAt == nil { failureStartedAt = uptime }
        return uptime - (failureStartedAt ?? uptime) >= 5
    }

    mutating func reset() { failureStartedAt = nil }

    /// Healthy sampling stays at 700 ms. Persistent transient status failures
    /// accelerate briefly, then back probes off through 1, 2, and 5 seconds.
    /// Terminal feature errors do not enter this failure window.
    func pollInterval(at uptime: TimeInterval) -> Duration {
        guard let failureStartedAt else { return .milliseconds(700) }
        let elapsed = uptime - failureStartedAt
        if elapsed < 10 { return .milliseconds(250) }
        if elapsed < 15 { return .seconds(1) }
        if elapsed < 20 { return .seconds(2) }
        return .seconds(5)
    }
}

enum SamplyBridgeError: LocalizedError, Equatable {
    /// The page is still initializing; a later poll or startup read may succeed.
    case notReady
    /// The pinned web build no longer exposes a required contract for one feature.
    /// This is terminal for that feature until the document changes.
    case contractMismatch
    /// Samply rejected the account, permission, or resource.
    case accessDenied
    /// A newer navigation or selection made this operation obsolete.
    case superseded
    /// The complete native invocation exceeded its deadline.
    case timedOut
    /// WebKit failed before the adapter could answer.
    case executionFailed
    /// The adapter rejected an otherwise valid command.
    case operationFailed

    var isTransient: Bool {
        switch self {
        case .notReady, .executionFailed, .timedOut: true
        case .contractMismatch, .accessDenied, .superseded, .operationFailed: false
        }
    }

    var errorDescription: String? {
        switch self {
        case .notReady:
            "Samply is still initializing. Open the Samply window to check its loading status."
        case .contractMismatch:
            "This Samply web build no longer supports part of the Tunes integration. Other features remain available."
        case .accessDenied:
            "Samply denied access to this item. Check your account and sharing permissions."
        case .superseded:
            "A newer request replaced this action."
        case .timedOut:
            "Samply did not answer in time. Open the Samply window to check your sign-in and access permissions."
        case .executionFailed:
            "Could not read or update the Samply web player. Open the Samply window and try again."
        case .operationFailed:
            "Samply could not complete this action. Check your access and the Samply window, then try again."
        }
    }
}
