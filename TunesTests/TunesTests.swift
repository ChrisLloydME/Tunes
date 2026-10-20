import Foundation
import Testing
@testable import Tunes

@MainActor
@Suite(.serialized)
struct TunesTests {
    private func client(handler: @escaping @Sendable (URLRequest) throws -> (Int, [String: String], String)) -> SamplyAPI {
        StubURLProtocol.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let tokens = MemoryTokenStore()
        try? tokens.save("fixture-token")
        return SamplyAPI(tokens: tokens, session: URLSession(configuration: config))
    }

    @Test func ownedProjectsUseDocumentedEndpointAndBearer() async throws {
        let api = client { request in
            #expect(request.url?.absoluteString == "https://samply.app/api/v0/projects")
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
            return (200, [:], #"[{"id":"project-1","name":"Album","timeModified":1700000000000}]"#)
        }
        let projects = try await api.projects()
        #expect(projects.first?.id == "project-1")
        #expect(projects.first?.timeModified == 1700000000000)
    }

    @Test func createProjectUsesPostBearerAndNameOnlyJSON() async throws {
        let api = client { request in
            #expect(request.url?.absoluteString == "https://samply.app/api/v0/projects")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            let json = try #require(JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any])
            #expect(Set(json.keys) == ["name"])
            #expect(json["name"] as? String == "Été – 東京")
            return (200, [:], #"{"id":"project-new","name":"Été – 東京","object":"project","size":0,"timeCreated":1700000000000,"timeModified":1700000000001,"playerUrl":"https://samply.app/p/share-new"}"#)
        }
        let project = try await api.createProject(name: "Été – 東京")
        #expect(project.id == "project-new")
        #expect(project.name == "Été – 東京")
        #expect(project.playerUrl?.absoluteString == "https://samply.app/p/share-new")
    }

    @Test func createProjectMapsAuthenticationErrorsWithoutServerDetails() async throws {
        for status in [401, 403] {
            let api = client { _ in (status, [:], #"{"error":"private server detail"}"#) }
            do {
                _ = try await api.createProject(name: "Album")
                Issue.record("Expected project creation to fail")
            } catch let error as SamplyError {
                if status == 401 {
                    guard case .invalidToken = error else { Issue.record("Wrong auth error"); return }
                } else {
                    guard case .http(let code, _) = error, code == 403 else {
                        Issue.record("Wrong HTTP error"); return
                    }
                }
                #expect(!error.localizedDescription.contains("private server detail"))
            }
        }
    }

    @Test func createProjectRejectsMalformedSuccessResponse() async {
        let api = client { _ in (200, [:], #"{"playerUrl":"https://samply.app/p/share-new"}"#) }
        await #expect(throws: (any Error).self) { try await api.createProject(name: "Album") }
    }

    @Test func createProjectNeverRetriesServerOrRateLimitErrors() async {
        for status in [429, 500, 503] {
            let log = RequestCounter()
            let api = client { _ in
                _ = log.increment()
                return (status, ["Retry-After": "0"], "{}")
            }
            await #expect(throws: (any Error).self) { try await api.createProject(name: "Album") }
            #expect(log.count == 1)
        }
    }

    @Test func boxesDecodeFoldersStacksVersionsAndAudio() async throws {
        let api = client { request in
            #expect(request.url?.path == "/api/v0/projects/project-1/all")
            return (200, [:], #"[{"id":"folder","object":"folder","name":"Mixes","children":[{"id":"stack","name":"Song"}]},{"id":"stack","object":"stack","name":"Song","children":[{"id":"v2"},{"id":"v1"}]},{"id":"v2","object":"file","name":"Song.wav","duration":123.45}]"#)
        }
        let boxes = try await api.boxes(projectID: "project-1")
        #expect(boxes.count == 3)
        #expect(boxes[0].children?.first?.id == "stack")
        #expect(boxes[1].children?.map(\.id) == ["v2", "v1"])
        #expect(boxes[2].isAudio)
    }

    @Test func uploadTicketEncodesOriginalFileAndParent() async throws {
        let api = client { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/api/v0/projects/project-1/files")
            // URLSession may move httpBody to a stream before URLProtocol receives the request.
            var body = request.httpBody ?? Data()
            if body.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    body.append(contentsOf: buffer.prefix(count))
                }
            }
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(json["name"] as? String == "Original Mix – Studio.wav")
            #expect(json["mimeType"] as? String == "audio/wav")
            #expect(json["size"] as? Int64 == 9_000_000_000)
            #expect(json["parentid"] as? String == "folder-1")
            return (200, [:], #"{"boxid":"new-file","contentType":"audio/wav","metadata":{"destination":"asset","projectid":"project-1","boxpath":"projects/project-1/boxes/new-file"},"stackid":"new-stack","url":"https://storage.googleapis.com/upload?signature=fixture"}"#)
        }
        let ticket = try await api.uploadTicket(projectID: "project-1", name: "Original Mix – Studio.wav",
                                                mimeType: "audio/wav", size: 9_000_000_000, parentID: "folder-1")
        #expect(ticket.boxid == "new-file")
        let request = try SamplyUploader.storageRequest(ticket: ticket)
        #expect(request.httpMethod == "PUT")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "audio/wav")
        #expect(request.value(forHTTPHeaderField: "x-goog-meta-projectid") == "project-1")
        #expect(request.value(forHTTPHeaderField: "x-goog-meta-destination") == "asset")
        #expect(request.value(forHTTPHeaderField: "x-goog-meta-boxpath") == "projects/project-1/boxes/new-file")
    }

    @Test func storageRejectsInsecureURLAndMissingMetadata() throws {
        let unsafe = UploadTicket(boxid: "f", contentType: "audio/wav", metadata: [:], stackid: nil,
                                  url: URL(string: "http://storage.example/upload")!)
        #expect(throws: (any Error).self) { try SamplyUploader.storageRequest(ticket: unsafe) }
        let invalid = UploadTicket(boxid: "f", contentType: "audio/wav", metadata: [:], stackid: nil,
                                   url: URL(string: "https://storage.example/upload")!)
        #expect(throws: (any Error).self) { try SamplyUploader.storageRequest(ticket: invalid) }
    }

    @Test func invalidIdentifiersCannotEscapeResourcePath() throws {
        let base = URL(string: "https://samply.app/api/v0")!
        for id in ["", "..", ".", "a/b", "a\\b", "a\nb"] {
            #expect(throws: (any Error).self) { try SamplyAPI.resourceURL(base: base, components: ["projects", id]) }
        }
        let url = try SamplyAPI.resourceURL(base: base, components: ["projects", "a?b#c"])
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.query == nil)
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment == nil)
    }

    @Test func mapsExpiredTokenAndDeniedAccess() async throws {
        for status in [401, 403, 404] {
            let api = client { _ in (status, [:], #"{"error":"private server detail"}"#) }
            do {
                _ = try await api.projects()
                Issue.record("Expected HTTP failure")
            } catch let error as SamplyError {
                if status == 401 {
                    guard case .invalidToken = error else { Issue.record("Wrong auth error"); return }
                } else {
                    guard case .http(let code, _) = error else { Issue.record("Wrong HTTP error"); return }
                    #expect(code == status)
                }
                #expect(!error.localizedDescription.contains("private server detail"))
            }
        }
    }

    @Test func getRetriesTransientFailureButPostNeverReplaysUploadCreation() async throws {
        let getLog = RequestCounter()
        let getAPI = client { _ in
            let count = getLog.increment()
            return count == 1 ? (503, ["Retry-After": "0"], "{}") : (200, [:], "[]")
        }
        _ = try await getAPI.projects()
        #expect(getLog.count == 2)
        let postLog = RequestCounter()
        let postAPI = client { _ in
            _ = postLog.increment()
            return (503, [:], "{}")
        }
        await #expect(throws: (any Error).self) {
            try await postAPI.uploadTicket(projectID: "p", name: "a.wav", mimeType: "audio/wav", size: 10, parentID: nil)
        }
        #expect(postLog.count == 1)
    }

    @Test func malformedSuccessFailsDecoding() async {
        let api = client { _ in (200, [:], #"{"unexpected":true}"#) }
        await #expect(throws: (any Error).self) { try await api.projects() }
    }

    @Test func completeOriginalFileUploadUsesSeparateStorageRequest() async throws {
        let log = RequestCounter()
        let api = client { request in
            _ = log.increment()
            if request.url?.host == "samply.app" {
                return (200, [:], #"{"boxid":"uploaded","contentType":"audio/wav","metadata":{"destination":"asset","projectid":"p","boxpath":"projects/p/boxes/uploaded"},"url":"https://storage.googleapis.com/fixture-upload"}"#)
            }
            #expect(request.httpMethod == "PUT")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.value(forHTTPHeaderField: "x-goog-meta-projectid") == "p")
            return (200, [:], "")
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let uploader = SamplyUploader(api: api, storageConfiguration: config)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        let original = Data(repeating: 37, count: 65536)
        try original.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        uploader.upload(file: file, projectID: "p")
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while uploader.isRunning, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(uploader.status == .completed)
        #expect(uploader.progress == 1)
        #expect(uploader.uploadedBoxID == "uploaded")
        #expect(log.count == 2)
        #expect(try Data(contentsOf: file) == original)
    }

    @Test func cancellingBeforeUploadStartsDoesNotCreateServerResources() async throws {
        let log = RequestCounter()
        let api = client { _ in _ = log.increment(); return (500, [:], "{}") }
        let uploader = SamplyUploader(api: api)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try Data([1, 2, 3]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        uploader.upload(file: file, projectID: "p")
        uploader.cancel()
        await Task.yield()
        #expect(uploader.status == .cancelled)
        #expect(log.count == 0)
        #expect(uploader.uploadedBoxID == nil)
    }

    @Test func tokensAreSessionOnlyAndExplicitlyRemovable() throws {
        let sessionA = MemoryTokenStore()
        let sessionB = MemoryTokenStore()
        try sessionA.save("fixture-token")
        #expect(try sessionA.read() == "fixture-token")
        #expect(try sessionB.read() == nil)
        try sessionA.remove()
        #expect(try sessionA.read() == nil)
    }

    @Test func signedDownloadIsNeverAnAutomaticPlaybackFallback() async throws {
        let api = client { request in
            #expect(request.url?.path == "/api/v0/projects/p/files/f/download")
            return (200, [:], #"{"url":"https://storage.googleapis.com/signed-file","expires":1800000000}"#)
        }
        let ticket = try await api.download(projectID: "p", fileID: "f")
        #expect(ticket.expires == 1800000000)
        #expect(ticket.url.scheme == "https")
    }
}

struct EmailSignInLinkTests {
    private let fixture = "https://samply.app/auth?apiKey=fixture-key&mode=signIn&oobCode=fixture-code&lang=en"

    @Test func preservesDirectAndEmailProviderLinksWithoutInspectingTheirFormat() throws {
        let destination = try #require(fixture.addingPercentEncoding(withAllowedCharacters: .alphanumerics))
        let links = [
            fixture,
            "https://nam12.safelinks.protection.outlook.com/?url=" + destination + "&data=fixture&reserved=0",
            "https://www.google.com/url?q=" + destination + "&source=gmail&ust=fixture",
            "https://mail.google.com/mail/u/0/?ui=2&url=" + destination,
            "http://mail.example/redirect/fixture-ticket?next=" + destination,
            "https://mail.example/continue?ticket=fixture-code#sign-in",
            fixture + "&mode=signIn&custom=preserved"
        ]
        for value in links {
            #expect(try SamplyEmailSignInLink.parse(" \n" + value + "\n").absoluteString == value)
        }
    }

    @Test func emptyInputDoesNotEchoCredentialsInErrors() {
        #expect(throws: EmailSignInLinkError.self) { try SamplyEmailSignInLink.parse(" \n") }
        #expect(!EmailSignInLinkError.invalidLink.localizedDescription.contains("fixture-code"))
        #expect(!EmailSignInLinkError.invalidLink.localizedDescription.contains("fixture-key"))
    }
}

private func requestBody(_ request: URLRequest) -> Data {
    // URLSession may move httpBody to a stream before URLProtocol receives the request.
    var body = request.httpBody ?? Data()
    if body.isEmpty, let stream = request.httpBodyStream {
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            body.append(contentsOf: buffer.prefix(count))
        }
    }
    return body
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, [String: String], String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let response = try Self.handler!(request)
            let http = HTTPURLResponse(url: request.url!, statusCode: response.0, httpVersion: "HTTP/1.1", headerFields: response.1)!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(response.2.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() -> Int { lock.withLock { value += 1; return value } }
    var count: Int { lock.withLock { value } }
}
