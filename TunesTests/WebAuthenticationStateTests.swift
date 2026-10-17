import Foundation
import Testing
@testable import Tunes

struct WebAuthenticationStateTests {
    private func snapshot(_ fields: String) throws -> WebSnapshot {
        let json = """
        {"version":1,"libraryReady":false,"library":[],"boxesReady":false,"boxes":[],"capabilities":[]\(fields)}
        """
        return try JSONDecoder().decode(WebSnapshot.self, from: Data(json.utf8))
    }

    @Test func missingAccountDoesNotMeanSignedOut() throws {
        #expect(try snapshot("").authenticationState == .checking)
        #expect(try snapshot(#", "authentication":"checking""#).authenticationState == .checking)
        #expect(try snapshot(#", "authentication":"signedIn""#).authenticationState == .checking)
    }

    @Test func resolvedIdentityDeterminesAuthentication() throws {
        #expect(try snapshot(#", "authentication":"signedOut""#).authenticationState == .signedOut)
        #expect(try snapshot(#", "account":{"uid":"fixture-user"}"#).authenticationState == .signedIn)
    }
}
