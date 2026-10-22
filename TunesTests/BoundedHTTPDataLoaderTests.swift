import Foundation
import Testing
@testable import Tunes

private final class LoaderRequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() -> Int { lock.withLock { value += 1; return value } }
    var count: Int { lock.withLock { value } }
}

@MainActor
@Suite(.serialized)
struct BoundedHTTPDataLoaderTests {
    private final class Stub: URLProtocol {
        nonisolated(unsafe) static var handler:
            (@Sendable (URLRequest) throws -> (Int, [String: String], Data))?
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            do {
                let response = try Self.handler!(request)
                let http = HTTPURLResponse(url: request.url!, statusCode: response.0,
                                           httpVersion: "HTTP/1.1",
                                           headerFields: response.1)!
                client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: response.2)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
        override func stopLoading() {}
    }

    private func loader() -> BoundedHTTPDataLoader {
        BoundedHTTPDataLoader(protocolClasses: [Stub.self])
    }

    @Test func rejectsNonHTTPSWithoutStartingATransfer() async {
        let counter = LoaderRequestCounter()
        Stub.handler = { _ in
            _ = counter.increment()
            return (200, [:], Data())
        }
        do {
            _ = try await loader().data(from: URL(string: "http://example.test/a.png")!,
                                        maxBytes: 100)
            Issue.record("Expected an insecure URL failure")
        } catch {
            #expect((error as? BoundedHTTPDataLoader.Failure) == .insecureURL)
        }
        #expect(counter.count == 0)
    }

    @Test func rejectsANonSuccessStatus() async {
        Stub.handler = { _ in (404, [:], Data("missing".utf8)) }
        do {
            _ = try await loader().data(from: URL(string: "https://example.test/a.png")!,
                                        maxBytes: 100)
            Issue.record("Expected a bad status failure")
        } catch {
            #expect((error as? BoundedHTTPDataLoader.Failure) == .badStatus)
        }
    }

    @Test func stopsReceivingOnceTheByteLimitIsExceeded() async {
        Stub.handler = { _ in (200, [:], Data(repeating: 1, count: 128)) }
        do {
            _ = try await loader().data(from: URL(string: "https://example.test/a.png")!,
                                        maxBytes: 32)
            Issue.record("Expected an oversized failure")
        } catch {
            #expect((error as? BoundedHTTPDataLoader.Failure) == .tooLarge)
        }
    }

    @Test func returnsBoundedBytesForAValidResponse() async throws {
        let bytes = Data(repeating: 7, count: 64)
        Stub.handler = { _ in (200, ["Content-Type": "image/png"], bytes) }
        let received = try await loader().data(
            from: URL(string: "https://example.test/a.png")!, maxBytes: 64)
        #expect(received == bytes)
    }

    @Test func transportErrorsAreNotRewrittenWithURLs() async {
        Stub.handler = { _ in throw URLError(.serverCertificateUntrusted) }
        do {
            _ = try await loader().data(from: URL(string: "https://example.test/a.png")!,
                                        maxBytes: 64)
            Issue.record("Expected a transport failure")
        } catch let error as URLError {
            #expect(error.code == .serverCertificateUntrusted)
            #expect(!error.localizedDescription.contains("example.test"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
