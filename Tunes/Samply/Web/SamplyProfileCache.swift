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
    @ObservationIgnored private var download: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    private static let key = "samply.profile.v1"

    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        if let data = defaults?.data(forKey: Self.key),
           let record = try? JSONDecoder().decode(Record.self, from: data) {
            account = record.account
            avatarData = record.avatarData
        }
    }

    func accept(_ account: WebSnapshot.Account?, authentication: WebAuthenticationState) {
        if authentication == .signedOut { clear(); return }
        guard let account else { return }
        let changed = self.account?.uid != account.uid || self.account?.avatarURL != account.avatarURL
        if changed {
            generation += 1
            download?.cancel()
            download = nil
            avatarData = nil
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
        let stamp = generation
        download = Task { [weak self] in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            let session = URLSession(configuration: configuration)
            defer { session.finishTasksAndInvalidate() }
            do {
                let (data, response) = try await session.data(from: url)
                guard !Task.isCancelled, let self, self.generation == stamp else { return }
                self.download = nil
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      data.count <= 2 * 1024 * 1024, NSImage(data: data) != nil else { return }
                self.avatarData = data
                self.save()
            } catch {
                guard let self, self.generation == stamp else { return }
                self.download = nil
            }
        }
    }

    func clear() {
        generation += 1
        download?.cancel()
        download = nil
        account = nil
        avatarData = nil
        defaults?.removeObject(forKey: Self.key)
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
