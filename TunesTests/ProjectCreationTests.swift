import Foundation
import Testing
@testable import Tunes

@MainActor
@Suite(.serialized)
struct ProjectCreationTests {
    @Test func blankNameIsRejectedBeforeAnyRequest() async {
        let api = StubProjectAPI(result: .success(project()))
        let coordinator = makeCoordinator(api: api, web: StubCreationWeb())

        await coordinator.create(name: " \n\t ")

        #expect(api.names.isEmpty)
        #expect(coordinator.state == .failed("Enter a project name."))
    }

    @Test func unicodeNameIsTrimmedButInternalCharactersArePreserved() async {
        let api = StubProjectAPI(result: .success(project(name: "Été – 東京")))
        let web = StubCreationWeb(libraryResponses: [.success(snapshot())])
        let coordinator = makeCoordinator(api: api, web: web)

        await coordinator.create(name: "  Été – 東京 \n")

        #expect(api.names == ["Été – 東京"])
        #expect(api.tokens == ["fixture-token"])
        #expect(coordinator.createdProject?.project.name == "Été – 東京")
    }

    @Test func mismatchedOrUnverifiableCredentialStartsNoCreationRequest() async {
        for state in [
            ProjectCredentialState.rejected("The token belongs to another account."),
            .identityUnverifiable("No owned project proves token identity.")
        ] {
            let credentials = StubCredentials()
            credentials.state = state
            credentials.isVerified = false
            let api = StubProjectAPI(result: .success(project()))
            let coordinator = ProjectCreationCoordinator(
                api: api, web: StubCreationWeb(), uploader: StubAssetUploader(),
                credentials: credentials)

            await coordinator.create(name: "Album")

            #expect(api.names.isEmpty)
            guard case .failed(let message) = coordinator.state else {
                Issue.record("Expected creation to be blocked before the request")
                return
            }
            switch state {
            case .rejected(let expected), .identityUnverifiable(let expected):
                #expect(message == expected)
            default:
                break
            }
        }
    }

    @Test func duplicateSubmissionsShareOneRequest() async {
        let api = DeferredProjectAPI()
        let web = StubCreationWeb(libraryResponses: [.success(snapshot())])
        let coordinator = makeCoordinator(api: api, web: web)

        let first = Task { await coordinator.create(name: "First") }
        await waitUntil { api.pendingCount == 1 }
        #expect(coordinator.blocksDismissal)
        let second = Task { await coordinator.create(name: "Second") }
        await Task.yield()
        #expect(api.names == ["First"])

        api.complete(0, with: .success(project()))
        await first.value
        await second.value
        #expect(api.names == ["First"])
    }

    @Test func completeLibraryIsRefreshedWithoutLeavingTheLibrary() async {
        let item = libraryItem()
        let shared = sharedItem()
        let web = StubCreationWeb(
            libraryResponses: [.success(snapshot(library: [item, shared]))],
            browseResponse: { routeID, _ in
                Issue.record("Creation must not navigate to the project")
                return snapshot(routeID: routeID)
            }
        )
        let api = StubProjectAPI(result: .success(project()))
        let coordinator = makeCoordinator(api: api, web: web)
        var refreshed: [LibraryItem] = []
        var opened: (LibraryItem, WebSnapshot)?
        coordinator.onLibraryRefreshed = { refreshed = $0 }
        coordinator.onProjectOpened = { opened = ($0, $1) }

        await coordinator.create(name: "  Album  ")

        #expect(api.names == ["Album"])
        #expect(web.calls.map(\.command) == ["refreshPage"])
        #expect(web.calls[0].arguments["page"] as? String == "library")
        #expect(refreshed == [item, shared])
        #expect(coordinator.createdStage == .visible)
        #expect(coordinator.createdProject?.libraryItem == item)
        #expect(opened == nil)
        #expect(!coordinator.isBackgroundWorkRunning)
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
        let coordinator = makeCoordinator(api: api, web: web)
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
        let coordinator = makeCoordinator(api: api, web: web)

        await coordinator.create(name: "Album")

        #expect(api.names.count == 1)
        #expect(coordinator.createdProject?.project.id == "project-1")
        guard case .created(_, .refreshFailed(let message)) = coordinator.state else {
            Issue.record("Expected a confirmed creation with a refresh failure")
            return
        }
        #expect(message.contains("Project created"))
        #expect(web.calls.filter { $0.command == "browse" }.isEmpty)

        await coordinator.refreshLibrary()

        #expect(api.names.count == 1)
        #expect(coordinator.createdStage == .visible)
        #expect(web.calls.filter { $0.command == "refreshPage" }.count == 2)
    }

    @Test func closingDuringRefreshDelayOrFailurePreservesRecovery() async {
        // Refresh in flight.
        let refreshWeb = StubCreationWeb(libraryResponses: [.success(snapshot())])
        refreshWeb.gateNextRefresh()
        let refreshCoordinator = makeCoordinator(api: StubProjectAPI(result: .success(project())),
                                                 web: refreshWeb)
        let refreshTask = Task { await refreshCoordinator.create(name: "Refresh") }
        await waitUntil { refreshWeb.isRefreshGated }
        refreshCoordinator.sheetDidDisappear()
        #expect(refreshCoordinator.createdProject != nil)
        refreshWeb.releaseRefresh()
        await refreshTask.value
        #expect(refreshCoordinator.createdProject?.project.id == "project-1")

        // Delayed Library propagation.
        let delayed = makeCoordinator(
            api: StubProjectAPI(result: .success(project())),
            web: StubCreationWeb(libraryResponses: [.success(snapshot())]))
        await delayed.create(name: "Delayed")
        #expect(delayed.createdStage == .delayed)
        delayed.sheetDidDisappear()
        #expect(delayed.createdProject?.project.id == "project-1")

        // Refresh failure.
        let failed = makeCoordinator(
            api: StubProjectAPI(result: .success(project())),
            web: StubCreationWeb(libraryResponses: [.failure(URLError(.timedOut))]))
        await failed.create(name: "Failed")
        guard case .created(_, .refreshFailed) = failed.state else {
            Issue.record("Expected a refresh failure")
            return
        }
        failed.sheetDidDisappear()
        #expect(failed.createdProject?.project.id == "project-1")
    }

