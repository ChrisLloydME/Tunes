import Foundation
import Testing
@testable import Tunes

@MainActor
@Suite(.serialized)
struct ProjectCreationTests {
    @Test func blankNameIsRejectedBeforeAnyRequest() async {
        let api = StubProjectAPI(result: .success(project()))
        let coordinator = ProjectCreationCoordinator(api: api, web: StubCreationWeb(), fileUploader: StubFileUploader())

        await coordinator.create(name: " \n\t ")

        #expect(api.names.isEmpty)
        #expect(coordinator.state == .failed("Enter a project name."))
    }

    @Test func unicodeNameIsTrimmedButInternalCharactersArePreserved() async {
        let api = StubProjectAPI(result: .success(project(name: "Été – 東京")))
        let web = StubCreationWeb(libraryResponses: [.success(snapshot())])
        let coordinator = ProjectCreationCoordinator(api: api, web: web, fileUploader: StubFileUploader())

        await coordinator.create(name: "  Été – 東京 \n")

        #expect(api.names == ["Été – 東京"])
        #expect(coordinator.createdProject?.project.name == "Été – 東京")
    }

    @Test func duplicateSubmissionsShareOneRequest() async {
        let api = DeferredProjectAPI()
        let web = StubCreationWeb(libraryResponses: [.success(snapshot())])
        let coordinator = ProjectCreationCoordinator(api: api, web: web, fileUploader: StubFileUploader())

        let first = Task { await coordinator.create(name: "First") }
        await waitUntil { api.isSuspended }
        #expect(coordinator.blocksDismissal)
        let second = Task { await coordinator.create(name: "Second") }
        await Task.yield()
        #expect(api.names == ["First"])

        api.release()
        await first.value
        await second.value
        #expect(api.names == ["First"])
    }

    @Test func completeLibraryIsRefreshedAndTheCreatedProjectIsOpened() async {
        let item = libraryItem()
        let web = StubCreationWeb(
            libraryResponses: [.success(snapshot(library: [item]))],
            browseResponse: { routeID, _ in
                #expect(routeID == "share-1")
                return snapshot(routeID: routeID)
            }
        )
        let api = StubProjectAPI(result: .success(project()))
        let coordinator = ProjectCreationCoordinator(api: api, web: web, fileUploader: StubFileUploader())
        var refreshed: [LibraryItem] = []
        var opened: (LibraryItem, WebSnapshot)?
        coordinator.onLibraryRefreshed = { refreshed = $0 }
        coordinator.onProjectOpened = { opened = ($0, $1) }

        await coordinator.create(name: "  Album  ")

        #expect(api.names == ["Album"])
        #expect(web.calls.map(\.command) == ["refreshPage", "browse"])
        #expect(web.calls[0].arguments["page"] as? String == "library")
        #expect(web.calls[1].arguments["routeID"] as? String == "share-1")
        #expect(refreshed == [item])
        #expect(coordinator.createdStage == .opened)
        #expect(coordinator.createdProject?.libraryItem == item)
        #expect(opened?.0 == item)
        #expect(opened?.1.routeID == "share-1")
    }

    @Test func documentedPlayerURLKeepsTheProjectOpenableBeforeLibraryPropagation() async {
        let playerURL = URL(string: "https://samply.app/p/share-from-url")!
        let web = StubCreationWeb(
            libraryResponses: [.success(snapshot())],
            browseResponse: { routeID, _ in
                #expect(routeID == "share-from-url")
                return snapshot(routeID: routeID)
            }
        )
        let api = StubProjectAPI(result: .success(project(playerURL: playerURL)))
        let coordinator = ProjectCreationCoordinator(api: api, web: web, fileUploader: StubFileUploader())
        var opened: LibraryItem?
        coordinator.onProjectOpened = { item, _ in opened = item }

        await coordinator.create(name: "Album")
        #expect(coordinator.createdStage == .delayed)
        #expect(coordinator.createdProject?.openItem?.routeID == "share-from-url")

        await coordinator.openCreatedProject()
        #expect(coordinator.createdStage == .opened)
        #expect(opened?.projectID == "project-1")
        #expect(opened?.shareID == "share-from-url")
        #expect(api.names.count == 1)
    }

