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

    @Test func loadingTraceKeepsOperationAndStageCorrelation() {
        let trace = SamplyLoadingTraceRecorder(isEnabled: true)
        #expect(trace.beginOperation(id: 1, command: .refreshPage))
        #expect(trace.record(stage: .bridgeStarted, operationID: 1,
                             elapsed: 0.01, duration: 0.02))
        #expect(trace.beginOperation(id: 2, command: .snapshot))
        #expect(trace.record(stage: .payloadDecoded, operationID: 2,
                             elapsed: 0.05, duration: 0.03,
                             itemCount: 3, responseBytes: 120))

        let first = trace.operation(id: 1)
        let second = trace.operation(id: 2)
        #expect(first?.command == .refreshPage)
        #expect(first?.stages.count == 1)
        #expect(first?.stages.first?.stage == .bridgeStarted)
        #expect(second?.command == .snapshot)
        #expect(second?.stages.first?.itemCount == 3)
        #expect(second?.stages.first?.responseBytes == 120)
        #expect(trace.trackedOperationCount == 2)
    }

    @Test func loadingTraceEvictsOldestOperationsAtTheBound() {
        let trace = SamplyLoadingTraceRecorder(isEnabled: true)
        for id in 1...200 {
            #expect(trace.beginOperation(id: UInt64(id), command: .snapshot))
            #expect(trace.record(stage: .requested, operationID: UInt64(id),
                                 elapsed: 0, duration: 0.01))
        }
        #expect(trace.trackedOperationCount == SamplyLoadingTraceRecorder.maxOperations)
        #expect(trace.operation(id: 1) == nil)
        #expect(trace.operation(id: 73) != nil)
        #expect(trace.operations.first?.id == 73)
        #expect(trace.operations.last?.id == 200)

        // A late stage for an evicted operation recreates a bounded record
        // rather than growing the history.
        #expect(trace.record(stage: .published, operationID: 1,
                             elapsed: 0.1, duration: 0.1))
        #expect(trace.trackedOperationCount == SamplyLoadingTraceRecorder.maxOperations)
        #expect(trace.operations.first?.id == 74)
        #expect(trace.operations.last?.id == 1)
    }

    @Test func loadingTraceBoundsStagesPerOperation() {
        let trace = SamplyLoadingTraceRecorder(isEnabled: true)
        _ = trace.beginOperation(id: 7, command: .browse)
        let stages = SamplyLoadingTraceStage.allCases
        for index in 0..<20 {
            let accepted = trace.record(stage: stages[index % stages.count],
                                        operationID: 7, elapsed: Double(index),
                                        duration: 0.1)
            #expect(accepted == (index < SamplyLoadingTraceRecorder.maxStagesPerOperation))
        }
        #expect(trace.operation(id: 7)?.stages.count ==
                SamplyLoadingTraceRecorder.maxStagesPerOperation)
    }

    @Test func disabledLoadingTraceRetainsNothing() {
        let trace = SamplyLoadingTraceRecorder(isEnabled: false)
        #expect(!trace.beginOperation(id: 1, command: .snapshot))
        #expect(!trace.record(stage: .requested, operationID: 1,
                              elapsed: 0, duration: 0))
        #expect(trace.operations.isEmpty)
        #expect(trace.developerDescription == "Loading trace disabled.")

        let diagnostics = SamplyDiagnostics(isEnabled: false)
        #expect(!diagnostics.loadingTrace.isEnabled)
    }

    @Test func loadingTraceDescriptionIsSanitized() {
        let trace = SamplyLoadingTraceRecorder(isEnabled: true)
        _ = trace.beginOperation(id: 1, command: .browse)
        _ = trace.record(stage: .bridgeStarted, operationID: 1,
                         elapsed: 0.123, duration: 0.456,
                         itemCount: 7, responseBytes: 42)
        _ = trace.record(stage: .routerSettled, operationID: 1,
                         elapsed: 0.5, duration: 0.1, outcome: .failure)
        let output = trace.developerDescription
        #expect(output.contains("operation 1 command=browse"))
        #expect(output.contains(
            "bridgeStarted elapsed=0.123s duration=0.456s count=7 bytes=42 outcome=success"))
        for forbidden in ["http", "samply.app", "token", "account", "fixture"] {
            #expect(!output.contains(forbidden))
        }
    }

    @Test func diagnosticsResetClearsTheLoadingTrace() {
        let diagnostics = SamplyDiagnostics(isEnabled: true)
        _ = diagnostics.loadingTrace.beginOperation(id: 1, command: .snapshot)
        _ = diagnostics.loadingTrace.record(stage: .requested, operationID: 1,
                                            elapsed: 0, duration: 0)
        diagnostics.reset()
        #expect(diagnostics.loadingTrace.trackedOperationCount == 0)
        #expect(diagnostics.nextOperationID() == 1)
    }

    @Test func unknownCommandNamesAreNotRecordedAsText() {
        // The initializer only accepts the fixed allowlist; arbitrary page text
        // therefore cannot become a diagnostics key.
        #expect(SamplyDiagnosticCommand(command: "snapshot") == .snapshot)
        #expect(SamplyDiagnosticCommand(command: "https://samply.app/secret") == nil)
        #expect(SamplyDiagnosticCommand(command: "account-user-a") == nil)
    }
}