    @Test func recoveryActionsDoNotRepeatCreation() async {
        let item = libraryItem()
        let web = StubCreationWeb(
            libraryResponses: [
                .failure(URLError(.cannotConnectToHost)),
                .success(snapshot(library: [item]))
            ],
            browseResponse: { routeID, _ in snapshot(routeID: routeID) })
        let api = StubProjectAPI(result: .success(project()))
        let coordinator = makeCoordinator(api: api, web: web)
        await coordinator.create(name: "Album")
        coordinator.sheetDidDisappear()
        #expect(coordinator.createdProject != nil)

        await coordinator.refreshLibrary()
        #expect(coordinator.createdStage == .visible)
        await coordinator.openCreatedProject()
        #expect(coordinator.createdStage == .opened)
        #expect(api.names.count == 1)
    }

    @Test func interruptedRefreshRetainsProjectUntilAbandoned() async {
        let web = StubCreationWeb(libraryResponses: [.failure(CancellationError())])
        let api = StubProjectAPI(result: .success(project()))
        let coordinator = makeCoordinator(api: api, web: web)

        await coordinator.create(name: "Album")

        #expect(api.names.count == 1)
        #expect(coordinator.createdProject?.project.id == "project-1")
        guard case .created(_, .refreshFailed(let message)) = coordinator.state else {
            Issue.record("Expected an interrupted refresh to remain a created state")
            return
        }
        #expect(message.contains("interrupted"))
        #expect(!coordinator.blocksDismissal)
        #expect(coordinator.canRefreshCreatedProject)
        #expect(!coordinator.canAbandonConfirmedCreation)

        coordinator.sheetDidDisappear()
        #expect(coordinator.createdProject?.project.id == "project-1")
    }

    @Test func ambiguousNetworkFailureIsNeverResubmitted() async {
        let web = StubCreationWeb(libraryResponses: [.success(snapshot())])
        let api = StubProjectAPI(result: .failure(URLError(.timedOut)))
        let coordinator = makeCoordinator(api: api, web: web)

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
        let credentials = StubCredentials()
        let web = StubCreationWeb()
        let coordinator = makeCoordinator(api: api, web: web, credentials: credentials)
        var refreshed = false
        coordinator.onLibraryRefreshed = { _ in refreshed = true }

        let task = Task { await coordinator.create(name: "Album") }
        await waitUntil { api.pendingCount == 1 }
        credentials.moveToAccount("account-b")
        web.accountID = "account-b"
        coordinator.invalidate()
        api.complete(0, with: .success(project()))
        await task.value

        #expect(coordinator.state == .idle)
        #expect(!refreshed)
        #expect(api.names.count == 1)
    }

