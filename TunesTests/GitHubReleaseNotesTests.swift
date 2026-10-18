import Foundation
import Testing
@testable import Tunes

@MainActor
@Suite(.serialized)
struct GitHubReleaseNotesTests {
    private func client(status: Int = 200, body: String) -> GitHubReleaseNotesClient {
        ReleaseNotesURLProtocol.status = status
        ReleaseNotesURLProtocol.body = body
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReleaseNotesURLProtocol.self]
        return GitHubReleaseNotesClient(session: URLSession(configuration: configuration))
    }

    @Test func requestsPublicTunesReleasesWithoutSamplyCredentials() async throws {
        let releases = try await client(body: "[]").fetchReleases()
        #expect(releases.isEmpty)
        let request = try #require(ReleaseNotesURLProtocol.request)
        #expect(request.url?.absoluteString == "https://api.github.com/repos/ChrisLloydME/Tunes/releases?per_page=50")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
    }

    @Test func preservesPublishedNotesAndPrereleasesWhileExcludingDrafts() async throws {
        let releases = try await client(body: ###"[{"id":1,"name":"  ","tag_name":"v1.0","body":"## Changes\n- Playback fixes","published_at":"2026-10-18T00:00:00Z","prerelease":true,"draft":false},{"id":2,"name":"Draft","tag_name":"v2","body":"Hidden","published_at":null,"prerelease":false,"draft":true}]"###).fetchReleases()
        #expect(releases.count == 1)
        #expect(releases.first?.displayTitle == "v1.0")
        #expect(releases.first?.body == "## Changes\n- Playback fixes")
        #expect(releases.first?.isPrerelease == true)
        #expect(releases.first?.publishedAt != nil)
    }

    @Test func acceptsReleaseWithoutBody() async throws {
        let releases = try await client(body: ###"[{"id":1,"name":"First Release","tag_name":"v1","body":null,"published_at":null,"prerelease":false,"draft":false}]"###).fetchReleases()
        #expect(releases.first?.displayTitle == "First Release")
        #expect(releases.first?.body == nil)
    }

    @Test func httpFailuresAndMalformedResponsesAreNotEmptyReleases() async {
        for (status, body) in [(403, "[]"), (404, "[]"), (200, "{}")] {
            do {
                _ = try await client(status: status, body: body).fetchReleases()
                Issue.record("An unsuccessful response must not appear as an empty release list.")
            } catch { }
        }
    }
}

private final class ReleaseNotesURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = "[]"
    nonisolated(unsafe) static var request: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.request = request
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
