import Foundation
import Testing
@testable import Tunes

struct SamplyReadRecoveryPolicyTests {
    @Test func attemptsUseTheApprovedDelaysWithBoundedJitter() {
        let policy = SamplyReadRecoveryPolicy()
        #expect(policy.maximumAttempts == 3)
        #expect(policy.delay(forAttempt: 0, randomValue: 0.5) == 0.5)
        #expect(policy.delay(forAttempt: 1, randomValue: 0.5) == 1)
        #expect(policy.delay(forAttempt: 2, randomValue: 0.5) == 2)
        #expect(policy.delay(forAttempt: 0, randomValue: 0) >= 0.425)
        #expect(policy.delay(forAttempt: 0, randomValue: 1) <= 0.575)
        #expect(policy.delay(forAttempt: 2, randomValue: 0) >= 1.7)
        #expect(policy.delay(forAttempt: 2, randomValue: 1) <= 2.3)
    }

    @Test func onlyTransientReadFailuresAreRetried() {
        let policy = SamplyReadRecoveryPolicy()
        #expect(policy.shouldRetry(SamplyBridgeError.notReady))
        #expect(policy.shouldRetry(SamplyBridgeError.timedOut))
        #expect(policy.shouldRetry(SamplyBridgeError.executionFailed))
        #expect(!policy.shouldRetry(SamplyBridgeError.contractMismatch))
        #expect(!policy.shouldRetry(SamplyBridgeError.accessDenied))
        #expect(!policy.shouldRetry(SamplyBridgeError.superseded))
        #expect(!policy.shouldRetry(SamplyBridgeError.operationFailed))
        #expect(!policy.shouldRetry(CancellationError()))
        #expect(policy.shouldRetry(SamplyError.invalidResponse))
        #expect(!policy.shouldRetry(SamplyError.bridgeUnavailable))
        #expect(policy.shouldRetry(SamplyError.http(503, retryAfter: nil)))
        #expect(!policy.shouldRetry(SamplyError.http(403, retryAfter: nil)))
    }
}