    @Test func credentialReplacementDuringCreationRetainsResultButStartsNoOptionalWrites() async throws {
        let file = try temporaryFile("Replaced.wav")
        defer { try? FileManager.default.removeItem(at: file) }
        let api = DeferredProjectAPI()
        let credentials = StubCredentials()
        let uploader = StubAssetUploader()
        let coordinator = makeCoordinator(
            api: api, web: StubCreationWeb(libraryResponses: [.success(snapshot(library: [libraryItem()]))]),
            uploader: uploader, credentials: credentials)
        let creating = Task {
            await coordinator.create(name: "Album", artwork: artworkPayload(), files: [file])
        }
        await waitUntil { api.pendingCount == 1 }

        credentials.replaceToken("replacement-token")
        api.complete(0, with: .success(project()))
        await creating.value
        await waitUntil { !coordinator.isBackgroundWorkRunning }

        #expect(coordinator.createdProject?.project.id == "project-1")
        #expect(coordinator.createdStage == .visible)
        #expect(uploader.calls.isEmpty)
        #expect(uploader.artworkCalls == 0)
        #expect(coordinator.initialFiles.first?.status ==
            .failed(message: "Not uploaded because token verification changed.", retryable: true))
        guard case .failed(_, true) = coordinator.artworkState else {
            Issue.record("Artwork should be retryable after re-verifying the replacement token")
            return
        }
    }

    @Test func oldTaskCompletionCannotModifyANewerOperation() async {
        let api = DeferredProjectAPI()
        let web = StubCreationWeb(libraryResponses: [.success(snapshot())])
        let coordinator = makeCoordinator(api: api, web: web)

        let first = Task { await coordinator.create(name: "First") }
        await waitUntil { api.pendingCount == 1 }
        coordinator.invalidate()
        let second = Task { await coordinator.create(name: "Second") }
        await waitUntil { api.pendingCount == 2 }

        api.complete(0, with: .success(project(name: "Stale")))
        await first.value
        #expect(coordinator.state == .creating)

        api.complete(0, with: .success(project(name: "Second")))
        await second.value
        #expect(coordinator.createdProject?.project.name == "Second")
        #expect(api.names == ["First", "Second"])
    }

    @Test func creationIdentityMismatchQuarantinesAndStartsNoOptionalWrites() async throws {
        let file = try temporaryFile("Skipped.wav")
        defer { try? FileManager.default.removeItem(at: file) }
        let uploader = StubAssetUploader()
        let web = StubCreationWeb(libraryResponses: [.success(snapshot())])
        let api = StubProjectAPI(result: .success(project(creatorUID: "someone-else")))
        let coordinator = makeCoordinator(api: api, web: web, uploader: uploader)

        await coordinator.create(name: "Album", artwork: artworkPayload(), files: [file])
        await waitUntil { !coordinator.isBackgroundWorkRunning }

        #expect(api.names.count == 1)
        #expect(uploader.calls.isEmpty)
        #expect(uploader.artworkCalls == 0)
        #expect(coordinator.artworkState == .none)
        #expect(coordinator.initialFiles.isEmpty)
        guard case .created(_, .quarantined(let message)) = coordinator.state else {
            Issue.record("Expected a quarantined creation result")
            return
        }
        #expect(message.contains("may exist"))
        #expect(message.contains("someone-else"))
        #expect(!coordinator.canOpenCreatedProject)
        #expect(web.calls.isEmpty)
    }

    @Test func missingCreatorIdentityAlsoQuarantinesWithoutOptionalWrites() async {
        let uploader = StubAssetUploader()
        let coordinator = makeCoordinator(
            api: StubProjectAPI(result: .success(project(creatorUID: nil))),
            web: StubCreationWeb(libraryResponses: [.success(snapshot())]),
            uploader: uploader)

        await coordinator.create(name: "Album", artwork: artworkPayload(),
                                 files: [URL(fileURLWithPath: "/tmp/missing.wav")])

        guard case .created(_, .quarantined(let message)) = coordinator.state else {
            Issue.record("A missing creator UID must quarantine the creation")
            return
        }
        #expect(message.contains("did not include a creator UID"))
        #expect(uploader.calls.isEmpty)
        #expect(uploader.artworkCalls == 0)
        #expect(coordinator.initialFiles.isEmpty)
    }

    @Test func quarantinedProjectRemainsNonOpenableAfterRefreshFailure() async {
        let web = StubCreationWeb(libraryResponses: [.failure(URLError(.cannotConnectToHost))])
        let coordinator = makeCoordinator(
            api: StubProjectAPI(result: .success(project(creatorUID: "other-account"))),
            web: web)
        await coordinator.create(name: "Album")
        #expect(coordinator.isQuarantined)

        await coordinator.refreshLibrary()

        #expect(coordinator.isQuarantined)
        #expect(!coordinator.canOpenCreatedProject)
        guard case .created(_, .quarantined(let message)) = coordinator.state else {
            Issue.record("A failed quarantine refresh must preserve the quarantine stage")
            return
        }
        #expect(message.contains("may exist"))
    }

    @Test func quarantineDoesNotBecomeOpenableWhenLibraryStillOmitsTheProject() async {
        let coordinator = makeCoordinator(
            api: StubProjectAPI(result: .success(project(creatorUID: "other-account"))),
            web: StubCreationWeb(libraryResponses: [.success(snapshot())]))
        await coordinator.create(name: "Album")

        await coordinator.refreshLibrary()

        #expect(coordinator.isQuarantined)
        #expect(!coordinator.canOpenCreatedProject)
        #expect(coordinator.createdProject != nil)
    }

    @Test func libraryNoticeExposesRecoveryForADelayedProject() async {
        let coordinator = makeCoordinator(
            api: StubProjectAPI(result: .success(project())),
            web: StubCreationWeb(libraryResponses: [.success(snapshot())]))
        await coordinator.create(name: "Album")
        #expect(coordinator.createdStage == .delayed)

        let notice = SamplyBackend.creationNotice(for: coordinator)
        #expect(notice != nil)
        #expect(notice?.message.contains("has not appeared in the Library") == true)
        #expect(notice?.canRefreshLibrary == true)
        #expect(notice?.canOpenProject == true)
        #expect(notice?.canStartNewProject == false)
    }

    @Test func libraryNoticeNamesQuarantineAndOffersOnlyReadOrAbandonmentActions() async {
        let coordinator = makeCoordinator(
            api: StubProjectAPI(result: .success(project(creatorUID: "other-account"))),
            web: StubCreationWeb(libraryResponses: [.success(snapshot())]))
        await coordinator.create(name: "Album")

        let notice = SamplyBackend.creationNotice(for: coordinator)
        #expect(notice?.message.contains("may exist") == true)
        #expect(notice?.canRefreshLibrary == true)
        #expect(notice?.canOpenProject == false)
        #expect(notice?.canStartNewProject == true)
    }

    @Test func accountChangeBeforeArtworkSubmissionPreventsSubmission() async {
        let uploader = StubAssetUploader()
        uploader.gateNextArtwork = true
        let credentials = StubCredentials()
        let web = StubCreationWeb(libraryResponses: [.success(snapshot())])
        let coordinator = makeCoordinator(
            api: StubProjectAPI(result: .success(project())), web: web,
            uploader: uploader, credentials: credentials)

        let task = Task { await coordinator.create(name: "Album", artwork: artworkPayload()) }
        await waitUntil { uploader.isArtworkGated }
        credentials.moveToAccount("account-b")
        web.accountID = "account-b"
        coordinator.invalidate()
        uploader.releaseArtwork()
        await task.value

        #expect(uploader.artworkSubmissions == 0)
        #expect(coordinator.state == .idle)
    }

    @Test func successfulCreationOrderedUploadsAndPartialSuccessRetainExistingBehavior() async throws {
        let first = try temporaryFile("01 First.wav")
        let second = try temporaryFile("02 Second.wav")
        let third = try temporaryFile("03 Third.wav")
        defer {
            for file in [first, second, third] { try? FileManager.default.removeItem(at: file) }
        }
        let item = libraryItem()
        let web = StubCreationWeb(libraryResponses: [.success(snapshot(library: [item]))])
        let api = StubProjectAPI(result: .success(project()))
        let uploader = StubAssetUploader()
        uploader.results = [
            .submitted(ticket(boxID: "box-1", fileName: "01 First.wav")),
            .failed("Samply rejected the upload request (HTTP 403).", phase: .waiting),
            .submitted(ticket(boxID: "box-3", fileName: "03 Third.wav")),
            .submitted(ticket(boxID: "box-2", fileName: "02 Second.wav"))
        ]
        let coordinator = makeCoordinator(api: api, web: web, uploader: uploader)

        await coordinator.create(name: "Album", files: [first, second, third])
        await waitUntil { !coordinator.isUploadingInitialFiles }

        #expect(uploader.calls == ["01 First.wav", "02 Second.wav", "03 Third.wav"])
        #expect(coordinator.initialFiles.map(\.status) == [
            .uploaded(boxID: "box-1"),
            .failed(message: "Samply rejected the upload request (HTTP 403).", retryable: true),
            .uploaded(boxID: "box-3")
        ])
        #expect(coordinator.canRetryInitialFiles)
        #expect(coordinator.createdStage == .visible)

        coordinator.retryFailedInitialFiles()
        await waitUntil { !coordinator.isUploadingInitialFiles }

        #expect(uploader.calls == ["01 First.wav", "02 Second.wav", "03 Third.wav", "02 Second.wav"])
        #expect(coordinator.initialFiles.map(\.status) == [
            .uploaded(boxID: "box-1"),
            .uploaded(boxID: "box-2"),
            .uploaded(boxID: "box-3")
        ])
        #expect(api.names == ["Album"])
    }

    @Test func initialUploadsDoNotRequireProjectNavigation() async throws {
        let file = try temporaryFile("Initial Mix.wav")
        defer { try? FileManager.default.removeItem(at: file) }
        let item = libraryItem()
        let web = StubCreationWeb(
            libraryResponses: [.success(snapshot(library: [item]))],
            browseResponse: { _, _ in
                Issue.record("Project creation must not navigate")
                throw SamplyError.invalidResponse
            }
        )
        let api = StubProjectAPI(result: .success(project()))
        let coordinator = makeCoordinator(api: api, web: web)

        await coordinator.create(name: "Album", files: [file])
        await waitUntil { !coordinator.isUploadingInitialFiles }

        #expect(coordinator.initialFiles.first?.status == .uploaded(boxID: "box-1"))
        #expect(api.names.count == 1)
        #expect(web.calls.map(\.command) == ["refreshPage"])
        #expect(coordinator.createdStage == .visible)
    }

    @Test func failedUploadCanBeDeliberatelyAbandonedAfterTheProjectAppeared() async throws {
        let file = try temporaryFile("Failed Mix.wav")
        defer { try? FileManager.default.removeItem(at: file) }
        let web = StubCreationWeb(libraryResponses: [.success(snapshot(library: [libraryItem()]))])
        let api = StubProjectAPI(result: .success(project()))
        let uploader = StubAssetUploader()
        uploader.results = [.failed("Samply rejected the upload request (HTTP 403).", phase: .waiting)]
        let coordinator = makeCoordinator(api: api, web: web, uploader: uploader)

        await coordinator.create(name: "Album")
        #expect(coordinator.addFiles([file]))
        await waitUntil { !coordinator.isUploadingInitialFiles }

        #expect(coordinator.hasUnresolvedInitialFiles)
        #expect(!coordinator.canFinishCreatedProject)
        #expect(coordinator.canAbandonConfirmedCreation)
        coordinator.discardConfirmedCreation()
        #expect(coordinator.state == .idle)
        #expect(api.names == ["Album"])
    }

    @Test func accountChangeStopsPendingInitialUploads() async throws {
        let file = try temporaryFile("Pending.wav")
        defer { try? FileManager.default.removeItem(at: file) }
        let credentials = StubCredentials()
        let web = StubCreationWeb(libraryResponses: [.success(snapshot())])
        let api = StubProjectAPI(result: .success(project()))
        let uploader = StubAssetUploader()
        uploader.gateNextUpload = true
        let coordinator = makeCoordinator(api: api, web: web, uploader: uploader,
                                          credentials: credentials)

        await coordinator.create(name: "Album", files: [file])
        await waitUntil { uploader.isUploadGated }
        credentials.moveToAccount("account-b")
        web.accountID = "account-b"
        coordinator.invalidate()
        uploader.releaseUpload()
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
        let uploader = StubAssetUploader()
        uploader.results = [.uncertain("Samply may have created a ticket.",
                                       phase: .ticketRequested)]
        let coordinator = makeCoordinator(api: api, web: web, uploader: uploader)

        await coordinator.create(name: "Album", files: [file])
        await waitUntil { !coordinator.isUploadingInitialFiles }

        #expect(uploader.calls == ["Uncertain.wav"])
        guard case .uncertain(let message, nil) = coordinator.initialFiles.first?.status else {
            Issue.record("Expected an uncertain upload outcome")
            return
        }
        #expect(message.contains("ticket"))
        #expect(!coordinator.canRetryInitialFiles)
        coordinator.retryFailedInitialFiles()
        #expect(uploader.calls == ["Uncertain.wav"])
        #expect(api.names.count == 1)
    }

    @Test func cancellationBeforeSubmissionIsSafelyRetryable() async throws {
        let file = try temporaryFile("Before.wav")
        defer { try? FileManager.default.removeItem(at: file) }
        let web = StubCreationWeb(libraryResponses: [.success(snapshot())])
        let uploader = StubAssetUploader()
        uploader.results = [.cancelled(.waiting)]
        let coordinator = makeCoordinator(api: StubProjectAPI(result: .success(project())),
                                          web: web, uploader: uploader)

        await coordinator.create(name: "Album", files: [file])
        await waitUntil { !coordinator.isUploadingInitialFiles }

        #expect(coordinator.initialFiles.first?.status ==
            .cancelled(retryable: true, boxID: nil))
        #expect(coordinator.canRetryInitialFiles)
    }

    @Test func cancellationDuringPUTRemainsUncertainAndIsNotBlindlyRetried() async throws {
        let file = try temporaryFile("During.wav")
        defer { try? FileManager.default.removeItem(at: file) }
        let web = StubCreationWeb(libraryResponses: [.success(snapshot())])
        let uploader = StubAssetUploader()
        uploader.results = [.cancelled(.putStarted,
                                       ticket: ticket(boxID: "box-during", fileName: "During.wav"))]
        let coordinator = makeCoordinator(api: StubProjectAPI(result: .success(project())),
                                          web: web, uploader: uploader)

        await coordinator.create(name: "Album", files: [file])
        await waitUntil { !coordinator.isUploadingInitialFiles }

        #expect(coordinator.initialFiles.first?.status ==
            .cancelled(retryable: false, boxID: "box-during"))
        #expect(!coordinator.canRetryInitialFiles)
        #expect(coordinator.hasUncertainInitialFiles)
    }

    @Test func successfulPUTRacingCancellationRetainsSuccess() async throws {
        let file = try temporaryFile("Racing.wav")
        defer { try? FileManager.default.removeItem(at: file) }
        let web = StubCreationWeb(libraryResponses: [.success(snapshot())])
        let uploader = StubAssetUploader()
        uploader.gateNextUpload = true
        uploader.results = [.submitted(ticket(boxID: "box-racing", fileName: "Racing.wav"))]
        let coordinator = makeCoordinator(api: StubProjectAPI(result: .success(project())),
                                          web: web, uploader: uploader)

        await coordinator.create(name: "Album", files: [file])
        await waitUntil { uploader.isUploadGated }
        coordinator.cancelInitialUploads()
        uploader.releaseUpload()
        await waitUntil { !coordinator.isUploadingInitialFiles }

        #expect(coordinator.initialFiles.first?.status == .uploaded(boxID: "box-racing"))
        #expect(coordinator.createdProject?.project.id == "project-1")
    }

    @Test func queuedCancellationStopsLaterFilesAndKeepsConfirmedOnes() async throws {
        let first = try temporaryFile("First.wav")
        let second = try temporaryFile("Second.wav")
        defer {
            for file in [first, second] { try? FileManager.default.removeItem(at: file) }
        }
        let web = StubCreationWeb(libraryResponses: [.success(snapshot())])
        let uploader = StubAssetUploader()
        uploader.gateNextUpload = true
        uploader.results = [.submitted(ticket(boxID: "box-first", fileName: "First.wav"))]
        let coordinator = makeCoordinator(api: StubProjectAPI(result: .success(project())),
                                          web: web, uploader: uploader)

        await coordinator.create(name: "Album", files: [first, second])
        await waitUntil { uploader.isUploadGated }
        coordinator.cancelInitialUploads()
        uploader.releaseUpload()
        await waitUntil { !coordinator.isUploadingInitialFiles }

        #expect(coordinator.initialFiles.map(\.status) == [
            .uploaded(boxID: "box-first"),
            .cancelled(retryable: true, boxID: nil)
        ])
        #expect(uploader.calls == ["First.wav"])
    }

    @Test func everyArtworkTimeoutPhaseEndsUnresolvedInsteadOfPending() async {
        let cases: [UploadOutcome] = [
            .uncertain("ticket timed out", phase: .ticketRequested),
            .uncertain("PUT timed out", phase: .putStarted,
                       ticket: ticket(boxID: "art-box", kind: .artwork,
                                      fileName: "Cover.jpg"))
        ]
        for outcome in cases {
            let uploader = StubAssetUploader()
            uploader.artworkResults = [outcome]
            let coordinator = makeCoordinator(
                api: StubProjectAPI(result: .success(project())),
                web: StubCreationWeb(libraryResponses: [.success(snapshot())]),
                uploader: uploader)

            await coordinator.create(name: "Album", artwork: artworkPayload())
            await waitUntil { !coordinator.artworkState.isBusy && coordinator.artworkState != .none }

            #expect(!coordinator.artworkState.isBusy)
            guard case .unresolved(_, let message) = coordinator.artworkState else {
                Issue.record("Expected an unresolved artwork phase, got \(coordinator.artworkState)")
                return
            }
            #expect(!message.isEmpty)
            #expect(!coordinator.canRetryArtwork)
        }
    }

    @Test func successfulArtworkPUTNeverClaimsUnprovenAssignment() async {
        let uploader = StubAssetUploader()
        uploader.artworkResults = [
            .submitted(ticket(boxID: "art-box", kind: .artwork, fileName: "Cover.jpg"))
        ]
        let api = StubProjectAPI(result: .success(project()))
        let coordinator = makeCoordinator(
            api: api,
            web: StubCreationWeb(libraryResponses: [
                .success(snapshot(library: [libraryItem()])),
                .success(snapshot(library: [libraryItem()]))
            ]),
            uploader: uploader)

        await coordinator.create(name: "Album", artwork: artworkPayload())
        await waitUntil { !coordinator.artworkState.isBusy && coordinator.artworkState != .none }

        #expect(coordinator.artworkState == .submitted(boxID: "art-box"))
        if case .confirmedAssigned = coordinator.artworkState {
            Issue.record("A successful PUT must not prove exact artwork assignment")
        }
        #expect(coordinator.hasUnresolvedArtwork)
        #expect(!coordinator.canRetryArtwork)
        #expect(!coordinator.canFinishCreatedProject)
        await coordinator.refreshLibrary()
        coordinator.sheetDidDisappear()
        coordinator.prepareForPresentation()
        coordinator.reset()
        #expect(coordinator.artworkState == .submitted(boxID: "art-box"))
        #expect(coordinator.createdProject != nil)
        #expect(coordinator.canAbandonConfirmedCreation)
        coordinator.discardConfirmedCreation()
        #expect(coordinator.state == .idle)
        #expect(coordinator.artworkState == .none)
        #expect(api.names == ["Album"])
        #expect(uploader.artworkCalls == 1)
    }

    @Test func artworkFailureBeforeSubmissionIsRetryableWithoutAnotherCreate() async {
        let uploader = StubAssetUploader()
        uploader.artworkResults = [
            .failed("Samply rejected the artwork request (HTTP 403).", phase: .waiting),
            .submitted(ticket(boxID: "art-box", kind: .artwork, fileName: "Cover.jpg"))
        ]
        let api = StubProjectAPI(result: .success(project()))
        let coordinator = makeCoordinator(
            api: api, web: StubCreationWeb(libraryResponses: [.success(snapshot())]),
            uploader: uploader)

        await coordinator.create(name: "Album", artwork: artworkPayload())
        await waitUntil {
            if case .failed = coordinator.artworkState { return true }
            return false
        }
        #expect(coordinator.canRetryArtwork)
        #expect(api.names.count == 1)

        coordinator.retryArtwork()
        await waitUntil { coordinator.artworkState == .submitted(boxID: "art-box") }
        #expect(api.names.count == 1)
        #expect(uploader.artworkCalls == 2)
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

    @Test func filesCanStartWhileInitialLibraryRefreshIsGated() async throws {
        let file = try temporaryFile("DuringRefresh.wav")
        defer { try? FileManager.default.removeItem(at: file) }
        let web = StubCreationWeb(libraryResponses: [.success(snapshot(library: [libraryItem()]))])
        web.gateNextRefresh()
        let api = StubProjectAPI(result: .success(project()))
        let uploader = StubAssetUploader()
        uploader.gateNextUpload = true
        let credentials = StubCredentials()
        let coordinator = makeCoordinator(api: api, web: web, uploader: uploader,
                                          credentials: credentials)
        let creating = Task { await coordinator.create(name: "Album") }
        await waitUntil { web.isRefreshGated }
        #expect(web.isRefreshGated)
        #expect(coordinator.createdStage == .refreshing)

        #expect(coordinator.addFiles([file]))
        await waitUntil { uploader.isUploadGated }
        #expect(uploader.isUploadGated)
        #expect(!coordinator.addFiles([file]))
        uploader.releaseUpload()
        await waitUntil { !coordinator.isUploadingInitialFiles }
        #expect(coordinator.initialFiles.first?.status == .uploaded(boxID: "box-1"))
        #expect(coordinator.createdStage == .refreshing)
        #expect(web.isRefreshGated)

        credentials.isVerified = false
        #expect(!coordinator.addFiles([URL(fileURLWithPath: "/tmp/blocked.wav")]))
        credentials.isVerified = true
        credentials.accountID = "account-b"
        #expect(!coordinator.addFiles([URL(fileURLWithPath: "/tmp/blocked.wav")]))
        web.releaseRefresh()
        await creating.value
        #expect(api.names == ["Album"])
        #expect(coordinator.createdStage == .visible)
        #expect(uploader.calls == ["DuringRefresh.wav"])
    }

    @Test func tokenReplacementLeavesNeverSubmittedFilesRetryable() async throws {
        let files = [try temporaryFile("First.wav"), try temporaryFile("Waiting.wav")]
        defer { files.forEach { try? FileManager.default.removeItem(at: $0) } }
        let credentials = StubCredentials()
        let uploader = StubAssetUploader()
        uploader.gateNextUpload = true
        let api = StubProjectAPI(result: .success(project()))
        let coordinator = makeCoordinator(
            api: api, web: StubCreationWeb(libraryResponses: [.success(snapshot())]),
            uploader: uploader, credentials: credentials)
        await coordinator.create(name: "Album", files: files)
        await waitUntil { uploader.isUploadGated }
        #expect(uploader.isUploadGated)

        // Exercise revision invalidation without relying on the backend's
        // additional cancellation notification.
        credentials.replaceToken("replacement-token")
        uploader.releaseUpload()
        await waitUntil { !coordinator.isUploadingInitialFiles }
        #expect(uploader.calls == ["First.wav"])
        #expect(coordinator.initialFiles.allSatisfy(\.isRetryable))
        #expect(coordinator.canRetryInitialFiles)

        coordinator.retryFailedInitialFiles()
        await waitUntil { !coordinator.isUploadingInitialFiles }
        #expect(uploader.calls == ["First.wav", "First.wav", "Waiting.wav"])
        #expect(coordinator.initialFiles.allSatisfy {
            if case .uploaded = $0.status { return true }
            return false
        })
        #expect(api.names == ["Album"])
    }

    @Test func quarantineRequiresExplicitAcknowledgementAndNeverRepeatsCreation() async {
        for creator in [String?.none, "other-account"] {
            for appearsInLibrary in [false, true] {
                let api = StubProjectAPI(result: .success(project(creatorUID: creator)))
                let uploader = StubAssetUploader()
                let web = StubCreationWeb(libraryResponses: [
                    .success(snapshot(library: appearsInLibrary ? [libraryItem()] : []))
                ])
                let coordinator = makeCoordinator(api: api, web: web, uploader: uploader)
                await coordinator.create(name: "Album")
                coordinator.sheetDidDisappear()
                coordinator.prepareForPresentation()
                coordinator.reset()
                #expect(coordinator.isQuarantined)
                #expect(coordinator.canAbandonConfirmedCreation)
                #expect(!coordinator.addFiles([URL(fileURLWithPath: "/tmp/blocked.wav")]))
                await coordinator.refreshLibrary()
                #expect(coordinator.isQuarantined)
                #expect(coordinator.hasAppearedInLibrary == appearsInLibrary)
                #expect(!coordinator.canOpenCreatedProject)
                #expect(!coordinator.canRetryArtwork)
                #expect(!coordinator.canRetryInitialFiles)
                await coordinator.create(name: "Must not repeat")
                #expect(api.names == ["Album"])

                coordinator.discardConfirmedCreation()
                #expect(coordinator.state == .idle)
                #expect(api.names == ["Album"])
                #expect(uploader.calls.isEmpty)
                #expect(uploader.artworkCalls == 0)
                #expect(web.calls.map(\.command) == ["refreshPage"])
            }
        }
    }

    private func makeCoordinator(api: any ProjectCreatingAPI,
                                 web: StubCreationWeb,
                                 uploader: StubAssetUploader? = nil,
                                 credentials: StubCredentials? = nil)
        -> ProjectCreationCoordinator {
        ProjectCreationCoordinator(api: api, web: web,
                                   uploader: uploader ?? StubAssetUploader(),
                                   credentials: credentials ?? StubCredentials())
    }

    private func artworkPayload() -> ProjectArtworkPayload {
        ProjectArtworkPayload(data: Data([1, 2, 3]), fileName: "Cover.jpg",
                              mimeType: "image/jpeg")
    }

    private func ticket(boxID: String, kind: UploadKind = .originalFile,
                        fileName: String = "file.wav") -> UploadTicketIdentity {
        UploadTicketIdentity(boxID: boxID, projectID: "project-1",
                             fileName: fileName, kind: kind)
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
        for _ in 0..<800 {
            if predicate() { return }
            await Task.yield()
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
                         playerURL: URL? = URL(string: "https://samply.app/p/share-1"),
                         creatorUID: String? = "account-a") -> SamplyProject {
        SamplyProject(id: "project-1", name: name, artwork: nil, timeModified: nil,
                      playerUrl: playerURL,
                      creator: creatorUID.map { SamplyProjectCreator(uid: $0) })
    }

    private func libraryItem() -> LibraryItem {
        LibraryItem(id: "history-1", name: "Album", projectID: "project-1",
                    playerID: "player-1", shareID: "share-1", artist: "Artist",
                    artwork: nil, canUpload: true, isOwned: true)
    }

    private func sharedItem() -> LibraryItem {
        LibraryItem(id: "history-shared", name: "Shared Album", projectID: "project-shared",
                    playerID: "player-shared", shareID: "share-shared", artist: "Friend",
                    artwork: nil, canUpload: false, isOwned: false)
    }
}

