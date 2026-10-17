import Foundation

/// Session-only credentials. This app does not read, write, or delete Keychain items.
@MainActor
protocol TokenStore {
    func read() throws -> String?
    func save(_ token: String) throws
    func remove() throws
}

@MainActor
final class MemoryTokenStore: TokenStore {
    private var token: String?
    func read() throws -> String? { token }
    func save(_ token: String) throws { self.token = token }
    func remove() throws { token = nil }
}
