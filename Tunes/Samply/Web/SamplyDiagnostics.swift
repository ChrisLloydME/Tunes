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

/// Fixed loading milestones. These are deliberately separate from the
/// aggregate bucket stages so operation traces can correlate startup and
/// navigation intervals without recording page content.
enum SamplyLoadingTraceStage: String, CaseIterable, Sendable {
    case requested
    case documentCommitted
    case documentFinished
    case adapterUsable
    case authenticationResolved
    case webLibraryReady
    case payloadDecoded
    case contentPublished
    case selection
    case bridgeStarted
    case routerSettled
    case boxesReady
    case responseBuilt
    case nativeDecoded
    case published
    case cacheHit
    case cacheMiss
}

struct SamplyLoadingTraceSample: Equatable, Sendable {
    let stage: SamplyLoadingTraceStage
    let elapsed: TimeInterval
    let duration: TimeInterval
    let itemCount: Int
    let responseBytes: Int
    let outcome: SamplyDiagnosticOutcome
}

struct SamplyLoadingTraceOperation: Equatable, Sendable, Identifiable {
    let id: UInt64
    let command: SamplyDiagnosticCommand?
    fileprivate(set) var stages: [SamplyLoadingTraceSample] = []
}

/// Opt-in, bounded Debug trace of loading phases. Operations are correlated by
/// opaque local IDs; samples retain only fixed stages, durations, counts, bytes,
/// and outcomes. No URLs, account/resource identifiers, headers, credentials,
/// bodies, or exception text are accepted by this API.
@MainActor
final class SamplyLoadingTraceRecorder {
    static let maxOperations = 128
    static let maxStagesPerOperation = 16

    private(set) var isEnabled: Bool
    private var history: [SamplyLoadingTraceOperation] = []

    init(isEnabled: Bool? = nil) {
        self.isEnabled = isEnabled ?? SamplyDiagnostics.optIn
    }

    var operations: [SamplyLoadingTraceOperation] { history }
    var trackedOperationCount: Int { history.count }

    func operation(id: UInt64) -> SamplyLoadingTraceOperation? {
        history.first { $0.id == id }
    }

    @discardableResult
    func beginOperation(id: UInt64, command: SamplyDiagnosticCommand? = nil) -> Bool {
        guard isEnabled, !history.contains(where: { $0.id == id }) else { return false }
        history.append(SamplyLoadingTraceOperation(id: id, command: command))
        trimHistory()
        return true
    }

    @discardableResult
    func record(stage: SamplyLoadingTraceStage, operationID: UInt64,
                elapsed: TimeInterval, duration: TimeInterval,
                itemCount: Int = 0, responseBytes: Int = 0,
                outcome: SamplyDiagnosticOutcome = .success) -> Bool {
        guard isEnabled else { return false }
        if !history.contains(where: { $0.id == operationID }) {
            history.append(SamplyLoadingTraceOperation(id: operationID, command: nil))
            trimHistory()
        }
        guard let index = history.firstIndex(where: { $0.id == operationID }),
              history[index].stages.count < Self.maxStagesPerOperation else { return false }
        history[index].stages.append(SamplyLoadingTraceSample(
            stage: stage,
            elapsed: max(0, elapsed),
            duration: max(0, duration),
            itemCount: max(0, itemCount),
            responseBytes: max(0, responseBytes),
            outcome: outcome))
        return true
    }

    func reset() {
        history.removeAll()
    }

    /// Sanitized, fixed-format developer output. It contains no page text,
    /// identifiers, URLs, credentials, or arbitrary error descriptions.
    var developerDescription: String {
        guard isEnabled else { return "Loading trace disabled." }
        guard !history.isEmpty else { return "Loading trace: no operations." }
        var lines = ["Loading trace: \(history.count) operation(s)"]
        for operation in history {
            let command = operation.command?.rawValue ?? "unknown"
            lines.append("operation \(operation.id) command=\(command) stages=\(operation.stages.count)")
            for sample in operation.stages {
                let elapsed = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"),
                                     sample.elapsed)
                let duration = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"),
                                      sample.duration)
                lines.append(
                    "  \(sample.stage.rawValue) elapsed=\(elapsed)s duration=\(duration)s " +
                    "count=\(sample.itemCount) bytes=\(sample.responseBytes) " +
                    "outcome=\(sample.outcome.rawValue)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func trimHistory() {
        if history.count > Self.maxOperations {
            history.removeFirst(history.count - Self.maxOperations)
        }
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
    let loadingTrace: SamplyLoadingTraceRecorder
    private var aggregates: [Key: SamplyDiagnosticAggregate] = [:]

    var trackedBucketCount: Int { aggregates.count }

    init(isEnabled: Bool? = nil) {
        let enabled = isEnabled ?? Self.optIn
        self.isEnabled = enabled
        self.loadingTrace = SamplyLoadingTraceRecorder(isEnabled: enabled)
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
        loadingTrace.reset()
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