@MainActor
private final class StubCredentials: ProjectCredentialProviding {
    var state: ProjectCredentialState
    var accountID: String?
    var sessionGeneration: UInt64 = 1
    var credentialRevision: UInt64 = 1
    var hasStoredToken = true
    var isVerified = true
    var token: String

    init(accountID: String = "account-a", token: String = "fixture-token") {
        self.accountID = accountID
        self.token = token
        state = .verified(accountID: accountID, sessionGeneration: 1, credentialRevision: 1)
    }

    func verifiedCredential() -> VerifiedProjectCredential? {
        guard isVerified, let accountID else { return nil }
        return VerifiedProjectCredential(token: token, accountID: accountID,
                                         sessionGeneration: sessionGeneration,
                                         credentialRevision: credentialRevision)
    }

    func isCurrent(_ context: MutationContext) -> Bool {
        guard isVerified, let accountID,
              let credential = verifiedCredential() else { return false }
        return context.accountID == accountID &&
            context.sessionGeneration == sessionGeneration &&
            context.credentialRevision == credentialRevision &&
            credential.accountID == accountID
    }

    func replaceToken(_ token: String) {
        self.token = token
        credentialRevision &+= 1
        isVerified = true
        state = .verified(accountID: accountID ?? "account-a",
                          sessionGeneration: sessionGeneration,
                          credentialRevision: credentialRevision)
    }

