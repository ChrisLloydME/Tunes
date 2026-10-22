import Foundation
import Testing
@testable import Tunes

@MainActor
@Suite(.serialized)
struct SamplyUploaderTests {
    @Test func artworkTicketTimeoutIsUncertainAndRetainsNoTicket() async {
        UploadURLProtocol.handler = { request in
            if request.url?.host == "samply.app" { return .hang }
            return .respond(200, [:], "")
        }
        let (uploader, _) = makeUploader(ticketTimeout: 0.2, artworkPutTimeout: 1)
        let outcome = await uploader.performArtworkUpload(
            payload: payload(), projectID: "project-1", authorization: authorization())

        #expect(outcome.phase == .ticketRequested)
        #expect(outcome.ticket == nil)
        guard case .uncertain(let message) = outcome.disposition else {
            Issue.record("A timed-out ticket request must be uncertain")
            return
        }
        #expect(message.contains("ticket"))
        #expect(!outcome.isSafelyRetryable)
    }

    @Test func artworkPUTTimeoutIsUncertainAndRetainsTicketIdentity() async {
        UploadURLProtocol.handler = { request in
            if request.url?.host == "samply.app" {
                return .respond(200, [:], artworkTicketJSON)
            }
            return .hang
        }
        let (uploader, _) = makeUploader(ticketTimeout: 1, artworkPutTimeout: 0.2)
        let outcome = await uploader.performArtworkUpload(
            payload: payload(), projectID: "project-1", authorization: authorization())

        #expect(outcome.phase == .putStarted)
        #expect(outcome.ticket?.boxID == "art-box")
        #expect(outcome.ticket?.kind == .artwork)
        guard case .uncertain(let message) = outcome.disposition else {
            Issue.record("A timed-out PUT must be uncertain")
            return
        }
        #expect(message.contains("may have received"))
        #expect(!outcome.isSafelyRetryable)
    }

    @Test func authorizationIsCheckedAgainBeforePUTAndNoStorageRequestStarts() async {
        let counter = UploadRequestCounter()
        UploadURLProtocol.handler = { request in
            _ = counter.increment()
            if request.url?.host == "samply.app" {
                return .respond(200, [:], artworkTicketJSON)
            }
            return .respond(200, [:], "")
        }
        let (uploader, _) = makeUploader(ticketTimeout: 1, artworkPutTimeout: 1)
        let authorization = authorization { counter.count < 1 }
        let outcome = await uploader.performArtworkUpload(
            payload: payload(), projectID: "project-1", authorization: authorization)

        #expect(counter.count == 1)
        #expect(outcome.phase == .ticketReceived)
        #expect(outcome.ticket?.boxID == "art-box")
        #expect(outcome.disposition == .cancelled)
        #expect(!outcome.isSafelyRetryable)
    }

    @Test func cancelledBeforeSubmissionReturnsRetryableWaitingOutcome() async {
        let counter = UploadRequestCounter()
        UploadURLProtocol.handler = { _ in
            _ = counter.increment()
            return .respond(200, [:], artworkTicketJSON)
        }
        let (uploader, _) = makeUploader(ticketTimeout: 1, artworkPutTimeout: 1)
        let task = Task {
            await uploader.performArtworkUpload(
                payload: payload(), projectID: "project-1", authorization: authorization())
        }
        task.cancel()
        let outcome = await task.value

        #expect(counter.count == 0)
        #expect(outcome.disposition == .cancelled)
        #expect(outcome.phase == .waiting)
        #expect(outcome.isSafelyRetryable)
    }

    @Test func rejectedStorageResponseIsDefiniteButNotBlindlyRetryable() async {
        UploadURLProtocol.handler = { request in
            if request.url?.host == "samply.app" {
                return .respond(200, [:], artworkTicketJSON)
            }
            return .respond(500, [:], "")
        }
        let (uploader, _) = makeUploader(ticketTimeout: 1, artworkPutTimeout: 1)
        let outcome = await uploader.performArtworkUpload(
            payload: payload(), projectID: "project-1", authorization: authorization())

        #expect(outcome.phase == .putStarted)
        #expect(outcome.ticket?.boxID == "art-box")
        guard case .failed(let message) = outcome.disposition else {
            Issue.record("A storage HTTP error is a definite failed PUT")
            return
        }
        #expect(message.contains("HTTP 500"))
        #expect(!outcome.isSafelyRetryable)
    }

    private func makeUploader(ticketTimeout: TimeInterval,
                              artworkPutTimeout: TimeInterval)
        -> (SamplyUploader, MemoryTokenStore) {
        let tokens = MemoryTokenStore()
        try? tokens.save("fixture-token")
        let apiConfig = URLSessionConfiguration.ephemeral
        apiConfig.protocolClasses = [UploadURLProtocol.self]
        let api = SamplyAPI(tokens: tokens,
                            session: URLSession(configuration: apiConfig))
        let storageConfig = URLSessionConfiguration.ephemeral
        storageConfig.protocolClasses = [UploadURLProtocol.self]
        let uploader = SamplyUploader(api: api, storageConfiguration: storageConfig,
                                      ticketTimeout: ticketTimeout,
                                      filePutTimeout: ticketTimeout,
                                      artworkPutTimeout: artworkPutTimeout)
        return (uploader, tokens)
    }

    private func authorization(valid: @escaping @MainActor () -> Bool = { true })
        -> UploadAuthorization {
        let credential = VerifiedProjectCredential(
            token: "fixture-token", accountID: "account-a",
            sessionGeneration: 1, credentialRevision: 1)
        let context = MutationContext(operationID: UUID(), sessionGeneration: 1,
                                      accountID: "account-a", credentialRevision: 1)
        return UploadAuthorization(credential: credential, context: context, isValid: valid)
    }

    private func payload() -> ProjectArtworkPayload {
        ProjectArtworkPayload(data: Data([1, 2, 3]), fileName: "Cover.jpg",
                              mimeType: "image/jpeg")
    }
}

private let artworkTicketJSON =
    #"{"boxid":"art-box","contentType":"image/jpeg","metadata":{"destination":"asset","projectid":"project-1","boxpath":"projects/project-1/boxes/art-box","writeback":"project"},"url":"https://storage.example/upload"}"#


private enum UploadURLResponse {
    case respond(Int, [String: String], String)
    case hang
}

private final class UploadURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> UploadURLResponse)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else { return }
        do {
            switch try handler(request) {
            case .hang:
                // Return without a callback so URLSession enforces the request
                // timeout. stopLoading() marks the fixture as abandoned.
                return
            case .respond(let status, let headers, let body):
                guard let url = request.url,
                      let response = HTTPURLResponse(url: url, statusCode: status,
                                                     httpVersion: "HTTP/1.1",
                                                     headerFields: headers) else { return }
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(body.utf8))
                client?.urlProtocolDidFinishLoading(self)
            }
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class UploadRequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() -> Int { lock.withLock { value += 1; return value } }
    var count: Int { lock.withLock { value } }
}
