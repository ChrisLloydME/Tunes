import AppKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct NewProjectSheet: View {
    @Bindable var backend: SamplyBackend
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var validationMessage: String?
    @State private var artworkStore = ProjectArtworkSelectionStore()
    @State private var photoSelection: PhotosPickerItem?
    @State private var initialFiles: [SelectedProjectFile] = []
    @State private var selectionGeneration = UUID()
    @State private var photoLoadGeneration = UUID()
    @State private var isTransferringPhoto = false
    @State private var accountID: String?
    @FocusState private var nameFieldFocused: Bool

    private var creation: ProjectCreationCoordinator { backend.projectCreation }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isPreparingArtwork: Bool { isTransferringPhoto || artworkStore.isLoading }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("New Project")
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("Create a project in Samply. Artwork and initial files are optional.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !backend.isConnected {
                        signedOutGuidance
                    } else if backend.hasToken {
                        projectContent
                    } else {
                        tokenGuidance
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            .frame(maxHeight: 430)

            Divider()

            footer
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
        }
        .frame(width: 560, alignment: .topLeading)
        .interactiveDismissDisabled(creation.blocksDismissal)
        .onAppear {
            let currentAccount = backend.web.snapshot?.account?.uid
            accountID = currentAccount
            artworkStore.updateAccount(currentAccount)
            if case .idle = creation.state {
                name = ""
                validationMessage = nil
                nameFieldFocused = true
            }
        }
        .onChange(of: backend.hasToken) { _, hasToken in
            if hasToken, case .idle = creation.state { nameFieldFocused = true }
        }
        .onChange(of: backend.web.snapshot?.account?.uid) { _, newAccount in
            guard newAccount != accountID else { return }
            accountID = newAccount
            selectionGeneration = UUID()
            artworkStore.updateAccount(newAccount)
            initialFiles = []
            cancelPhotoLoad()
        }
        .onChange(of: photoSelection) { _, item in
            loadPhoto(item)
        }
        .onChange(of: creation.createdStage) { _, stage in
            if stage == .opened, !creation.hasOptionalCreatedWork { dismiss() }
        }
        .onDisappear {
            selectionGeneration = UUID()
            artworkStore.remove()
            cancelPhotoLoad()
            initialFiles = []
            if creation.canFinishCreatedProject { creation.reset() }
        }
    }

    @ViewBuilder private var projectContent: some View {
        switch creation.state {
        case .idle, .failed:
            nameForm
            artworkForm
            initialFilesForm

        case .creating:
            VStack(alignment: .leading, spacing: 12) {
                Text(trimmedName)
                    .font(.headline)
                    .textSelection(.enabled)
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Creating project")
                    Text("Creating project in Samply…")
                }
                Text("Keep this window open until Samply responds.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

        case .created(let created, let stage):
            createdContent(created, stage)

        case .uncertain(let message, let canStartOver):
            VStack(alignment: .leading, spacing: 10) {
                Label("Creation Not Confirmed", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if canStartOver {
                    Text("If the project is not in your Library, you can start a new project.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if creation.isRefreshingAfterUncertain {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Refreshing Library")
                }
            }
        }
    }

    private var nameForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Project Name")
                .font(.body.weight(.medium))
            TextField("Project Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFieldFocused)
                .onSubmit(submit)
                .disabled(creation.isCreating)
                .accessibilityLabel("Project Name")
                .accessibilityIdentifier("newProjectName")
                .onChange(of: name) { _, _ in validationMessage = nil }
            if let validationMessage {
                statusMessage(validationMessage, systemImage: "exclamationmark.circle")
            }
            if case .failed(let message) = creation.state {
                statusMessage(message, systemImage: "exclamationmark.triangle")
            }
        }
    }

    private var artworkForm: some View {
        let hasArtwork = artworkStore.selection != nil
        return VStack(alignment: .leading, spacing: 10) {
            Text("Artwork")
                .font(.body.weight(.medium))
            HStack(alignment: .top, spacing: 14) {
                artworkPreview
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Button(hasArtwork ? "Replace from Files" : "Choose from Files") {
                            chooseArtworkFile()
                        }
                        .disabled(isPreparingArtwork)
                        PhotosPicker(selection: $photoSelection, matching: .images) {
                            Label(hasArtwork ? "Replace from Photos" : "Choose from Photos",
                                  systemImage: "photo")
                        }
                        .buttonStyle(.bordered)
                        .disabled(isPreparingArtwork)
                        .accessibilityLabel(hasArtwork ? "Replace artwork from Photos" : "Choose artwork from Photos")
                    }
                    if artworkStore.selection != nil {
                        Button("Remove Artwork", role: .destructive) {
                            cancelPhotoLoad()
                            artworkStore.remove()
                        }
                        .buttonStyle(.borderless)
                    }
                    if isPreparingArtwork {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(isTransferringPhoto ? "Loading photo…" : "Preparing artwork…")
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                    if let message = artworkStore.errorMessage {
                        statusMessage(message, systemImage: "exclamationmark.triangle")
                    }
                }
            }
            Text("Artwork is assigned through Samply's authorized web session after the project is created.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var artworkPreview: some View {
        if let selection = artworkStore.selection {
            Image(nsImage: selection.preview)
                .resizable()
                .scaledToFill()
                .frame(width: 96, height: 96)
                .clipShape(.rect(cornerRadius: 8))
                .accessibilityLabel("Selected project artwork")
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary)
                .frame(width: 96, height: 96)
                .overlay {
                    Image(systemName: "photo")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                }
                .accessibilityHidden(true)
        }
    }

    private var initialFilesForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Initial Files")
                    .font(.body.weight(.medium))
                Spacer()
                Button("Add Files…") { chooseInitialFiles() }
                    .disabled(creation.isCreating)
                    .accessibilityLabel("Add initial files")
            }
            if initialFiles.isEmpty {
                Text("No files selected. You can upload files later from the project.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(initialFiles) { file in
                            HStack(spacing: 10) {
                                Image(systemName: "doc")
                                    .foregroundStyle(.secondary)
                                Text(file.fileName)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Button {
                                    initialFiles.removeAll { $0.id == file.id }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Remove \(file.fileName)")
                                .accessibilityLabel("Remove \(file.fileName)")
                            }
                            .padding(.vertical, 6)
                            if file.id != initialFiles.last?.id { Divider() }
                        }
                    }
                }
                .frame(maxHeight: 150)
                Text("Uploaded in this order after Samply confirms the project. Originals are streamed without transcoding.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func createdContent(_ created: ProjectCreationCoordinator.CreatedProject,
                                _ stage: ProjectCreationCoordinator.Stage) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(created.project.name, systemImage: "checkmark.circle.fill")
                .font(.headline)
                .textSelection(.enabled)
            Text(createdMessage(stage))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if stage.isBusy {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(stage == .refreshing ? "Refreshing Library" : "Opening project")
            }
            if creation.artworkState != .none {
                artworkStatus
            }
            if !creation.initialFiles.isEmpty {
                initialFilesStatus
            }
        }
    }

    private var artworkStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Artwork")
                .font(.body.weight(.medium))
            switch creation.artworkState {
            case .none:
                EmptyView()
            case .pending:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Assigning artwork in Samply…")
                }
            case .assigned:
                Label("Artwork assigned.", systemImage: "checkmark.circle")
            case .failed(let message), .uncertain(let message), .unsupported(let message):
                statusMessage(message, systemImage: "exclamationmark.triangle")
            }
        }
    }

    private var initialFilesStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Initial Files")
                .font(.body.weight(.medium))
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(creation.initialFiles) { file in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 8) {
                                Image(systemName: initialFileSymbol(file.status))
                                    .foregroundStyle(.secondary)
                                Text(file.fileName)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Text(initialFileStatus(file))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if file.status == .uploading {
                                ProgressView(value: file.progress)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 220)
            if creation.hasUncertainInitialFiles {
                Text("An uncertain upload may already exist in the project. Check the project in Samply before retrying.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if creation.initialFiles.contains(where: { $0.status == .cancelled }) {
                Text("Cancelling uploads does not remove files already submitted to Samply.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if creation.initialFiles.contains(where: {
                if case .uploaded = $0.status { return true }
                return false
            }) {
                Text("A successful upload confirms Samply received the original file; processing may continue.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var signedOutGuidance: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Sign In to Samply", systemImage: "person.crop.circle")
                .font(.headline)
            Text("Sign in to Samply before creating a project. Tunes will not create anything automatically.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var tokenGuidance: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Personal Access Token Required", systemImage: "key")
                .font(.headline)
            Text("Creating a project uses Samply's official REST API. Open Settings, choose API Access, and add a Personal Access Token from the same Samply account. This window will not create a project automatically after Settings closes.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SettingsLink {
                Text("Open Settings")
            }
        }
    }

    @ViewBuilder private var footer: some View {
        HStack(spacing: 12) {
            if creation.isCreating {
                ProgressView()
                    .controlSize(.small)
                Text("Creating project…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            footerButtons
        }
    }

    @ViewBuilder private var footerButtons: some View {
        switch creation.state {
        case .idle, .failed:
            if backend.isConnected, backend.hasToken {
                Button("Cancel") { close() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("cancelNewProject")
                Button("Create") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty || creation.isCreating || isPreparingArtwork)
                    .accessibilityIdentifier("createProject")
            } else {
                Button("Close") { close() }
                    .keyboardShortcut(.cancelAction)
            }

        case .creating:
            Button("Cancel") {}.disabled(true)
                .accessibilityIdentifier("cancelNewProject")
            Button("Create") {}.disabled(true)
                .accessibilityIdentifier("createProject")

        case .created(_, let stage):
            if stage.isBusy || creation.artworkState.isBusy || creation.isUploadingInitialFiles {
                if creation.isUploadingInitialFiles {
                    Button("Cancel Uploads") { creation.cancelInitialUploads() }
                }
                Button("Close") {}.disabled(true)
            } else {
                if creation.canRetryInitialFiles || creation.canRetryArtwork {
                    Menu("Recover") {
                        if creation.canRetryInitialFiles {
                            Button("Retry Failed Files") { creation.retryFailedInitialFiles() }
                        }
                        if creation.canRetryArtwork {
                            Button("Retry Artwork") { creation.retryArtwork() }
                        }
                    }
                    .fixedSize()
                }
                Button("Close") { close() }
                Button("Refresh Library") {
                    Task { await creation.refreshLibrary() }
                }
                if creation.canOpenCreatedProject {
                    Button("Open Project") {
                        Task { await creation.openCreatedProject() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

        case .uncertain(_, let canStartOver):
            Button("Close") { close() }
                .keyboardShortcut(.cancelAction)
                .disabled(creation.isRefreshingAfterUncertain)
            if canStartOver {
                Button("Start New Project") {
                    name = ""
                    validationMessage = nil
                    creation.startOverAfterUncertainOutcome()
                    nameFieldFocused = true
                }
            } else {
                Button("Refresh Library") {
                    Task { await creation.refreshLibrary() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(creation.isRefreshingAfterUncertain)
            }
        }
    }

    private func createdMessage(_ stage: ProjectCreationCoordinator.Stage) -> String {
        switch stage {
        case .refreshing:
            return "Project created. Refreshing your complete Samply Library…"
        case .opening:
            return "Project created. Opening it now…"
        case .opened:
            return "Project created and opened."
        case .delayed:
            return "Project created, but it has not appeared in your Library yet. Samply may still be updating your history."
        case .refreshFailed(let message), .openFailed(let message):
            return message
        }
    }

    private func initialFileStatus(_ file: ProjectCreationCoordinator.InitialFile) -> String {
        switch file.status {
        case .pending: return "Waiting to upload."
        case .uploading: return "Uploading \(Int(file.progress * 100))%…"
        case .uploaded: return "Submitted; Samply is processing."
        case .failed(let message): return "Not uploaded: \(message)"
        case .cancelled: return "Upload cancelled."
        case .uncertain(let message): return message
        }
    }

    private func initialFileSymbol(_ status: ProjectCreationCoordinator.InitialFile.Status) -> String {
        switch status {
        case .pending: return "clock"
        case .uploading: return "arrow.up.circle"
        case .uploaded: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        case .cancelled: return "slash.circle"
        case .uncertain: return "questionmark.circle"
        }
    }

    private func statusMessage(_ message: String, systemImage: String) -> some View {
        Label {
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        } icon: {
            Image(systemName: systemImage)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private func chooseArtworkFile() {
        cancelPhotoLoad()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose artwork for the new project."
        panel.prompt = "Choose"
        let generation = selectionGeneration
        let account = accountID
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                guard generation == selectionGeneration,
                      account == accountID else { return }
                await artworkStore.load(fileURL: url, accountID: account)
            }
        }
    }

    private func cancelPhotoLoad() {
        photoLoadGeneration = UUID()
        photoSelection = nil
        isTransferringPhoto = false
    }

    private func loadPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        let token = UUID()
        photoLoadGeneration = token
        isTransferringPhoto = true
        let account = accountID
        Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    guard photoLoadGeneration == token else { return }
                    isTransferringPhoto = false
                    artworkStore.reject("The selected photo could not be loaded.")
                    photoSelection = nil
                    return
                }
                guard photoLoadGeneration == token else { return }
                isTransferringPhoto = false
                await artworkStore.load(data: data, suggestedName: "Project Artwork",
                                        accountID: account)
                guard photoLoadGeneration == token else { return }
                photoSelection = nil
            } catch {
                guard photoLoadGeneration == token else { return }
                isTransferringPhoto = false
                artworkStore.reject("The selected photo could not be loaded.")
                photoSelection = nil
            }
        }
    }

    private func chooseInitialFiles() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.message = "Choose original files to upload after the project is created."
        panel.prompt = "Add Files"
        let generation = selectionGeneration
        let account = accountID
        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in
                guard generation == selectionGeneration,
                      account == accountID else { return }
                var seen = Set(initialFiles.map { $0.url.standardizedFileURL.path })
                for url in urls {
                    let path = url.standardizedFileURL.path
                    guard seen.insert(path).inserted else { continue }
                    initialFiles.append(SelectedProjectFile(url: url))
                }
            }
        }
    }

    private func submit() {
        guard backend.isConnected, backend.hasToken, !creation.isCreating,
              !isPreparingArtwork else { return }
        guard !trimmedName.isEmpty else {
            validationMessage = "Enter a project name."
            nameFieldFocused = true
            return
        }
        validationMessage = nil
        Task {
            await creation.create(name: name,
                                  artwork: artworkStore.selection?.payload,
                                  files: initialFiles.map(\.url))
        }
    }

    private func close() {
        if creation.canFinishCreatedProject {
            creation.reset()
        } else {
            switch creation.state {
            case .idle, .failed: creation.reset()
            default: break
            }
        }
        dismiss()
    }
}

private struct SelectedProjectFile: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    var fileName: String { url.lastPathComponent }
}
