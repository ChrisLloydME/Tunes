import Foundation

/// Leaves email-provider redirects and authentication parameters for the web session to handle.
enum SamplyEmailSignInLink {
    static func parse(_ input: String) throws -> URL {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, let url = URL(string: value) else { throw EmailSignInLinkError.invalidLink }
        return url
    }
}

enum EmailSignInLinkError: LocalizedError {
    case invalidLink, alreadyConnected, signingOut

    var errorDescription: String? {
        switch self {
        case .invalidLink:
            "The link could not be opened. Copy the full link from your email and try again."
        case .alreadyConnected:
            "You are already signed in to Samply. Sign out before switching accounts."
        case .signingOut:
            "Signing out. Please wait before opening a sign-in link."
        }
    }
}
