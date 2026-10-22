import Foundation

/// One bounded automatic content-recovery episode. The initial failed read is
/// not counted; at most three recovery reads follow at 0.5, 1, and 2 seconds with
/// bounded jitter. Explicit user retries start a new episode.
struct SamplyReadRecoveryPolicy: Equatable, Sendable {
    var attemptDelays: [TimeInterval] = [0.5, 1, 2]
    var jitterFraction: Double = 0.15

    var maximumAttempts: Int { attemptDelays.count }

    func delay(forAttempt index: Int, randomValue: Double) -> TimeInterval {
        guard !attemptDelays.isEmpty else { return 0 }
        let base = attemptDelays[min(max(index, 0), attemptDelays.count - 1)]
        let unit = min(max(randomValue, 0), 1)
        let jitter = base * jitterFraction * (unit * 2 - 1)
        return max(0.05, base + jitter)
    }

    /// Retries only transient read failures. Access denial, a changed contract,
    /// supersession, cancellation, and mutation rejections are terminal for the
    /// episode.
    func shouldRetry(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if let bridge = error as? SamplyBridgeError {
            switch bridge {
            case .notReady, .timedOut, .executionFailed: return true
            case .contractMismatch, .accessDenied, .superseded, .operationFailed: return false
            }
        }
        if let sample = error as? SamplyError {
            switch sample {
            case .invalidResponse, .timedOut, .webContract:
                return true
            case .http(let code, _):
                return code == 429 || (500...599).contains(code)
            case .noToken, .noAccount, .invalidToken, .invalidIdentifier,
                 .insecureURL, .bridgeUnavailable, .fileChanged:
                return false
            }
        }
        return true
    }
}
