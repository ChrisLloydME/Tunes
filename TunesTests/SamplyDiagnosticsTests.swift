import Foundation
import Testing
@testable import Tunes

@MainActor
struct SamplyDiagnosticsTests {
    @Test func aggregatesUseFixedBucketsAndArithmetic() {
        let diagnostics = SamplyDiagnostics(isEnabled: true)
        #expect(diagnostics.nextOperationID() == 1)
        #expect(diagnostics.nextOperationID() == 2)
        diagnostics.record(SamplyDiagnosticSample(
            stage: .bridgeInvocation, command: .snapshot, operationID: 1,
            duration: 0.5, responseBytes: 120, itemCount: 3, attemptCount: 1))
        diagnostics.record(SamplyDiagnosticSample(
            stage: .bridgeInvocation, command: .snapshot, operationID: 2,
            duration: 1.5, responseBytes: 80, itemCount: 5, attemptCount: 2))
        let aggregate = diagnostics.aggregate(stage: .bridgeInvocation)
        #expect(aggregate?.count == 2)
        #expect(aggregate?.responseBytes == 200)
        #expect(aggregate?.itemCount == 8)
        #expect(aggregate?.attempts == 3)
        #expect(aggregate?.averageDuration == 1)
        #expect(aggregate?.maximumDuration == 1.5)
    }

    @Test func disabledDiagnosticsRetainNothing() {
        let diagnostics = SamplyDiagnostics(isEnabled: false)
        for _ in 0..<50 {
            diagnostics.record(SamplyDiagnosticSample(stage: .artworkTransfer,
                                                      command: .artwork, operationID: 1,
                                                      responseBytes: 4_096))
        }
        #expect(diagnostics.trackedBucketCount == 0)
        #expect(diagnostics.recordCount(stage: .artworkTransfer) == 0)
    }

    @Test func bucketCountStaysBoundedUnderRepeatedSamples() {
        let diagnostics = SamplyDiagnostics(isEnabled: true)
        let visibleStages = SamplyDiagnosticStage.allCases
        let outcomes = SamplyDiagnosticOutcome.allCases
        for index in 0..<2_000 {
            diagnostics.record(SamplyDiagnosticSample(
                stage: visibleStages[index % visibleStages.count],
                command: SamplyDiagnosticCommand.allCases[index % SamplyDiagnosticCommand.allCases.count],
                operationID: UInt64(index),
                duration: Double(index % 7) / 10,
                responseBytes: index % 1_024,
                itemCount: index % 11,
                attemptCount: index % 3 + 1,
                outcome: outcomes[index % outcomes.count]))
        }
        #expect(diagnostics.trackedBucketCount <= visibleStages.count * outcomes.count)
        #expect(diagnostics.recordCount(stage: .bridgeInvocation) > 0)
    }

    @Test func errorsMapToFixedOutcomes() {
        #expect(SamplyDiagnosticOutcome(SamplyBridgeError.notReady) == .notReady)
        #expect(SamplyDiagnosticOutcome(SamplyBridgeError.contractMismatch) == .contractMismatch)
        #expect(SamplyDiagnosticOutcome(SamplyBridgeError.accessDenied) == .accessDenied)
        #expect(SamplyDiagnosticOutcome(SamplyBridgeError.superseded) == .superseded)
        #expect(SamplyDiagnosticOutcome(SamplyBridgeError.timedOut) == .timedOut)
        #expect(SamplyDiagnosticOutcome(SamplyBridgeError.executionFailed) == .failure)
        #expect(SamplyDiagnosticOutcome(SamplyBridgeError.operationFailed) == .failure)
        #expect(SamplyDiagnosticOutcome(CancellationError()) == .cancelled)
        #expect(SamplyDiagnosticOutcome(SamplyError.invalidResponse) == .failure)
    }

    @Test func unknownCommandNamesAreNotRecordedAsText() {
        // The initializer only accepts the fixed allowlist; arbitrary page text
        // therefore cannot become a diagnostics key.
        #expect(SamplyDiagnosticCommand(command: "snapshot") == .snapshot)
        #expect(SamplyDiagnosticCommand(command: "https://samply.app/secret") == nil)
        #expect(SamplyDiagnosticCommand(command: "account-user-a") == nil)
    }
}