    func moveToAccount(_ accountID: String?) {
        self.accountID = accountID
        sessionGeneration &+= 1
        credentialRevision &+= 1
        isVerified = false
        state = .absent
    }
}

@MainActor
private final class StubProjectAPI: ProjectCreatingAPI {
    let result: Result<SamplyProject, any Error>
    private(set) var names: [String] = []
    private(set) var tokens: [String] = []

    init(result: Result<SamplyProject, any Error>) {
        self.result = result
    }

    func createProject(name: String,
                       credential: VerifiedProjectCredential) async throws -> SamplyProject {
        names.append(name)
        tokens.append(credential.token)
        return try result.get()
    }
}

@MainActor
private final class DeferredProjectAPI: ProjectCreatingAPI {
    private struct Pending {
        let name: String
        let continuation: CheckedContinuation<SamplyProject, any Error>
    }

    private(set) var names: [String] = []
    private var pending: [Pending] = []

    var pendingCount: Int { pending.count }

    func createProject(name: String,
                       credential: VerifiedProjectCredential) async throws -> SamplyProject {
        names.append(name)
        return try await withCheckedThrowingContinuation { continuation in
            pending.append(Pending(name: name, continuation: continuation))
        }
    }

    func complete(_ index: Int, with result: Result<SamplyProject, any Error>) {
        guard pending.indices.contains(index) else { return }
        let request = pending.remove(at: index)
        request.continuation.resume(with: result)
    }
}

