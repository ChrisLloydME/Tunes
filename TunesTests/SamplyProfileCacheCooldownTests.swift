import AppKit
import Foundation
import Testing
@testable import Tunes

@MainActor
struct SamplyProfileCacheCooldownTests {
    private let avatarURL = "https://example.test/avatar.png"
    private let avatarAccount = WebSnapshot.Account(uid: "fixture-user", name: "Fixture",
                                                    avatarURL: "https://example.test/avatar.png")

    private func waitUntil(_ condition: () -> Bool, _ message: String) async {
        for _ in 0..<1_000 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record(Comment(rawValue: message))
    }

    private func makeCache() throws -> (SamplyProfileCache, ControllableArtworkLoader,
                                        ManualMonotonicClock, UserDefaults) {
        let defaults = try #require(UserDefaults(suiteName: "TunesAvatarCooldown." + UUID().uuidString))
        let clock = ManualMonotonicClock(time: 1_000)
        let loader = ControllableArtworkLoader()
        let cache = SamplyProfileCache(defaults: defaults, clock: clock, loader: loader)
        return (cache, loader, clock, defaults)
    }

    private func failNext(_ loader: ControllableArtworkLoader, at index: Int) async {
        loader.fail(index, with: URLError(.timedOut))
    }

    @Test func repeatedFailuresFollowFiveFifteenSixtySecondCooldowns() async throws {
        let (cache, loader, clock, _) = try makeCache()
        var account = avatarAccount
        account.avatarURL = avatarURL

        cache.accept(account, authentication: .signedIn)
        await waitUntil({ loader.requests.count == 1 }, "the first avatar request did not start")
        #expect(loader.requests[0].maxBytes == 2 * 1024 * 1024)
        await failNext(loader, at: 0)
        await waitUntil({ !cache.isDownloadingAvatar }, "the first failure did not settle")

        cache.accept(account, authentication: .signedIn)
        await Task.yield()
        #expect(loader.requests.count == 1)
        clock.advance(by: 4.9)
        cache.accept(account, authentication: .signedIn)
        await Task.yield()
        #expect(loader.requests.count == 1)
        clock.advance(by: 0.2)
        cache.accept(account, authentication: .signedIn)
        await waitUntil({ loader.requests.count == 2 }, "the 5 s cooldown did not expire")
        await failNext(loader, at: 1)
        await waitUntil({ !cache.isDownloadingAvatar }, "the second failure did not settle")

        clock.advance(by: 14.9)
        cache.accept(account, authentication: .signedIn)
        await Task.yield()
        #expect(loader.requests.count == 2)
        clock.advance(by: 0.2)
        cache.accept(account, authentication: .signedIn)
        await waitUntil({ loader.requests.count == 3 }, "the 15 s cooldown did not expire")
        await failNext(loader, at: 2)
        await waitUntil({ !cache.isDownloadingAvatar }, "the third failure did not settle")

        clock.advance(by: 59.9)
        cache.accept(account, authentication: .signedIn)
        await Task.yield()
        #expect(loader.requests.count == 3)
        clock.advance(by: 0.2)
        cache.accept(account, authentication: .signedIn)
        await waitUntil({ loader.requests.count == 4 }, "the 60 s cooldown did not expire")
    }

    @Test func successResetsTheFailureSchedule() async throws {
        let (cache, loader, clock, _) = try makeCache()
        cache.accept(avatarAccount, authentication: .signedIn)
        await waitUntil({ loader.requests.count == 1 }, "the first avatar request did not start")
        await failNext(loader, at: 0)
        await waitUntil({ !cache.isDownloadingAvatar }, "the first failure did not settle")

        clock.advance(by: 5)
        cache.accept(avatarAccount, authentication: .signedIn)
        await waitUntil({ loader.requests.count == 2 }, "the retry did not start")
        loader.complete(1, with: testArtworkPNG(width: 8, height: 8))
        await waitUntil({ cache.avatarData != nil }, "the successful avatar was not accepted")

        var changed = avatarAccount
        changed.avatarURL = "https://example.test/avatar-2.png"
        cache.accept(changed, authentication: .signedIn)
        await waitUntil({ loader.requests.count == 3 }, "the changed avatar did not load")
        await failNext(loader, at: 2)
        await waitUntil({ !cache.isDownloadingAvatar }, "the new failure did not settle")

        clock.advance(by: 4.9)
        cache.accept(changed, authentication: .signedIn)
        await Task.yield()
        #expect(loader.requests.count == 3)
        clock.advance(by: 0.2)
        cache.accept(changed, authentication: .signedIn)
        await waitUntil({ loader.requests.count == 4 }, "the cooldown was not reset to 5 s")
    }

    @Test func accountOrURLClearResetsCooldownImmediately() async throws {
        let (cache, loader, _, _) = try makeCache()
        cache.accept(avatarAccount, authentication: .signedIn)
        await waitUntil({ loader.requests.count == 1 }, "the first avatar request did not start")
        await failNext(loader, at: 0)
        await waitUntil({ !cache.isDownloadingAvatar }, "the failure did not settle")

        var changedURL = avatarAccount
        changedURL.avatarURL = "https://example.test/other.png"
        cache.accept(changedURL, authentication: .signedIn)
        await waitUntil({ loader.requests.count == 2 }, "a URL change did not reset the cooldown")
        await failNext(loader, at: 1)
        await waitUntil({ !cache.isDownloadingAvatar }, "the second failure did not settle")

        let otherAccount = WebSnapshot.Account(uid: "other-user", name: "Other",
                                               avatarURL: "https://example.test/other.png")
        cache.accept(otherAccount, authentication: .signedIn)
        await waitUntil({ loader.requests.count == 3 }, "an account change did not reset the cooldown")
    }

    @Test func signOutClearsCooldownAndPendingWork() async throws {
        let (cache, loader, _, _) = try makeCache()
        cache.accept(avatarAccount, authentication: .signedIn)
        await waitUntil({ loader.requests.count == 1 }, "the first avatar request did not start")
        await failNext(loader, at: 0)
        await waitUntil({ !cache.isDownloadingAvatar }, "the failure did not settle")

        cache.accept(nil, authentication: .signedOut)
        #expect(cache.account == nil)

        cache.accept(avatarAccount, authentication: .signedIn)
        await waitUntil({ loader.requests.count == 2 }, "sign-out did not clear the cooldown")
    }

    @Test func malformedAvatarDataCountsAsAFailure() async throws {
        let (cache, loader, clock, _) = try makeCache()
        cache.accept(avatarAccount, authentication: .signedIn)
        await waitUntil({ loader.requests.count == 1 }, "the avatar request did not start")
        loader.complete(0, with: Data("not an image".utf8))
        await waitUntil({ !cache.isDownloadingAvatar }, "malformed data did not settle")
        #expect(cache.avatarData == nil)

        cache.accept(avatarAccount, authentication: .signedIn)
        await Task.yield()
        #expect(loader.requests.count == 1)
        clock.advance(by: 5)
        cache.accept(avatarAccount, authentication: .signedIn)
        await waitUntil({ loader.requests.count == 2 }, "malformed data did not start a cooldown")
    }
}
