import AppKit
import Foundation
import Observation

/// Display metadata only. A cached profile never establishes an authenticated session.
@MainActor
@Observable
final class SamplyProfileCache {
    private struct Record: Codable {
        var account: WebSnapshot.Account
        var avatarData: Data?
    }

    private(set) var account: WebSnapshot.Account?
    private(set) var avatarData: Data?
    /// Acceptance counter for focused tests; display state remains the source of truth.
    @ObservationIgnored private(set) var accountAssignmentCount = 0
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let clock: any MonotonicClock
    @ObservationIgnored private let loader: any BoundedDataLoading
    @ObservationIgnored private var download: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var avatarFailureCount = 0
    @ObservationIgnored private var nextAvatarAttemptAt: TimeInterval?
    @ObservationIgnored private var failedAvatarURL: String?
    @ObservationIgnored private var failedAvatarUID: String?
    private static let key = "samply.profile.v1"
    private static let maximumAvatarBytes = 2 * 1024 * 1024
    private static let avatarFailureDelays: [TimeInterval] = [5, 15, 60]

    init(defaults: UserDefaults? = .standard,
         clock: (any MonotonicClock)? = nil,
         loader: (any BoundedDataLoading)? = nil) {
        self.defaults = defaults
        self.clock = clock ?? SystemMonotonicClock()
        self.loader = loader ?? BoundedHTTPDataLoader()
        if let data = defaults?.data(forKey: Self.key),
           let record = try? JSONDecoder().decode(Record.self, from: data) {
            account = record.account
            avatarData = record.avatarData
        }
    }

    var isDownloadingAvatar: Bool { download != nil }

    func accept(_ account: WebSnapshot.Account?, authentication: WebAuthenticationState) {
        if authentication == .signedOut { clear(); return }
        guard let account else { return }
        let changed = self.account?.uid != account.uid || self.account?.avatarURL != account.avatarURL
        if changed {
            generation += 1
            download?.cancel()
            download = nil
            avatarData = nil
            resetAvatarFailure()
        }
        let metadataChanged = self.account != account
        if metadataChanged {
            self.account = account
            accountAssignmentCount &+= 1
            save()
        }
        guard avatarData == nil, download == nil,
              let value = account.avatarURL, let url = URL(string: value),
              url.scheme?.lowercased() == "https" else { return }
        if failedAvatarURL == value, failedAvatarUID == account.uid,
           let nextAvatarAttemptAt, clock.now() < nextAvatarAttemptAt {
            return
        }
        let stamp = generation
        let uid = account.uid
        download = Task { [weak self] in
            guard let self else { return }
            do {
                let data = try await self.loader.data(from: url,
                                                      maxBytes: Self.maximumAvatarBytes)
                guard !Task.isCancelled, self.generation == stamp,
                      self.account?.uid == uid else { return }
                self.download = nil
                guard NSImage(data: data) != nil else {
                    self.recordAvatarFailure(url: value, uid: uid)
                    return
                }
                self.avatarData = data
                self.resetAvatarFailure()
                self.save()
            } catch {
                guard !Task.isCancelled, self.generation == stamp else { return }
                self.download = nil
                if !(error is CancellationError) {
                    self.recordAvatarFailure(url: value, uid: uid)
                }
            }
        }
    }

    func clear() {
        generation += 1
        download?.cancel()
        download = nil
        account = nil
        avatarData = nil
        resetAvatarFailure()
        defaults?.removeObject(forKey: Self.key)
    }

    private func recordAvatarFailure(url: String, uid: String) {
        if failedAvatarURL != url || failedAvatarUID != uid {
            avatarFailureCount = 0
        }
        failedAvatarURL = url
        failedAvatarUID = uid
        let delay = Self.avatarFailureDelays[
            min(avatarFailureCount, Self.avatarFailureDelays.count - 1)]
        avatarFailureCount += 1
        nextAvatarAttemptAt = clock.now() + delay
    }

    private func resetAvatarFailure() {
        avatarFailureCount = 0
        nextAvatarAttemptAt = nil
        failedAvatarURL = nil
        failedAvatarUID = nil
    }

    private func save() {
        guard let account,
              let data = try? JSONEncoder().encode(Record(account: account, avatarData: avatarData)) else { return }
        defaults?.set(data, forKey: Self.key)
    }
}

extension WebSnapshot.Account {
    var avatarInitials: String {
        let parts = (name ?? "").split(separator: " ")
        guard let first = parts.first else { return "" }
        if parts.count > 1, let last = parts.last {
            return (String(first.prefix(1)) + String(last.prefix(1))).uppercased()
        }
        return String(first.prefix(2)).uppercased()
    }

    var avatarHue: Double {
        var hash: UInt32 = 5381
        for unit in uid.utf16.reversed() { hash = (hash &* 33) ^ UInt32(unit) }
        return Double(hash % 360) / 360
    }
}
