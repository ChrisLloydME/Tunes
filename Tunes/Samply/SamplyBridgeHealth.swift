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

    func pollInterval(at uptime: TimeInterval) -> Duration {
        guard let failureStartedAt, uptime - failureStartedAt < 10 else { return .milliseconds(700) }
        return .milliseconds(250)
    }
}

enum SamplyBridgeError: LocalizedError {
    case notReady, executionFailed, operationFailed

    var isTransient: Bool {
        switch self {
        case .notReady, .executionFailed: true
        case .operationFailed: false
        }
    }

    var errorDescription: String? {
        switch self {
        case .notReady:
            "Samply is still initializing. Open the Samply window to check its loading status."
        case .executionFailed:
            "Could not read or update the Samply web player. Open the Samply window and try again."
        case .operationFailed:
            "Samply could not complete this action. Check your access and the Samply window, then try again."
        }
    }
}
