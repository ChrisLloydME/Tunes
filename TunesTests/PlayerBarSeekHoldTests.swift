import Foundation
import Testing
@testable import Tunes

struct PlayerBarSeekHoldTests {
    @Test func delayedPlaybackSnapshotDoesNotUndoTheUsersSeek() {
        var hold = PlayerBarSeekHold()
        let issued = Date(timeIntervalSince1970: 100)
        hold.begin(target: 90, issuedAt: issued)
        hold.reconcile(observedProgress: 12, now: issued.addingTimeInterval(0.7))
        #expect(hold.displayProgress(observedProgress: 12) == 90)

        hold.reconcile(observedProgress: 90.4, now: issued.addingTimeInterval(1))
        #expect(!hold.isActive)
        #expect(hold.displayProgress(observedProgress: 90.4) == 90.4)
    }

    @Test func anEarlierTimeoutCannotClearANewerSeek() {
        var hold = PlayerBarSeekHold()
        let first = hold.begin(target: 30)
        let second = hold.begin(target: 90)
        let clearedByOldTimeout = hold.clearIfCurrent(first)
        #expect(!clearedByOldTimeout)
        #expect(hold.targetProgress == 90)
        let clearedByCurrentTimeout = hold.clearIfCurrent(second)
        #expect(clearedByCurrentTimeout)
        #expect(!hold.isActive)
    }

    @Test func failedSeekEventuallyReturnsToReportedPlaybackAndTrackChangeClearsIt() {
        var hold = PlayerBarSeekHold()
        let issued = Date(timeIntervalSince1970: 100)
        hold.begin(target: 90, issuedAt: issued)
        hold.reconcile(observedProgress: 14, now: issued.addingTimeInterval(3))
        #expect(!hold.isActive)
        #expect(hold.displayProgress(observedProgress: 14) == 14)

        hold.begin(target: 90)
        hold.clear()
        #expect(hold.displayProgress(observedProgress: 0) == 0)
    }
}
