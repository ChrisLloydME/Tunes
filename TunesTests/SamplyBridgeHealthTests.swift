import Testing
@testable import Tunes

struct SamplyBridgeHealthTests {
    @Test func pollingAcceleratesDuringShortFailuresAndReturnsToNormalAfterRecovery() {
        var health = SamplyBridgeHealth()
        #expect(health.pollInterval(at: 100) == .milliseconds(700))
        _ = health.recordFailure(at: 100)
        #expect(health.pollInterval(at: 100) == .milliseconds(250))
        #expect(health.pollInterval(at: 109.9) == .milliseconds(250))
        #expect(health.pollInterval(at: 110) == .milliseconds(700))
        health.reset()
        #expect(health.pollInterval(at: 111) == .milliseconds(700))
    }

    @Test func rejectedActionsAreNotAutomaticallyRetried() {
        #expect(SamplyBridgeError.notReady.isTransient)
        #expect(SamplyBridgeError.executionFailed.isTransient)
        #expect(!SamplyBridgeError.operationFailed.isTransient)
    }

    @Test func briefFailuresStayQuietButPersistentFailuresSurface() {
        var health = SamplyBridgeHealth()
        for (time, expected) in [(100.0, false), (100.7, false), (104.9, false), (105.0, true), (106.0, true)] {
            let surfaced = health.recordFailure(at: time)
            #expect(surfaced == expected)
        }
    }

    @Test func recoveryAndNavigationStartANewGracePeriod() {
        var health = SamplyBridgeHealth()
        _ = health.recordFailure(at: 100)
        let sustained = health.recordFailure(at: 105)
        #expect(sustained)
        health.reset()
        for (time, expected) in [(120.0, false), (124.9, false), (125.0, true)] {
            let surfaced = health.recordFailure(at: time)
            #expect(surfaced == expected)
        }
    }
}
