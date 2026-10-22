import Foundation

/// Monotonic time source for deadline, retry, and polling policy.
///
/// Production code uses `ProcessInfo.systemUptime`, which is unaffected by
/// wall-clock changes. Tests inject a manual clock so request counts and
/// deadlines stay deterministic.
@MainActor
protocol MonotonicClock {
    /// Seconds since an arbitrary fixed point. The value never decreases.
    func now() -> TimeInterval
}

@MainActor
struct SystemMonotonicClock: MonotonicClock {
    func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
}

/// A deterministic clock for policy tests.
@MainActor
final class ManualMonotonicClock: MonotonicClock {
    private(set) var time: TimeInterval

    init(time: TimeInterval = 0) {
        self.time = time
    }

    func now() -> TimeInterval { time }

    func advance(by interval: TimeInterval) {
        time += interval
    }
}

/// Suspension seam for retry and deadline policy. Tests substitute a sleeper
/// that advances a manual clock instead of waiting in real time.
@MainActor
protocol Sleeper {
    func sleep(for duration: Duration) async throws
}

@MainActor
struct TaskSleeper: Sleeper {
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

/// Product defaults for the complete native bridge invocation, including a JS
/// Promise that never settles. These are not Samply service guarantees, and REST
/// or storage transfer limits stay separate.
struct SamplyBridgeDeadlinePolicy: Equatable, Sendable {
    var status: Duration = .seconds(5)
    var interaction: Duration = .seconds(25)
    var transport: Duration = .seconds(10)

    func timeout(for command: String) -> Duration {
        switch command {
        case "snapshot", "runtimeSnapshot", "versions":
            status
        case "browse", "playBox", "refreshPage", "projectOwnership":
            interaction
        case "play", "pause", "toggle", "next", "previous", "seek", "volume", "quality":
            transport
        default:
            transport
        }
    }
}