@MainActor
private final class StubAssetUploader: ProjectAssetUploading {
    var results: [UploadOutcome] = []
    var artworkResults: [UploadOutcome] = []
    var gateNextUpload = false
    var gateNextArtwork = false
    private(set) var calls: [String] = []
    private(set) var artworkCalls = 0
    private(set) var artworkSubmissions = 0
    private var uploadContinuation: CheckedContinuation<Void, Never>?
    private var artworkContinuation: CheckedContinuation<Void, Never>?

    var isUploadGated: Bool { uploadContinuation != nil }
    var isArtworkGated: Bool { artworkContinuation != nil }

    func performUpload(file: URL, projectID: String, parentID: String?,
                       authorization: UploadAuthorization,
                       progress: @escaping @MainActor @Sendable (Double) -> Void) async -> UploadOutcome {
        calls.append(file.lastPathComponent)
        if gateNextUpload {
            gateNextUpload = false
            await withCheckedContinuation { uploadContinuation = $0 }
        }
        guard authorization.isCurrent else { return .cancelled(.waiting) }
        if results.isEmpty { return .submitted(
            UploadTicketIdentity(boxID: "box-\(calls.count)", projectID: projectID,
                                 fileName: file.lastPathComponent, kind: .originalFile)) }
        return results.removeFirst()
    }

