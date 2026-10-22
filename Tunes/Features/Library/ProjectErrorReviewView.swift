#if DEBUG
import SwiftUI

/// Temporary review harness. All mutations use in-memory protocol fixtures.
struct ProjectErrorReviewView: View {
    let backend: SamplyBackend
    @State private var scenario = ProjectErrorScenario.mixedUploads
    @State private var creation: ProjectCreationCoordinator?
    @State private var showsSheet = false
    @State private var noticeDismissed = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Scenario", selection: $scenario) {
                    ForEach(ProjectErrorScenario.allCases) { scenario in
                        Text(scenario.rawValue).tag(scenario)
                    }
                }
                .frame(maxWidth: 420)
                Button("Reset Scenario") { loadScenario() }
                Button("Open Project Sheet") { showsSheet = true }
                    .disabled(creation == nil)
            }
            .padding()
            Text("Debug fixtures only. No projects are created and no files are uploaded to Samply. Retries repeat the selected failure.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.bottom)
            Divider()
            if let creation {
                LibraryView(
                    items: [ProjectErrorFixture.item],
                    isOpeningProject: false,
                    creationNotice: noticeDismissed ? nil : SamplyBackend.creationNotice(for: creation),
                    retryProjectUploads: { creation.retryFailedInitialFiles() },
                    retryProjectArtwork: { creation.retryArtwork() },
                    refreshProjectLibrary: { Task { await creation.refreshLibrary() } },
                    openCreatedProject: { Task { await creation.openCreatedProject() } },
                    startNewProject: { creation.discardConfirmedCreation() },
                    dismissCreationNotice: { noticeDismissed = true },
                    openProject: { _ in showsSheet = true }
                )
            }
        }
        .frame(minWidth: 860, minHeight: 560)
        .onAppear { loadScenario() }
        .onChange(of: scenario) { _, _ in loadScenario() }
        .sheet(isPresented: $showsSheet) {
            if let creation {
                NewProjectSheet(backend: backend, reviewCreation: creation)
            }
        }
        .onDisappear { creation?.invalidate() }
    }

    private func loadScenario() {
        creation?.invalidate()
        noticeDismissed = false
        let fixture = ProjectErrorFixture(scenario: scenario)
        let coordinator = ProjectCreationCoordinator(api: fixture, web: fixture,
                                                     uploader: fixture,
                                                     credentials: fixture.credentials)
        creation = coordinator
        Task {
            await coordinator.create(
                name: ProjectErrorFixture.item.name,
                artwork: scenario.includesArtwork
                    ? ProjectArtworkPayload(data: Data(), fileName: "Artwork.jpg", mimeType: "image/jpeg") : nil,
                files: scenario.fileNames.map { URL(fileURLWithPath: "/debug-fixtures/\($0)") }
            )
        }
    }
}

private enum ProjectErrorScenario: String, CaseIterable, Identifiable {
    case mixedUploads = "Uploads: Mixed Outcomes"
    case failedUpload = "Upload: Failed"
    case uncertainUpload = "Upload: Not Confirmed"
    case cancelledUpload = "Upload: Cancelled"
    case artworkFailed = "Artwork: Failed"
    case artworkUncertain = "Artwork: Submitted, Unconfirmed"
    case artworkSubmitted = "Artwork: Submitted, Pending"
    case combined = "Uploads and Artwork: Failed"
    case creationFailed = "Creation: Failed"
    case creationUncertain = "Creation: Not Confirmed"

    var id: Self { self }

    var includesArtwork: Bool {
        switch self {
        case .artworkFailed, .artworkUncertain, .artworkSubmitted, .combined: true
        default: false
        }
    }

    var fileNames: [String] {
        switch self {
        case .mixedUploads: ["Uploaded Mix.wav", "Failed Mix.wav", "Unconfirmed Mix.wav", "Cancelled Mix.wav"]
        case .failedUpload, .combined: ["Failed Mix.wav"]
        case .uncertainUpload: ["Unconfirmed Mix.wav"]
        case .cancelledUpload: ["Cancelled Mix.wav"]
        default: []
        }
    }
}

