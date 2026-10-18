import Foundation

enum SamplyError: LocalizedError {
    case noToken, noAccount, invalidToken, invalidIdentifier, invalidResponse, insecureURL
    case http(Int, retryAfter: TimeInterval?)
    case bridgeUnavailable, webContract(String), timedOut, fileChanged

    var errorDescription: String? {
        switch self {
        case .noToken: "Add a Samply Personal Access Token in Connection Settings first."
        case .noAccount: "Sign in to Samply before saving an upload token."
        case .invalidToken: "Your token is invalid or expired. Update it in Connection Settings."
        case .invalidIdentifier: "Invalid Samply resource ID."
        case .invalidResponse: "Samply returned an unexpected response."
        case .insecureURL: "The server did not return a valid HTTPS address."
        case .http(let code, _):
            switch code {
            case 403: "Samply denied this operation. Check your account permissions."
            case 404: "This resource could not be found in Samply."
            case 429: "Too many requests to Samply. Please try again later."
            default: "Samply request failed (HTTP \(code))."
            }
        case .bridgeUnavailable: "Open the Samply sign-in window and wait for the page to load."
        case .webContract(let detail): "Samply web integration unavailable: \(detail)"
        case .timedOut: "Samply timed out. Open the Samply window to check your sign-in and access permissions."
        case .fileChanged: "The file has changed or cannot be read. Please select it again."
        }
    }
}
