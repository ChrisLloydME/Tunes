import Foundation

/// One poll coordinator's cadence policy. Runtime identity/playback is sampled
/// at `runtimeInterval`; complete content is read at most once per
/// `fullContentInterval` unless an explicit identity/route/readiness change or
/// action result invalidates it earlier.
///
/// The interval is a deadline for the next eligible full read, so a due read is
/// not delayed by another full-duration sleep. Tests drive this with a virtual
/// clock; production uses the backend's injected monotonic clock.
struct SamplyPollSchedule: Equatable, Sendable {
    var runtimeInterval: TimeInterval = 0.7
    var fullContentInterval: TimeInterval = 2.1

    private(set) var lastFullReadAt: TimeInterval?
    private(set) var fullReadInvalidated = true
    private(set) var fullReadRetryNotBefore: TimeInterval = 0
    private(set) var invalidationGeneration: UInt64 = 1

    mutating func markFullContentNeeded() {
        invalidationGeneration &+= 1
        fullReadInvalidated = true
        fullReadRetryNotBefore = 0
    }

    func shouldReadFullContent(at time: TimeInterval, interactive: Bool = false) -> Bool {
        guard !interactive, time >= fullReadRetryNotBefore else { return false }
        if fullReadInvalidated { return true }
        guard let lastFullReadAt else { return true }
        return time - lastFullReadAt >= fullContentInterval
    }

    /// Records an attempted full read. A success clears the invalidation only
    /// when no newer invalidation arrived while the read was in flight, so a
    /// stale result cannot erase a follow-up read.
    mutating func recordFullRead(at time: TimeInterval, succeeded: Bool,
                                 generation: UInt64) {
        lastFullReadAt = time
        if succeeded {
            fullReadRetryNotBefore = 0
            fullReadInvalidated = generation != invalidationGeneration
        } else {
            fullReadInvalidated = true
            fullReadRetryNotBefore = time + fullContentInterval
        }
    }

    /// Delay until the next poll. Full reads take priority when due; otherwise
    /// the runtime cadence applies. Interactive commands suppress full reads
    /// without stalling runtime samples.
    func nextPollDelay(at time: TimeInterval, interactive: Bool = false) -> Duration {
        guard !interactive else { return .seconds(runtimeInterval) }
        if fullReadInvalidated, time >= fullReadRetryNotBefore { return .zero }
        if let lastFullReadAt {
            // Compare the same elapsed quantity used by shouldReadFullContent so
            // floating-point addition cannot create a zero-delay tight loop.
            let elapsed = time - lastFullReadAt
            let remaining = max(fullContentInterval - elapsed,
                                fullReadRetryNotBefore - time, 0)
            if remaining <= 0 { return .zero }
            return .seconds(min(runtimeInterval, remaining))
        }
        return .zero
    }
}