    func performArtworkUpload(payload: ProjectArtworkPayload, projectID: String,
                              authorization: UploadAuthorization) async -> UploadOutcome {
        artworkCalls += 1
        if gateNextArtwork {
            gateNextArtwork = false
            await withCheckedContinuation { artworkContinuation = $0 }
        }
        guard authorization.isCurrent else { return .cancelled(.waiting) }
        artworkSubmissions += 1
        if artworkResults.isEmpty {
            return .submitted(UploadTicketIdentity(
                boxID: "artwork-\(artworkCalls)", projectID: projectID,
                fileName: payload.fileName, kind: .artwork))
        }
        return artworkResults.removeFirst()
    }

    func releaseUpload() {
        uploadContinuation?.resume()
        uploadContinuation = nil
    }

    func releaseArtwork() {
        artworkContinuation?.resume()
        artworkContinuation = nil
    }
}

@MainActor
private final class StubCreationWeb: ProjectCreationWebSession {
    var accountID: String? = "account-a"
    var isSigningOut = false
    var libraryResponses: [Result<WebSnapshot, any Error>]
    var browseResponse: (String, [String: Any]) throws -> WebSnapshot
    private(set) var calls: [(command: String, arguments: [String: Any])] = []
    private var refreshContinuation: CheckedContinuation<Void, Never>?
    private var shouldGateNextRefresh = false

    var isRefreshGated: Bool { refreshContinuation != nil }

    init(libraryResponses: [Result<WebSnapshot, any Error>] = [],
         browseResponse: @escaping (String, [String: Any]) throws -> WebSnapshot = { _, _ in
             throw SamplyError.invalidResponse
         }) {
        self.libraryResponses = libraryResponses
        self.browseResponse = browseResponse
    }

    func gateNextRefresh() {
        shouldGateNextRefresh = true
    }

    func releaseRefresh() {
        refreshContinuation?.resume()
        refreshContinuation = nil
    }

    func call<T: Decodable>(_ command: String, arguments: [String: Any]) async throws -> T {
        calls.append((command, arguments))
        let value: Any
        switch command {
        case "refreshPage":
            if shouldGateNextRefresh {
                shouldGateNextRefresh = false
                await withCheckedContinuation { refreshContinuation = $0 }
            }
            guard !libraryResponses.isEmpty else { throw SamplyError.invalidResponse }
            value = try libraryResponses.removeFirst().get()
        case "browse":
            value = try browseResponse(arguments["routeID"] as? String ?? "", arguments)
        default:
            throw SamplyError.invalidResponse
        }
        guard let typed = value as? T else { throw SamplyError.invalidResponse }
        return typed
    }
}
