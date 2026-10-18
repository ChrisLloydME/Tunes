import Foundation

/// A startup hint only. Samply must still verify every restored web session.
@MainActor
final class SamplySessionHistory {
    private let defaults: UserDefaults?
    private static let key = "samply.session.wasSignedIn.v1"
    private(set) var wasSignedIn: Bool?

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        wasSignedIn = defaults?.object(forKey: Self.key) as? Bool
    }

    var initialAuthenticationState: WebAuthenticationState {
        wasSignedIn == false ? .signedOut : .checking
    }

    func accept(_ state: WebAuthenticationState) {
        guard state != .checking else { return }
        let signedIn = state == .signedIn
        guard wasSignedIn != signedIn else { return }
        wasSignedIn = signedIn
        defaults?.set(signedIn, forKey: Self.key)
    }

    func shouldRestoreLegacySession(hasWebsiteData: Bool) -> Bool {
        if let wasSignedIn { return wasSignedIn }
        if !hasWebsiteData { accept(.signedOut) }
        return hasWebsiteData
    }
}