    @Test func confirmedCreationSurvivesRefreshFailureWithoutAnotherCreate() async {
        let item = libraryItem()
        let web = StubCreationWeb(
            libraryResponses: [
                .failure(URLError(.cannotConnectToHost)),
                .success(snapshot(library: [item]))
            ],
            browseResponse: { routeID, _ in snapshot(routeID: routeID) }
        )
        let api = StubProjectAPI(result: .success(project()))
        let coordinator = ProjectCreationCoordinator(api: api, web: web, fileUploader: StubFileUploader())

        await coordinator.create(name: "Album")

        #expect(api.names.count == 1)
        #expect(coordinator.createdProject?.project.id == "project-1")
        guard case .created(_, .refreshFailed(let message)) = coordinator.state else {
            Issue.record("Expected a confirmed creation with a refresh failure")
            return
        }
        #expect(message.contains("Project created"))

        await coordinator.refreshLibrary()

        #expect(api.names.count == 1)
        #expect(coordinator.createdStage == .opened)
        #expect(web.calls.filter { $0.command == "refreshPage" }.count == 2)
    }

    @Test func interruptedRefreshKeepsTheConfirmedProjectRetryable() async {
        let web = StubCreationWeb(libraryResponses: [.failure(CancellationError())])
        let api = StubProjectAPI(result: .success(project()))
        let coordinator = ProjectCreationCoordinator(api: api, web: web, fileUploader: StubFileUploader())

        await coordinator.create(name: "Album")

        #expect(api.names.count == 1)
        #expect(coordinator.createdProject?.project.id == "project-1")
        guard case .created(_, .refreshFailed(let message)) = coordinator.state else {
            Issue.record("Expected an interrupted refresh to remain a created state")
            return
        }
        #expect(message.contains("interrupted"))
        #expect(!coordinator.blocksDismissal)

        coordinator.reset()
        #expect(coordinator.createdProject?.project.id == "project-1")
    }

    @Test func ambiguousNetworkFailureIsNeverResubmitted() async {
        let web = StubCreationWeb(libraryResponses: [.success(snapshot())])
        let api = StubProjectAPI(result: .failure(URLError(.timedOut)))
        let coordinator = ProjectCreationCoordinator(api: api, web: web, fileUploader: StubFileUploader())

        await coordinator.create(name: "Album")

        #expect(api.names.count == 1)
        guard case .uncertain(let message, let canStartOver) = coordinator.state else {
            Issue.record("Expected an uncertain creation outcome")
            return
        }
        #expect(!canStartOver)
        #expect(message.contains("may already exist"))
        #expect(message.contains("Refresh your Library"))

        await coordinator.refreshLibrary()
        #expect(api.names.count == 1)
        guard case .uncertain(_, let refreshed) = coordinator.state else {
            Issue.record("Expected the refreshed uncertain state")
            return
        }
        #expect(refreshed)

        await coordinator.create(name: "Again")
        #expect(api.names.count == 1)

        coordinator.startOverAfterUncertainOutcome()
        #expect(coordinator.state == .idle)
    }

    @Test func staleCompletionIsIgnoredAfterAccountChange() async {
        let api = DeferredProjectAPI()
        let web = StubCreationWeb()
        let coordinator = ProjectCreationCoordinator(api: api, web: web, fileUploader: StubFileUploader())
        var refreshed = false
        coordinator.onLibraryRefreshed = { _ in refreshed = true }

        let task = Task { await coordinator.create(name: "Album") }
        await waitUntil { api.isSuspended }
        web.accountID = "account-b"
        coordinator.invalidate()
        api.release()
        await task.value

        #expect(coordinator.state == .idle)
        #expect(!refreshed)
        #expect(api.names.count == 1)
    }

