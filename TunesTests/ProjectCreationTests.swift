import Foundation
import Testing
@testable import Tunes

@MainActor
@Suite(.serialized)
struct ProjectCreationTests {
    @Test func blankNameIsRejectedBeforeAnyRequest() async {
        let api = StubProjectAPI(result: .success(project()))
        let coordinator = ProjectCreationCoordinator(api: api, web: StubCreationWeb())

        await coordinator.create(name: " \n\t ")

        #expect(api.names.isEmpty)
        #expect(coordinator.state == .failed("Enter a project name."))
    }

    @Test func unicodeNameIsTrimmedButInternalCharactersArePreserved() async {
        let api = StubProjectAPI(result: .success(project(name: "Été – 東京")))
        let web = StubCreationWeb(libraryResponses: [.success(snapshot())])
        let coordinator = ProjectCreationCoordinator(api: api, web: web)

        await coordinator.create(name: "  Été – 東京 \n")

        #expect(api.names == ["Été – 東京"])
        #expect(coordinator.createdProject?.project.name == "Été – 東京")
    }

    @Test func duplicateSubmissionsShareOneRequest() async {
        let api = DeferredProjectAPI()
        let web = StubCreationWeb(libraryResponses: [.success(snapshot())])
        let coordinator = ProjectCreationCoordinator(api: api, web: web)

        let first = Task { await coordinator.create(name: "First") }
        await waitUntil { api.isSuspended }
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
            browseResponse: { routeID in
                #expect(routeID == "share-1")
                return snapshot(routeID: routeID)
            }
        )
        let api = StubProjectAPI(result: .success(project()))
        let coordinator = ProjectCreationCoordinator(api: api, web: web)
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
            browseResponse: { routeID in
                #expect(routeID == "share-from-url")
                return snapshot(routeID: routeID)
            }
        )
        let api = StubProjectAPI(result: .success(project(playerURL: playerURL)))
        let coordinator = ProjectCreationCoordinator(api: api, web: web)
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
            browseResponse: { routeID in snapshot(routeID: routeID) }
        )
        let api = StubProjectAPI(result: .success(project()))
        let coordinator = ProjectCreationCoordinator(api: api, web: web)

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

    @Test func ambiguousNetworkFailureIsNeverResubmitted() async {
        let web = StubCreationWeb(libraryResponses: [.success(snapshot())])
        let api = StubProjectAPI(result: .failure(URLError(.timedOut)))
        let coordinator = ProjectCreationCoordinator(api: api, web: web)

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
    }

    @Test func staleCompletionIsIgnoredAfterAccountChange() async {
        let api = DeferredProjectAPI()
        let web = StubCreationWeb()
        let coordinator = ProjectCreationCoordinator(api: api, web: web)
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

    private func waitUntil(_ predicate: @MainActor () -> Bool) async {
        for _ in 0..<400 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func snapshot(account: String = "account-a", library: [LibraryItem] = [],
                          routeID: String? = nil) -> WebSnapshot {
        WebSnapshot(
            version: 1,
            account: .init(uid: account, name: nil, avatarURL: nil),
            authentication: .signedIn,
            libraryReady: true,
            library: library,
            routeID: routeID,
            projectID: nil,
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
private final class StubCreationWeb: ProjectCreationWebSession {
    var accountID: String? = "account-a"
    var isSigningOut = false
    var libraryResponses: [Result<WebSnapshot, any Error>]
    var browseResponse: (String) throws -> WebSnapshot
    private(set) var calls: [(command: String, arguments: [String: Any])] = []

    init(libraryResponses: [Result<WebSnapshot, any Error>] = [],
         browseResponse: @escaping (String) throws -> WebSnapshot = { _ in
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
            value = try browseResponse(arguments["routeID"] as? String ?? "")
        default:
            throw SamplyError.invalidResponse
        }
        guard let typed = value as? T else { throw SamplyError.invalidResponse }
        return typed
    }
}
