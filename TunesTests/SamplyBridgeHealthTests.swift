import Testing
@testable import Tunes

struct SamplyBridgeHealthTests {
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