    @Test func matchingRouteWithDifferentProjectIdentityIsNotLoaded() {
        let item = libraryItem()
        let otherProject = snapshot(routeID: "share-1", projectID: "project-other")
        #expect(!otherProject.hasLoadedBoxes(for: item, groupID: nil))
        #expect(otherProject.hasLoadedBoxes(for: item, groupID: nil,
                                            expectedProjectID: "project-other"))
    }

    @Test func playerURLTokenIsResolvedToTheLiveShareRoute() async {
        let playerURL = URL(string: "https://samply.app/p/project-1?token=share-token&si=user-a")!
        let web = StubCreationWeb(
            libraryResponses: [.success(snapshot())],
            browseResponse: { routeID, arguments in
                #expect(routeID == "project-1")
                #expect(arguments["token"] as? String == "share-token")
                #expect(arguments["projectID"] as? String == "project-1")
                return self.snapshot(routeID: "resolved-share", projectID: "project-1")
            }
        )
        let api = StubProjectAPI(result: .success(project(playerURL: playerURL)))
        let coordinator = ProjectCreationCoordinator(api: api, web: web, fileUploader: StubFileUploader())
        var opened: LibraryItem?
        coordinator.onProjectOpened = { item, _ in opened = item }

        await coordinator.create(name: "Album")
        #expect(coordinator.createdStage == .delayed)
        #expect(coordinator.createdProject?.openItem?.shareID == nil)

        await coordinator.openCreatedProject()
        #expect(coordinator.createdStage == .opened)
        #expect(opened?.shareID == "resolved-share")
        #expect(opened?.projectID == "project-1")
    }

    @Test func artworkAssignmentIsConfirmedWithoutRecreatingTheProject() async {
        let web = StubCreationWeb(libraryResponses: [.success(snapshot())])
        web.artworkResponses = [.success(.init(status: .confirmed, message: nil))]
        let api = StubProjectAPI(result: .success(project()))
        let coordinator = ProjectCreationCoordinator(api: api, web: web,
                                                     fileUploader: StubFileUploader())

        await coordinator.create(name: "Album", artwork: artworkPayload())
        await waitUntil { coordinator.artworkState == .assigned }

        #expect(api.names == ["Album"])
        #expect(coordinator.createdProject?.project.id == "project-1")
        #expect(web.calls.contains { $0.command == "setProjectArtwork" })
        #expect(web.calls.first { $0.command == "setProjectArtwork" }?
            .arguments["projectID"] as? String == "project-1")
    }

    @Test func artworkFailureIsHonestAndRetryableWithoutAnotherCreate() async {
        let web = StubCreationWeb(libraryResponses: [.failure(URLError(.cannotConnectToHost))])
        web.artworkResponses = [
            .success(.init(status: .failed, message: "This account cannot change the project artwork.")),
            .success(.init(status: .confirmed, message: nil))
        ]
        let api = StubProjectAPI(result: .success(project()))
        let coordinator = ProjectCreationCoordinator(api: api, web: web,
                                                     fileUploader: StubFileUploader())

        await coordinator.create(name: "Album", artwork: artworkPayload())
        await waitUntil {
            if case .failed = coordinator.artworkState { return true }
            return false
        }
        #expect(api.names.count == 1)
        #expect(coordinator.createdProject?.project.id == "project-1")
        guard case .created(_, .refreshFailed) = coordinator.state else {
            Issue.record("Expected the creation to survive the refresh failure")
            return
        }

        coordinator.retryArtwork()
        await waitUntil { coordinator.artworkState == .assigned }
        #expect(api.names.count == 1)
        #expect(web.calls.filter { $0.command == "setProjectArtwork" }.count == 2)
    }

    @Test func unsupportedArtworkContractFailsHonestly() async {
        let web = StubCreationWeb(libraryResponses: [.success(snapshot())])
        web.artworkResponses = [.success(.init(
            status: .unsupported,
            message: "This Samply web build does not expose the authorized artwork contract."
        ))]
        let api = StubProjectAPI(result: .success(project()))
        let coordinator = ProjectCreationCoordinator(api: api, web: web,
                                                     fileUploader: StubFileUploader())

        await coordinator.create(name: "Album", artwork: artworkPayload())
        await waitUntil {
            if case .unsupported = coordinator.artworkState { return true }
            return false
        }

        #expect(api.names.count == 1)
        #expect(coordinator.createdProject?.project.id == "project-1")
        #expect(!coordinator.canRetryArtwork)
    }

    @Test func initialUploadsStartBeforeNavigationAndSurviveItsFailure() async throws {
        let file = try temporaryFile("Initial Mix.wav")
        defer { try? FileManager.default.removeItem(at: file) }
        let item = libraryItem()
        let web = StubCreationWeb(
            libraryResponses: [.success(snapshot(library: [item]))],
            browseResponse: { _, _ in throw SamplyError.invalidResponse }
        )
        let api = StubProjectAPI(result: .success(project()))
        let uploader = StubFileUploader()
        let coordinator = ProjectCreationCoordinator(api: api, web: web, fileUploader: uploader)

        await coordinator.create(name: "Album", files: [file])
        await waitUntil { !coordinator.isUploadingInitialFiles }

        #expect(uploader.calls == ["Initial Mix.wav"])
        #expect(coordinator.initialFiles.count == 1)
        #expect(coordinator.initialFiles[0].status == .uploaded(boxID: "box-1"))
        #expect(api.names.count == 1)
        guard case .created(_, .openFailed) = coordinator.state else {
            Issue.record("Expected navigation failure after uploads started")
            return
        }
    }

    @Test func initialUploadsAreOrderedAndPreservePartialSuccess() async throws {
        let first = try temporaryFile("01 First.wav")
        let second = try temporaryFile("02 Second.wav")
        let third = try temporaryFile("03 Third.wav")
        defer {
            for file in [first, second, third] { try? FileManager.default.removeItem(at: file) }
        }
        let web = StubCreationWeb(libraryResponses: [.success(snapshot())])
        let api = StubProjectAPI(result: .success(project()))
        let uploader = StubFileUploader()
        uploader.results = [
            .success("box-1"),
            .failure(SamplyError.http(403, retryAfter: nil)),
            .success("box-3"),
            .success("box-2-retry")
        ]
        let coordinator = ProjectCreationCoordinator(api: api, web: web, fileUploader: uploader)

        await coordinator.create(name: "Album", files: [first, second, third])
        await waitUntil { !coordinator.isUploadingInitialFiles }

        #expect(uploader.calls == ["01 First.wav", "02 Second.wav", "03 Third.wav"])
        #expect(coordinator.initialFiles.map(\.status) == [
            .uploaded(boxID: "box-1"),
            .failed(SamplyError.http(403, retryAfter: nil).localizedDescription),
            .uploaded(boxID: "box-3")
        ])
        #expect(coordinator.canRetryInitialFiles)

        coordinator.retryFailedInitialFiles()
        await waitUntil { !coordinator.isUploadingInitialFiles }

        #expect(uploader.calls == ["01 First.wav", "02 Second.wav", "03 Third.wav", "02 Second.wav"])
        #expect(coordinator.initialFiles.map(\.status) == [
            .uploaded(boxID: "box-1"),
            .uploaded(boxID: "box-2-retry"),
            .uploaded(boxID: "box-3")
        ])
    }

    @Test func accountChangeStopsPendingInitialUploads() async throws {
        let file = try temporaryFile("Pending.wav")
        defer { try? FileManager.default.removeItem(at: file) }
        let web = StubCreationWeb(libraryResponses: [.success(snapshot())])
        let api = StubProjectAPI(result: .success(project()))
        let uploader = StubFileUploader()
        uploader.delay = .seconds(5)
        let coordinator = ProjectCreationCoordinator(api: api, web: web, fileUploader: uploader)

        await coordinator.create(name: "Album", files: [file])
        await waitUntil { uploader.calls.count == 1 }
        web.accountID = "account-b"
        coordinator.invalidate()
        await waitUntil { !coordinator.isUploadingInitialFiles }

        #expect(coordinator.state == .idle)
        #expect(coordinator.initialFiles.isEmpty)
        #expect(api.names.count == 1)
    }

    @Test func ambiguousInitialUploadIsNotAutomaticallyResubmitted() async throws {
        let file = try temporaryFile("Uncertain.wav")
        defer { try? FileManager.default.removeItem(at: file) }
        let web = StubCreationWeb(libraryResponses: [.success(snapshot())])
        let api = StubProjectAPI(result: .success(project()))
        let uploader = StubFileUploader()
        uploader.results = [.failure(URLError(.timedOut))]
        let coordinator = ProjectCreationCoordinator(api: api, web: web, fileUploader: uploader)

        await coordinator.create(name: "Album", files: [file])
        await waitUntil { !coordinator.isUploadingInitialFiles }

        #expect(uploader.calls == ["Uncertain.wav"])
        guard case .uncertain(let message) = coordinator.initialFiles.first?.status else {
            Issue.record("Expected an uncertain upload outcome")
            return
        }
        #expect(message.contains("may already exist"))
        #expect(!coordinator.canRetryInitialFiles)
        #expect(api.names.count == 1)
    }

    @Test func cancellingInitialUploadsKeepsConfirmedProjectAndCompletedFiles() async throws {
        let first = try temporaryFile("First.wav")
        let second = try temporaryFile("Second.wav")
        defer {
            for file in [first, second] { try? FileManager.default.removeItem(at: file) }
        }
        let web = StubCreationWeb(libraryResponses: [.success(snapshot())])
        let api = StubProjectAPI(result: .success(project()))
        let uploader = StubFileUploader()
        uploader.delay = .milliseconds(500)
        let coordinator = ProjectCreationCoordinator(api: api, web: web, fileUploader: uploader)

        await coordinator.create(name: "Album", files: [first, second])
        await waitUntil { uploader.calls.count == 1 }
        coordinator.cancelInitialUploads()
        await waitUntil { !coordinator.isUploadingInitialFiles }

        #expect(api.names.count == 1)
        #expect(coordinator.createdProject?.project.id == "project-1")
        #expect(coordinator.initialFiles.map(\.status) == [.cancelled, .cancelled])
    }

    @Test func playerURLRouteMustUseTheExistingSamplyPath() {
        #expect(ProjectCreationCoordinator.routeID(
            from: URL(string: "https://samply.app/p/share-new")!) == "share-new")
        #expect(ProjectCreationCoordinator.routeID(
            from: URL(string: "https://samply.app/p/share%20new")!) == "share new")
        #expect(ProjectCreationCoordinator.routeID(
            from: URL(string: "https://example.com/p/share-new")!) == nil)
        #expect(ProjectCreationCoordinator.routeID(
            from: URL(string: "http://samply.app/p/share-new")!) == nil)
        #expect(ProjectCreationCoordinator.routeID(
            from: URL(string: "https://samply.app/library/share-new")!) == nil)
    }

    private func artworkPayload() -> ProjectArtworkPayload {
        ProjectArtworkPayload(data: Data([1, 2, 3]), fileName: "Cover.jpg",
                              mimeType: "image/jpeg")
    }

    private func temporaryFile(_ name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data([1, 2, 3]).write(to: url)
        return url
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async {
        for _ in 0..<400 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func snapshot(account: String = "account-a", library: [LibraryItem] = [],
                          routeID: String? = nil,
                          projectID: String? = "project-1") -> WebSnapshot {
        WebSnapshot(
            version: 1,
            account: .init(uid: account, name: nil, avatarURL: nil),
            authentication: .signedIn,
            libraryReady: true,
            library: library,
            routeID: routeID,
            projectID: projectID,
            levelID: nil,
            boxesReady: routeID != nil,
            boxes: [],
            playback: nil,
            capabilities: []
        )
    }

    private func project(name: String = "Album",
                         playerURL: URL? = URL(string: "https://samply.app/p/share-1")) -> SamplyProject {
        SamplyProject(id: "project-1", name: name, artwork: nil, timeModified: nil,
                      playerUrl: playerURL)
    }

    private func libraryItem() -> LibraryItem {
        LibraryItem(id: "history-1", name: "Album", projectID: "project-1",
                    playerID: "player-1", shareID: "share-1", artist: "Artist",
                    artwork: nil, canUpload: true, isOwned: true)
    }
}

@MainActor
private final class StubProjectAPI: ProjectCreatingAPI {
    let result: Result<SamplyProject, any Error>
    private(set) var names: [String] = []

    init(result: Result<SamplyProject, any Error>) {
        self.result = result
    }

    func createProject(name: String) async throws -> SamplyProject {
        names.append(name)
        return try result.get()
    }
}

@MainActor
private final class DeferredProjectAPI: ProjectCreatingAPI {
    private(set) var names: [String] = []
    private var continuation: CheckedContinuation<Void, Never>?

    var isSuspended: Bool { continuation != nil }

    func createProject(name: String) async throws -> SamplyProject {
        names.append(name)
        await withCheckedContinuation { continuation = $0 }
        return SamplyProject(id: "project-1", name: name, artwork: nil, timeModified: nil,
                             playerUrl: URL(string: "https://samply.app/p/share-1"))
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class StubFileUploader: ProjectFileUploading {
    var results: [Result<String, any Error>] = []
    var delay: Duration?
    private(set) var calls: [String] = []
    private(set) var progressValues: [Double] = []

    func performUpload(file: URL, projectID: String, parentID: String?,
                       progress: @escaping @MainActor @Sendable (Double) -> Void) async throws -> String {
        calls.append(file.lastPathComponent)
        progress(0.5)
        progressValues.append(0.5)
        if let delay { try await Task.sleep(for: delay) }
        if results.isEmpty { return "box-\(calls.count)" }
        return try results.removeFirst().get()
    }
}

@MainActor
private final class StubCreationWeb: ProjectCreationWebSession {
    var accountID: String? = "account-a"
    var isSigningOut = false
    var libraryResponses: [Result<WebSnapshot, any Error>]
    var browseResponse: (String, [String: Any]) throws -> WebSnapshot
    var artworkResponses: [Result<ProjectCreationCoordinator.ArtworkResult, any Error>] = []
    private(set) var calls: [(command: String, arguments: [String: Any])] = []

    init(libraryResponses: [Result<WebSnapshot, any Error>] = [],
         browseResponse: @escaping (String, [String: Any]) throws -> WebSnapshot = { _, _ in
             throw SamplyError.invalidResponse
         }) {
        self.libraryResponses = libraryResponses
        self.browseResponse = browseResponse
    }

    func call<T: Decodable>(_ command: String, arguments: [String: Any]) async throws -> T {
        calls.append((command, arguments))
        let value: Any
        switch command {
        case "refreshPage":
            guard !libraryResponses.isEmpty else { throw SamplyError.invalidResponse }
            value = try libraryResponses.removeFirst().get()
        case "browse":
            value = try browseResponse(arguments["routeID"] as? String ?? "", arguments)
        case "setProjectArtwork":
            guard !artworkResponses.isEmpty else { throw SamplyError.invalidResponse }
            value = try artworkResponses.removeFirst().get()
        default:
            throw SamplyError.invalidResponse
        }
        guard let typed = value as? T else { throw SamplyError.invalidResponse }
        return typed
    }
}
