import Foundation

/// Fixed command categories. Unknown commands are never recorded as text so a
/// future caller cannot leak arguments, URLs, or account data into diagnostics.
enum SamplyDiagnosticCommand: String, CaseIterable, Sendable {
    case snapshot, runtimeSnapshot, browse, playBox, refreshPage, navigatePage
    case projectOwnership, versions, transport, quality, artwork, rest

    init?(command: String) {
        self.init(rawValue: command)
    }
}

/// Local flow milestones. These distinguish native command timing from the
/// later accepted state so a fast call is not mistaken for audible playback or
/// a completed Library refresh.
enum SamplyDiagnosticStage: String, CaseIterable, Sendable {
    case sessionRestoration
    case libraryAcceptance
    case selection
    case playbackStart
    case serverRefresh
    case bridgeInvocation
    case responseDecoding
    case artworkTransfer
    case artworkDecode
    case artworkCacheHit
    case avatarTransfer
    case restAttempt
}

enum SamplyDiagnosticOutcome: String, CaseIterable, Sendable {
    case success, notReady, contractMismatch, accessDenied, superseded
    case timedOut, cancelled, failure
}

struct SamplyDiagnosticSample: Sendable {
    var stage: SamplyDiagnosticStage
    var command: SamplyDiagnosticCommand?
    var operationID: UInt64
    var duration: TimeInterval = 0
    var responseBytes: Int = 0
    var itemCount: Int = 0
    var attemptCount: Int = 1
    var outcome: SamplyDiagnosticOutcome = .success
}

struct SamplyDiagnosticAggregate: Equatable, Sendable {
    private(set) var count = 0
    private(set) var totalDuration: TimeInterval = 0
    private(set) var maximumDuration: TimeInterval = 0
    private(set) var responseBytes = 0
    private(set) var itemCount = 0
    private(set) var attempts = 0

    var averageDuration: TimeInterval { count == 0 ? 0 : totalDuration / Double(count) }

    mutating func add(_ sample: SamplyDiagnosticSample) {
        count += 1
        totalDuration += max(0, sample.duration)
        maximumDuration = max(maximumDuration, sample.duration)
        responseBytes += max(0, sample.responseBytes)
        itemCount += max(0, sample.itemCount)
        attempts += max(0, sample.attemptCount)
    }
}

/// Opt-in, Debug-only aggregate counters for the local bridge. There is one
/// bounded bucket per stage/outcome pair (never one log entry per poll), and no
/// arguments, identifiers, URLs, headers, credentials, or exception text are
/// retained.
@MainActor
final class SamplyDiagnostics {
    static let shared = SamplyDiagnostics()

    private struct Key: Hashable {
        let stage: SamplyDiagnosticStage
        let outcome: SamplyDiagnosticOutcome
    }

    private(set) var isEnabled: Bool
    private(set) var operationCount: UInt64 = 0
    private var aggregates: [Key: SamplyDiagnosticAggregate] = [:]

    var trackedBucketCount: Int { aggregates.count }

    init(isEnabled: Bool? = nil) {
        self.isEnabled = isEnabled ?? Self.optIn
    }

    /// Diagnostics are disabled unless a developer opts in for this Debug build.
    /// Release builds always return `false`.
    static var optIn: Bool {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment["TUNES_BRIDGE_DIAGNOSTICS"] == "1"
        return environment || UserDefaults.standard.bool(forKey: "samply.bridgeDiagnostics")
        #else
        return false
        #endif
    }

    func nextOperationID() -> UInt64 {
        operationCount &+= 1
        return operationCount
    }

    func record(_ sample: SamplyDiagnosticSample) {
        guard isEnabled else { return }
        let key = Key(stage: sample.stage, outcome: sample.outcome)
        aggregates[key, default: SamplyDiagnosticAggregate()].add(sample)
    }

    func aggregate(stage: SamplyDiagnosticStage,
                   outcome: SamplyDiagnosticOutcome = .success) -> SamplyDiagnosticAggregate? {
        aggregates[Key(stage: stage, outcome: outcome)]
    }

    func recordCount(stage: SamplyDiagnosticStage) -> Int {
        SamplyDiagnosticOutcome.allCases.reduce(0) { total, outcome in
            total + (aggregates[Key(stage: stage, outcome: outcome)]?.count ?? 0)
        }
    }

    func reset() {
        aggregates.removeAll()
        operationCount = 0
    }
}

extension SamplyDiagnosticOutcome {
    init(_ error: Error) {
        if error is CancellationError {
            self = .cancelled
            return
        }
        guard let bridge = error as? SamplyBridgeError else {
            self = .failure
            return
        }
        switch bridge {
        case .notReady: self = .notReady
        case .contractMismatch: self = .contractMismatch
        case .accessDenied: self = .accessDenied
        case .superseded: self = .superseded
        case .timedOut: self = .timedOut
        case .executionFailed, .operationFailed: self = .failure
        }
    }
}
