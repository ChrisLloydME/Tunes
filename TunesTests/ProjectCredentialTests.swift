import Foundation
import Testing
@testable import Tunes

@MainActor
@Suite(.serialized)
struct ProjectCredentialTests {
    @Test func emptyOwnedProjectListBlocksIdentityVerification() async throws {
        let tokens = MemoryTokenStore()
        let api = makeAPI(tokens: tokens) { request in
            #expect(request.url?.path == "/api/v0/projects")
            return (200, [:], "[]")
        }
        let ownership = StubOwnershipReader()
        let authority = ProjectCredentialAuthority(tokens: tokens, api: api,
                                                   ownership: ownership)
        authority.activate(accountID: "account-a", generation: 1)

        await #expect(throws: ProjectCredentialError.self) {
            try await authority.saveCandidate("candidate-token")
        }
        #expect(try tokens.read() == nil)
        #expect(ownership.reads.isEmpty)
        guard case .identityUnverifiable(let message) = authority.state else {
            Issue.record("Expected an explicit unverifiable identity state")
            return
        }
        #expect(message.contains("no owned project"))
        #expect(message.contains("will not create a disposable project"))
    }

    @Test func ownedProjectWithDifferentWebOwnerIsUnverifiable() async throws {
        let tokens = MemoryTokenStore()
        let api = makeAPI(tokens: tokens) { _ in
            (200, [:], #"[{"id":"project-1","name":"Album","creator":{"uid":"account-b"}}]"#)
        }
        let ownership = StubOwnershipReader(ownerID: "account-b")
        let authority = ProjectCredentialAuthority(tokens: tokens, api: api,
                                                   ownership: ownership)
        authority.activate(accountID: "account-a", generation: 1)

        await #expect(throws: ProjectCredentialError.self) {
            try await authority.saveCandidate("candidate-token")
        }
        #expect(try tokens.read() == nil)
        #expect(ownership.reads == ["project-1"])
        guard case .identityUnverifiable(let message) = authority.state else {
            Issue.record("Expected a different-owner identity state")
            return
        }
        #expect(message.contains("different Samply account"))
    }

    @Test func ownedProjectCurrentlyOwnedBySignedInAccountVerifies() async throws {
        let tokens = MemoryTokenStore()
        let api = makeAPI(tokens: tokens) { _ in
            (200, [:], #"[{"id":"project-1","name":"Album","creator":{"uid":"account-a"}}]"#)
        }
        let ownership = StubOwnershipReader(ownerID: "account-a")
        let authority = ProjectCredentialAuthority(tokens: tokens, api: api,
                                                   ownership: ownership)
        authority.activate(accountID: "account-a", generation: 1)

        try await authority.saveCandidate("candidate-token")

        #expect(try tokens.read() == "candidate-token")
        #expect(ownership.reads == ["project-1"])
        #expect(authority.state == .verified(accountID: "account-a", sessionGeneration: 1,
                                             credentialRevision: 2))
        #expect(authority.verifiedCredential()?.token == "candidate-token")
    }

    @Test func candidateValidationKeepsTheCandidateInMemoryUntilProven() async throws {
        let tokens = MemoryTokenStore()
        let api = makeAPI(tokens: tokens) { _ in
            (200, [:], #"[{"id":"project-1","name":"Album"}]"#)
        }
        let ownership = StubOwnershipReader(ownerID: "account-a")
        ownership.gateNextRead = true
        let authority = ProjectCredentialAuthority(tokens: tokens, api: api,
                                                   ownership: ownership)
        authority.activate(accountID: "account-a", generation: 1)

        let saving = Task { try await authority.saveCandidate("candidate-token") }
        await waitUntil { ownership.isGated }
        #expect(try tokens.read() == nil)
        #expect(authority.state == .validating)
        ownership.releaseRead()
        try await saving.value
        #expect(try tokens.read() == "candidate-token")
    }

    @Test func rejectedCandidateDoesNotReplaceAWorkingSavedToken() async throws {
        let tokens = MemoryTokenStore()
        try tokens.save("good-token")
        let api = makeAPI(tokens: tokens) { request in
            let authorization = request.value(forHTTPHeaderField: "Authorization")
            if authorization == "Bearer bad-token" {
                return (401, [:], "{}")
            }
            return (200, [:], #"[{"id":"project-1","name":"Album"}]"#)
        }
        let ownership = StubOwnershipReader(ownerID: "account-a")
        let authority = ProjectCredentialAuthority(tokens: tokens, api: api,
                                                   ownership: ownership)
        authority.activate(accountID: "account-a", generation: 1)
        await waitUntil { authority.verifiedCredential() != nil }
        #expect(authority.verifiedCredential()?.token == "good-token")

        await #expect(throws: ProjectCredentialError.self) {
            try await authority.saveCandidate("bad-token")
        }

        #expect(try tokens.read() == "good-token")
        #expect(authority.verifiedCredential()?.token == "good-token")
        #expect(authority.state == .verified(accountID: "account-a", sessionGeneration: 1,
                                             credentialRevision: 1))
    }

    @Test func removalDuringCandidateValidationDoesNotResurrectTheToken() async throws {
        let tokens = MemoryTokenStore()
        let api = makeAPI(tokens: tokens) { _ in
            (200, [:], #"[{"id":"project-1","name":"Album"}]"#)
        }
        let ownership = StubOwnershipReader(ownerID: "account-a")
        ownership.gateNextRead = true
        let authority = ProjectCredentialAuthority(tokens: tokens, api: api,
                                                   ownership: ownership)
        authority.activate(accountID: "account-a", generation: 1)
        let saving = Task { try await authority.saveCandidate("candidate-token") }
        await waitUntil { ownership.isGated }
        try authority.remove()
        ownership.releaseRead()
        await #expect(throws: ProjectCredentialError.self) { try await saving.value }

        #expect(try tokens.read() == nil)
        #expect(authority.verifiedCredential() == nil)
        #expect(authority.state == .absent)
        #expect(!authority.hasStoredToken)
    }

    @Test func rejectedRestoredTokenStaysInactiveUntilReplaced() async throws {
        let tokens = MemoryTokenStore()
        try tokens.save("expired-token")
        let api = makeAPI(tokens: tokens) { _ in (401, [:], "{}") }
        let ownership = StubOwnershipReader(ownerID: "account-a")
        let authority = ProjectCredentialAuthority(tokens: tokens, api: api,
                                                   ownership: ownership)

        authority.activate(accountID: "account-a", generation: 1)
        await waitUntil {
            if case .rejected = authority.state { return true }
            return false
        }

        #expect(authority.verifiedCredential() == nil)
        #expect(authority.hasStoredToken)
        #expect(try tokens.read() == "expired-token")
        guard case .rejected(let message) = authority.state else {
            Issue.record("Expected an explicit rejected state")
            return
        }
        #expect(message.contains("rejected"))
    }

    @Test func restoredTokenIsRevalidatedAndOldContextsBecomeStale() async throws {
        let tokens = MemoryTokenStore()
        try tokens.save("restored-token")
        let api = makeAPI(tokens: tokens) { _ in
            (200, [:], #"[{"id":"project-1","name":"Album"}]"#)
        }
        let ownership = StubOwnershipReader(ownerID: "account-a")
        let authority = ProjectCredentialAuthority(tokens: tokens, api: api,
                                                   ownership: ownership)

        authority.activate(accountID: "account-a", generation: 1)
        await waitUntil { authority.verifiedCredential() != nil }
        let first = try #require(authority.verifiedCredential())
        let context = MutationContext(operationID: UUID(), sessionGeneration: first.sessionGeneration,
                                      accountID: first.accountID,
                                      credentialRevision: first.credentialRevision)
        #expect(authority.isCurrent(context))

        // The same account can start a new session generation (for example after
        // sign-out and sign-in). The old verification must not remain current.
        authority.activate(accountID: "account-a", generation: 2)
        #expect(!authority.isCurrent(context))
        await waitUntil { authority.verifiedCredential() != nil }
        #expect(authority.verifiedCredential()?.sessionGeneration == 2)
        #expect(!authority.isCurrent(context))
    }

    @Test func removingOrReplacingTheTokenInvalidatesTheCapturedContext() async throws {
        let tokens = MemoryTokenStore()
        try tokens.save("restored-token")
        let api = makeAPI(tokens: tokens) { _ in
            (200, [:], #"[{"id":"project-1","name":"Album"}]"#)
        }
        let ownership = StubOwnershipReader(ownerID: "account-a")
        let authority = ProjectCredentialAuthority(tokens: tokens, api: api,
                                                   ownership: ownership)
        authority.activate(accountID: "account-a", generation: 1)
        await waitUntil { authority.verifiedCredential() != nil }
        let credential = try #require(authority.verifiedCredential())
        let context = MutationContext(operationID: UUID(),
                                      sessionGeneration: credential.sessionGeneration,
                                      accountID: credential.accountID,
                                      credentialRevision: credential.credentialRevision)
        #expect(authority.isCurrent(context))

        try authority.remove()
        #expect(!authority.isCurrent(context))
        #expect(try tokens.read() == nil)
        #expect(authority.state == .absent)
        #expect(authority.verifiedCredential() == nil)
    }

    @Test func accountChangeInvalidatesRestoredVerification() async throws {
        let tokens = MemoryTokenStore()
        try tokens.save("account-a-token")
        let api = makeAPI(tokens: tokens) { _ in
            (200, [:], #"[{"id":"project-1","name":"Album"}]"#)
        }
        let ownership = StubOwnershipReader(ownerID: "account-a")
        let authority = ProjectCredentialAuthority(tokens: tokens, api: api,
                                                   ownership: ownership)
        authority.activate(accountID: "account-a", generation: 1)
        await waitUntil { authority.verifiedCredential() != nil }

        ownership.accountID = "account-b"
        ownership.ownerID = "account-b"
        authority.activate(accountID: "account-b", generation: 2)

        // account-a's saved credential is deleted on restore for a different account.
        #expect(try tokens.read() == nil)
        #expect(authority.verifiedCredential() == nil)
        #expect(authority.state == .absent)
    }
}

@MainActor
private final class StubOwnershipReader: ProjectOwnershipReading {
    var accountID: String? = "account-a"
    var isSigningOut = false
    var ownerID: String?
    var proofs: [String: ProjectOwnershipProof] = [:]
    private(set) var reads: [String] = []
    var gateNextRead = false
    private var continuation: CheckedContinuation<Void, Never>?

    var isGated: Bool { continuation != nil }

    init(ownerID: String? = "account-a") {
        self.ownerID = ownerID
    }

    func projectOwnership(projectID: String) async throws -> ProjectOwnershipProof {
        reads.append(projectID)
        if gateNextRead {
            gateNextRead = false
            await withCheckedContinuation { continuation = $0 }
        }
        if let proof = proofs[projectID] { return proof }
        return ProjectOwnershipProof(accountID: accountID ?? "account-a",
                                     projectID: projectID,
                                     ownerID: ownerID,
                                     exists: true)
    }

    func releaseRead() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private func makeAPI(tokens: MemoryTokenStore,
                     handler: @escaping @Sendable (URLRequest) throws -> (Int, [String: String], String))
    -> SamplyAPI {
    CredentialURLProtocol.handler = handler
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [CredentialURLProtocol.self]
    return SamplyAPI(tokens: tokens, session: URLSession(configuration: config))
}

@MainActor
private func waitUntil(_ predicate: @MainActor () -> Bool) async {
    for _ in 0..<800 {
        if predicate() { return }
        await Task.yield()
    }
}

private final class CredentialURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, [String: String], String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let response = try Self.handler!(request)
            let http = HTTPURLResponse(url: request.url!, statusCode: response.0,
                                       httpVersion: "HTTP/1.1", headerFields: response.1)!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(response.2.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}
