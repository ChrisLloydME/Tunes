import Foundation
import Testing
@testable import Tunes

@MainActor
struct SamplyProfileCacheTests {
    private func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "TunesProfileTests." + UUID().uuidString))
    }

    @Test func restoresDisplayMetadataBeforeAuthenticationAndClearsConfirmedSignOut() throws {
        let storage = try defaults()
        let cache = SamplyProfileCache(defaults: storage)
        let account = WebSnapshot.Account(uid: "fixture-user", name: "ChrisLloyd")
        cache.accept(account, authentication: .signedIn)
        let restored = SamplyProfileCache(defaults: storage)
        #expect(restored.account == account)
        restored.accept(nil, authentication: .checking)
        #expect(restored.account == account)
        restored.accept(nil, authentication: .signedOut)
        #expect(restored.account == nil)
        #expect(SamplyProfileCache(defaults: storage).account == nil)
    }

    @Test func avatarBytesRestoreAndAreDiscardedWhenAccountOrPictureChanges() throws {
        let storage = try defaults()
        let seed = #"{"account":{"uid":"a","name":"Artist","avatarURL":"https://example.test/a.png"},"avatarData":"AQID"}"#
        storage.set(Data(seed.utf8), forKey: "samply.profile.v1")
        let cache = SamplyProfileCache(defaults: storage)
        #expect(cache.avatarData == Data([1, 2, 3]))
        cache.accept(WebSnapshot.Account(uid: "b", name: "Other"), authentication: .signedIn)
        #expect(cache.avatarData == nil)
        #expect(SamplyProfileCache(defaults: storage).account?.uid == "b")
        cache.clear()
    }

    @Test func independentStorageDomainsDoNotShareProfiles() throws {
        let beta = try defaults(), release = try defaults()
        let cache = SamplyProfileCache(defaults: beta)
        cache.accept(WebSnapshot.Account(uid: "beta", name: "Beta"), authentication: .signedIn)
        #expect(SamplyProfileCache(defaults: release).account == nil)
        cache.clear()
    }

    @Test func defaultAvatarMatchesSamplyInitialsAndUIDHash() {
        #expect(WebSnapshot.Account(uid: "user-a", name: "ChrisLloyd").avatarInitials == "CH")
        #expect(WebSnapshot.Account(uid: "user-a", name: "Christopher Lloyd").avatarInitials == "CL")
        #expect(WebSnapshot.Account(uid: "user-a").avatarInitials == "")
        #expect(WebSnapshot.Account(uid: "user-a").avatarHue == 192.0 / 360)
    }
}
