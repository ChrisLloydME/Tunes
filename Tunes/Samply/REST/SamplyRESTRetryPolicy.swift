import Foundation

/// Bounded REST GET retry policy. The caller's timeout is an operation-wide
/// monotonic budget: every attempt and sleep rechecks what remains, so three
/// attempts cannot each consume the original timeout.
struct SamplyRESTRetryPolicy {
    static let maximumAttempts = 3
    static let retryableStatusCodes: Set<Int> = [429, 502, 503, 504]

    var wallClock: () -> Date
    var monotonicClock: any MonotonicClock
    var sleeper: any Sleeper
    var randomUnit: () -> Double
    var jitterFraction: Double = 0.15

    init(wallClock: (() -> Date)? = nil,
         monotonicClock: (any MonotonicClock)? = nil,
         sleeper: (any Sleeper)? = nil,
         randomUnit: (() -> Double)? = nil) {
        self.wallClock = wallClock ?? Date.init
        self.monotonicClock = monotonicClock ?? SystemMonotonicClock()
        self.sleeper = sleeper ?? TaskSleeper()
        self.randomUnit = randomUnit ?? { Double.random(in: 0...1) }
    }

    func isRetryable(status: Int) -> Bool {
        Self.retryableStatusCodes.contains(status)
    }

    /// The server's requested wait. A malformed or missing header uses bounded
    /// jittered fallback; a valid header is never shortened.
    func retryDelay(for response: HTTPURLResponse, attempt: Int) -> TimeInterval {
        if let requested = Self.parseRetryAfter(
            response.value(forHTTPHeaderField: "Retry-After"), now: wallClock()) {
            return requested
        }
        return fallbackDelay(attempt: attempt)
    }

    /// Delay reported with a typed HTTP error, without inventing a server wait.
    func serverDelay(for response: HTTPURLResponse) -> TimeInterval? {
        Self.parseRetryAfter(response.value(forHTTPHeaderField: "Retry-After"),
                             now: wallClock())
    }

    func fallbackDelay(attempt: Int) -> TimeInterval {
        let base = pow(2, Double(max(0, attempt)))
        let unit = min(max(randomUnit(), 0), 1)
        let jitter = base * jitterFraction * (unit * 2 - 1)
        return max(0.1, base + jitter)
    }

    /// RFC 9110 section 10.2.3: delay-seconds or an HTTP-date.
    static func parseRetryAfter(_ raw: String?, now: Date) -> TimeInterval? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        if raw.range(of: #"^\d+$"#, options: .regularExpression) != nil,
           let seconds = Double(raw), seconds.isFinite {
            return seconds
        }
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz",
                       "EEEE, dd-MMM-yy HH:mm:ss zzz",
                       "EEE MMM d HH:mm:ss yyyy"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) {
                return max(0, date.timeIntervalSince(now))
            }
        }
        return nil
    }

    /// Only explicit transient transport failures are retried. Cancellation,
    /// certificate failures, and unknown errors are not.
    func shouldRetryTransport(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet,
             .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
             .internationalRoamingOff, .dataNotAllowed, .callIsActive:
            true
        default:
            false
        }
    }

    func sleep(for seconds: TimeInterval) async throws {
        try await sleeper.sleep(for: .seconds(seconds))
    }
}
