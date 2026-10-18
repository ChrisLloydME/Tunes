import Foundation
import Testing
@testable import Tunes

@MainActor
struct SamplySessionHistoryTests {
    private func storage() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "TunesSessionHistoryTests." + UUID().uuidString))
    }

    @Test func confirmedSignOutSkipsRestorationAfterRestart() throws {
        let defaults = try storage()
        SamplySessionHistory(defaults: defaults).accept(.signedOut)
        let restarted = SamplySessionHistory(defaults: defaults)
        #expect(restarted.initialAuthenticationState == .signedOut)
        #expect(restarted.wasSignedIn == false)
        #expect(!restarted.shouldRestoreLegacySession(hasWebsiteData: true))
    }

    @Test func rememberedSignInRequiresWebVerificationAfterRestart() throws {
        let defaults = try storage()
        SamplySessionHistory(defaults: defaults).accept(.signedIn)
        let restarted = SamplySessionHistory(defaults: defaults)
        #expect(restarted.wasSignedIn == true)
        #expect(restarted.initialAuthenticationState == .checking)
    }

    @Test func unresolvedSnapshotsDoNotOverwriteRememberedState() throws {
        let defaults = try storage()
        let history = SamplySessionHistory(defaults: defaults)
        history.accept(.signedIn)
        history.accept(.checking)
        #expect(SamplySessionHistory(defaults: defaults).wasSignedIn == true)
        history.accept(.signedOut)
        history.accept(.checking)
        #expect(SamplySessionHistory(defaults: defaults).wasSignedIn == false)
    }

    @Test func freshWebStoreSkipsNetworkRestorationAndRemembersSignOut() throws {
        let defaults = try storage()
        let history = SamplySessionHistory(defaults: defaults)
        #expect(history.wasSignedIn == nil)
        #expect(!history.shouldRestoreLegacySession(hasWebsiteData: false))
        #expect(SamplySessionHistory(defaults: defaults).initialAuthenticationState == .signedOut)
    }

    @Test func legacyWebStoreGetsAChanceToRestoreWithoutAssumingAuthentication() throws {
        let history = SamplySessionHistory(defaults: try storage())
        #expect(history.shouldRestoreLegacySession(hasWebsiteData: true))
        #expect(history.wasSignedIn == nil)
        #expect(history.initialAuthenticationState == .checking)
    }

    @Test func expiredSessionReturnsToSignInOnNextLaunch() throws {
        let defaults = try storage()
        let history = SamplySessionHistory(defaults: defaults)
        history.accept(.signedIn)
        history.accept(.signedOut)
        #expect(SamplySessionHistory(defaults: defaults).initialAuthenticationState == .signedOut)
    }

    @Test func independentBuildDomainsDoNotShareStartupHints() throws {
        let beta = try storage(), release = try storage()
        SamplySessionHistory(defaults: beta).accept(.signedOut)
        #expect(SamplySessionHistory(defaults: release).wasSignedIn == nil)
        SamplySessionHistory(defaults: release).accept(.signedIn)
        #expect(SamplySessionHistory(defaults: beta).wasSignedIn == false)
    }
}
