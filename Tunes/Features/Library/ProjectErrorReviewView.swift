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
        let coordinator = ProjectCreationCoordinator(api: fixture, web: fixture, fileUploader: fixture)
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
    case artworkUncertain = "Artwork: Not Confirmed"
    case artworkUnsupported = "Artwork: Unsupported"
    case combined = "Uploads and Artwork: Failed"
    case creationFailed = "Creation: Failed"
    case creationUncertain = "Creation: Not Confirmed"

    var id: Self { self }

    var includesArtwork: Bool {
        switch self {
        case .artworkFailed, .artworkUncertain, .artworkUnsupported, .combined: true
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
private final class ProjectErrorFixture: ProjectCreatingAPI, ProjectCreationWebSession, ProjectFileUploading {
    static let item = LibraryItem(id: "debug-project", name: "Error UI Review Project",
                                  projectID: "debug-project", canUpload: true, isOwned: true)
    let scenario: ProjectErrorScenario
    let accountID: String? = "debug-account"
    let isSigningOut = false

    init(scenario: ProjectErrorScenario) { self.scenario = scenario }

    func createProject(name: String) async throws -> SamplyProject {
        try await Task.sleep(for: .milliseconds(350))
        switch scenario {
        case .creationFailed: throw SamplyError.http(403, retryAfter: nil)
        case .creationUncertain: throw URLError(.timedOut)
        default: return SamplyProject(id: Self.item.id, name: name)
        }
    }

    func performUpload(file: URL, projectID: String, parentID: String?,
                       progress: @escaping @MainActor @Sendable (Double) -> Void) async throws -> String {
        progress(0.35)
        try await Task.sleep(for: .milliseconds(350))
        switch file.lastPathComponent {
        case "Uploaded Mix.wav": return "debug-box"
        case "Unconfirmed Mix.wav": throw URLError(.timedOut)
        case "Cancelled Mix.wav": throw CancellationError()
        default: throw SamplyError.http(403, retryAfter: nil)
        }
    }

    func call<T: Decodable>(_ command: String, arguments: [String: Any]) async throws -> T {
        try await Task.sleep(for: .milliseconds(350))
        let data: Data
        switch command {
        case "setProjectArtwork":
            let status: String
            switch scenario {
            case .artworkUncertain: status = "submitted"
            case .artworkUnsupported: status = "unsupported"
            default: status = "failed"
            }
            data = try JSONSerialization.data(withJSONObject: ["status": status])
        case "refreshPage", "browse":
            let snapshot = WebSnapshot(
                version: 1, account: .init(uid: "debug-account", name: "UI Review"),
                libraryReady: true, library: [Self.item], boxesReady: true, boxes: [], capabilities: []
            )
            data = try JSONEncoder().encode(snapshot)
        default:
            throw SamplyError.webContract("Unsupported debug fixture command: \(command)")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
#endif