@MainActor
private final class ProjectErrorFixture: ProjectCreatingAPI, ProjectCreationWebSession,
    ProjectAssetUploading {
    static let item = LibraryItem(id: "debug-project", name: "Error UI Review Project",
                                  projectID: "debug-project", canUpload: true, isOwned: true)
    let scenario: ProjectErrorScenario
    let accountID: String? = "debug-account"
    let isSigningOut = false
    let credentials = ProjectErrorCredentials()

    init(scenario: ProjectErrorScenario) { self.scenario = scenario }

    func createProject(name: String,
                       credential: VerifiedProjectCredential) async throws -> SamplyProject {
        try await Task.sleep(for: .milliseconds(350))
        switch scenario {
        case .creationFailed: throw SamplyError.http(403, retryAfter: nil)
        case .creationUncertain: throw URLError(.timedOut)
        default:
            return SamplyProject(id: Self.item.id, name: name,
                                 creator: .init(uid: "debug-account"))
        }
    }

    func performUpload(file: URL, projectID: String, parentID: String?,
                       authorization: UploadAuthorization,
                       progress: @escaping @MainActor @Sendable (Double) -> Void) async -> UploadOutcome {
        progress(0.35)
        try? await Task.sleep(for: .milliseconds(350))
        let identity = UploadTicketIdentity(boxID: "debug-box", projectID: projectID,
                                            fileName: file.lastPathComponent,
                                            kind: .originalFile)
        switch file.lastPathComponent {
        case "Uploaded Mix.wav": return .submitted(identity)
        case "Unconfirmed Mix.wav": return .uncertain(
            "Samply did not confirm whether the upload ticket was created.",
            phase: .ticketRequested)
        case "Cancelled Mix.wav": return .cancelled(.waiting)
        default: return .failed("Samply rejected the upload request (HTTP 403).",
                                phase: .waiting)
        }
    }

    func performArtworkUpload(payload: ProjectArtworkPayload, projectID: String,
                              authorization: UploadAuthorization) async -> UploadOutcome {
        try? await Task.sleep(for: .milliseconds(350))
        let identity = UploadTicketIdentity(boxID: "debug-artwork-box", projectID: projectID,
                                            fileName: payload.fileName, kind: .artwork)
        switch scenario {
        case .artworkFailed:
            return .failed("Samply rejected the artwork request (HTTP 403).", phase: .waiting)
        case .artworkUncertain:
            return .uncertain("The artwork upload timed out after submission started.",
                              phase: .putStarted, ticket: identity)
        case .artworkSubmitted:
            return .submitted(identity)
        default:
            return .failed("Samply rejected the artwork request (HTTP 403).", phase: .waiting)
        }
    }

    func call<T: Decodable>(_ command: String, arguments: [String: Any]) async throws -> T {
        try await Task.sleep(for: .milliseconds(350))
        guard command == "refreshPage" || command == "browse" else {
            throw SamplyError.webContract("Unsupported debug fixture command: \(command)")
        }
        let snapshot = WebSnapshot(
            version: 1, account: .init(uid: "debug-account", name: "UI Review"),
            libraryReady: true, library: [Self.item], boxesReady: true, boxes: [], capabilities: []
        )
        let data = try JSONEncoder().encode(snapshot)
        return try JSONDecoder().decode(T.self, from: data)
    }
}

@MainActor
private final class ProjectErrorCredentials: ProjectCredentialProviding {
    var state: ProjectCredentialState {
        .verified(accountID: "debug-account", sessionGeneration: 0, credentialRevision: 0)
    }
    var accountID: String? { "debug-account" }
    var sessionGeneration: UInt64 { 0 }
    var credentialRevision: UInt64 { 0 }
    var hasStoredToken: Bool { true }

    func verifiedCredential() -> VerifiedProjectCredential? {
        VerifiedProjectCredential(token: "debug-fixture-token", accountID: "debug-account",
                                  sessionGeneration: 0, credentialRevision: 0)
    }

    func isCurrent(_ context: MutationContext) -> Bool {
        context.accountID == "debug-account" && context.sessionGeneration == 0 &&
            context.credentialRevision == 0
    }
}
#endif
