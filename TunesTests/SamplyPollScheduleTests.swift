import Foundation
import Testing
@testable import Tunes

@MainActor
struct SamplyPollScheduleTests {
    private func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) +
            Double(duration.components.attoseconds) / 1_000_000_000_000_000_000
    }

    @Test func healthyMinuteStaysWithinTheFullReadCapAndKeepsRuntimeCadence() {
        var schedule = SamplyPollSchedule()
        var nowMilliseconds = 0
        var fullReads = 0
        var runtimePolls = 0
        while nowMilliseconds < 60_000 {
            let now = Double(nowMilliseconds) / 1_000
            runtimePolls += 1
            if schedule.shouldReadFullContent(at: now) {
                fullReads += 1
                schedule.recordFullRead(at: now, succeeded: true,
                                        generation: schedule.invalidationGeneration)
            }
            let delay = seconds(schedule.nextPollDelay(at: now))
            #expect(delay > 0 || schedule.shouldReadFullContent(at: now))
            nowMilliseconds += max(1, Int((delay * 1_000).rounded()))
        }
        #expect(fullReads == 29)
        #expect(fullReads <= 29)
        #expect(runtimePolls >= 80)
    }

    @Test func repeatedInvalidationsMergeIntoOneFollowUpRead() {
        var schedule = SamplyPollSchedule()
        schedule.recordFullRead(at: 0, succeeded: true,
                                generation: schedule.invalidationGeneration)
        #expect(!schedule.shouldReadFullContent(at: 0.7))

        for _ in 0..<100 { schedule.markFullContentNeeded() }
        #expect(schedule.shouldReadFullContent(at: 0.8))
        schedule.recordFullRead(at: 0.8, succeeded: true,
                                generation: schedule.invalidationGeneration)
        #expect(!schedule.shouldReadFullContent(at: 0.9))
        #expect(schedule.shouldReadFullContent(at: 0.8 + 2.1))
    }

    @Test func invalidationDuringAReadSurvivesThatReadsSuccess() {
        var schedule = SamplyPollSchedule()
        schedule.recordFullRead(at: 0, succeeded: true,
                                generation: schedule.invalidationGeneration)
        let generation = schedule.invalidationGeneration
        schedule.markFullContentNeeded()
        schedule.recordFullRead(at: 0.5, succeeded: true, generation: generation)
        // The result predates the newer invalidation, so another read is due.
        #expect(schedule.shouldReadFullContent(at: 0.6))
    }

    @Test func failedFullReadsBackOffInsteadOfLooping() {
        var schedule = SamplyPollSchedule()
        schedule.recordFullRead(at: 0, succeeded: false,
                                generation: schedule.invalidationGeneration)
        #expect(!schedule.shouldReadFullContent(at: 0.7))
        #expect(!schedule.shouldReadFullContent(at: 2.0))
        #expect(schedule.shouldReadFullContent(at: 2.1))
        // Runtime sampling still gets a normal delay while the full read waits.
        #expect(seconds(schedule.nextPollDelay(at: 0.7)) == 0.7)
    }

    @Test func metadataIsAcceptedByTheNextFullReadDeadline() {
        var schedule = SamplyPollSchedule()
        schedule.recordFullRead(at: 0, succeeded: true,
                                generation: schedule.invalidationGeneration)
        // A change immediately after a full read must be picked up at 2.1 s,
        // which stays inside the 2.8 s healthy acceptance bound.
        #expect(!schedule.shouldReadFullContent(at: 2.09))
        #expect(schedule.shouldReadFullContent(at: 2.1))
        #expect(2.1 <= 2.8)
    }

    @Test func interactiveCommandsDelayFullReadsButNotRuntimeSamples() {
        var schedule = SamplyPollSchedule()
        #expect(!schedule.shouldReadFullContent(at: 10, interactive: true))
        #expect(seconds(schedule.nextPollDelay(at: 10, interactive: true)) == 0.7)
        #expect(schedule.shouldReadFullContent(at: 10, interactive: false))
    }
}
