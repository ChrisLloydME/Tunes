import AppKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct NewProjectSheet: View {
    private enum Page {
        case details, files
    }

    @Bindable var backend: SamplyBackend
    @Environment(\.dismiss) private var dismiss
    @State private var page: Page = .details
    @State private var name = ""
    @State private var validationMessage: String?
    @State private var artworkStore = ProjectArtworkSelectionStore()
    @State private var photoSelection: PhotosPickerItem?
    @State private var filesToUpload: [SelectedProjectFile] = []
    @State private var selectionGeneration = UUID()
    @State private var photoLoadGeneration = UUID()
    @State private var isTransferringPhoto = false
    @State private var accountID: String?
    @FocusState private var nameFieldFocused: Bool

    private var creation: ProjectCreationCoordinator { backend.projectCreation }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isPreparingArtwork: Bool { isTransferringPhoto || artworkStore.isLoading }
    private var showsFilesPage: Bool { page == .files && creation.createdProject != nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            footer
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
        }
        .frame(width: 620, height: 640, alignment: .topLeading)
        .interactiveDismissDisabled(creation.blocksDismissal)
        .onAppear {
            let currentAccount = backend.web.snapshot?.account?.uid
            accountID = currentAccount
            artworkStore.updateAccount(currentAccount)
            page = creation.createdProject == nil ? .details : .files
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
            filesToUpload = []
            cancelPhotoLoad()
            if creation.createdProject == nil { page = .details }
        }
        .onChange(of: photoSelection) { _, item in
            loadPhoto(item)
        }
        .onChange(of: creation.createdProject?.project.id) { _, projectID in
            page = projectID == nil ? .details : .files
        }
        .onDisappear {
            selectionGeneration = UUID()
            artworkStore.remove()
            cancelPhotoLoad()
            filesToUpload = []
            if creation.canFinishCreatedProject {
                creation.reset()
            } else if case .failed = creation.state {
                creation.reset()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("New Project")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text("Create a project in Samply. Artwork and files are optional.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 16)
    }

    @ViewBuilder private var content: some View {
        if showsFilesPage {
            filesPage
        } else {
            detailsPage
        }
    }

    // MARK: - Details page

    @ViewBuilder private var detailsPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !backend.isConnected {
                    signedOutGuidance
                } else if backend.hasToken {
                    switch creation.state {
                    case .idle, .failed:
                        detailsForm
                    case .creating:
                        creatingPanel
                    case .uncertain(let message, let canStartOver):
                        uncertainPanel(message, canStartOver)
                    case .created:
                        ProgressView("Preparing project…")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    tokenGuidance
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
    }

    private var detailsForm: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
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

            VStack(alignment: .leading, spacing: 10) {
                artworkPreview
                artworkButtons
                artworkStatusLine
            }

            Text("Artwork is assigned through Samply's authorized web session after the project is created.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var creatingPanel: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
                .accessibilityLabel("Creating project")
            Text(trimmedName)
                .font(.title3.weight(.semibold))
                .textSelection(.enabled)
            Text("Creating the project and its player in Samply…")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Keep this window open until Samply responds.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 100)
    }

    private func uncertainPanel(_ message: String, _ canStartOver: Bool) -> some View {
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
        }
    }

    @ViewBuilder private var artworkPreview: some View {
        let hasArtwork = artworkStore.selection != nil
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(.quaternary)
            if let selection = artworkStore.selection {
                Image(nsImage: selection.preview)
                    .resizable()
                    .scaledToFill()
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "photo")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)
                    Text("No Artwork Selected")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            if isPreparingArtwork {
                ProgressView()
                    .controlSize(.large)
                    .padding(14)
                    .background(.regularMaterial, in: Circle())
                    .accessibilityLabel("Preparing artwork")
            }
            if hasArtwork {
                VStack {
                    HStack {
                        Spacer()
                        Button {
                            cancelPhotoLoad()
                            artworkStore.remove()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title2)
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.42))
                        }
                        .buttonStyle(.plain)
                        .padding(10)
                        .help("Remove Artwork")
                        .accessibilityLabel("Remove Artwork")
                    }
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 230)
        .clipShape(.rect(cornerRadius: 14))
        .accessibilityElement(children: .contain)
    }

    private var artworkButtons: some View {
        let hasArtwork = artworkStore.selection != nil
        return GeometryReader { proxy in
            let buttonWidth = max(0, (proxy.size.width - 12) / 2)
            HStack(spacing: 12) {
                Button {
                    chooseArtworkFile()
                } label: {
                    Text(hasArtwork ? "Replace From Files" : "Choose From Files")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .frame(width: buttonWidth)
                .disabled(isPreparingArtwork)

                PhotosPicker(selection: $photoSelection, matching: .images) {
                    Text(hasArtwork ? "Replace From Photos" : "Choose From Photos")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .frame(width: buttonWidth)
                .disabled(isPreparingArtwork)
                .accessibilityLabel(hasArtwork ? "Replace artwork from Photos" : "Choose artwork from Photos")
            }
        }
        .frame(height: 34)
    }

    @ViewBuilder private var artworkStatusLine: some View {
        Group {
            if isPreparingArtwork {
                Text(isTransferringPhoto ? "Loading photo…" : "Preparing artwork…")
            } else if let message = artworkStore.errorMessage {
                Text(message)
            } else if artworkStore.selection != nil {
                Text("Artwork ready to assign after creation.")
            } else {
                Text("Artwork is optional.")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(2)
        .frame(height: 28, alignment: .topLeading)
    }

    // MARK: - Files page

    private var filesPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let created = creation.createdProject {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(created.project.name)
                            .font(.title3.weight(.semibold))
                            .lineLimit(2)
                        Spacer()
                        Label("Project Created", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                projectStageStatus
                artworkSummary
                Divider()
                filesSection
                if !creation.initialFiles.isEmpty {
                    Divider()
                    uploadsSection
                }
                navigationRecovery
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
    }

    private var projectStageStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let stage = creation.createdStage {
                Text(createdMessage(stage))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if stage.isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(stage == .refreshing ? "Refreshing Library" : "Opening project")
                }
            }
        }
    }

    @ViewBuilder private var artworkSummary: some View {
        if creation.artworkState != .none {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("Artwork")
                        .font(.body.weight(.medium))
                    Spacer()
                    switch creation.artworkState {
                    case .pending:
                        ProgressView().controlSize(.small)
                    case .assigned:
                        Label("Assigned", systemImage: "checkmark.circle")
                            .font(.caption)
                    case .failed, .uncertain, .unsupported, .none:
                        EmptyView()
                    }
                }
                switch creation.artworkState {
                case .none:
                    EmptyView()
                case .pending:
                    Text("Assigning artwork in Samply…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                case .assigned:
                    Text("The project artwork was confirmed by Samply.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                case .failed(let message), .uncertain(let message), .unsupported(let message):
                    statusMessage(message, systemImage: "exclamationmark.triangle")
                }
                if creation.canRetryArtwork {
                    Button("Retry Artwork") { creation.retryArtwork() }
                        .controlSize(.small)
                }
            }
        }
    }

    private var filesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Files")
                    .font(.body.weight(.medium))
                Spacer()
                Button("Choose Files…") { chooseFilesToUpload() }
                    .disabled(creation.isUploadingInitialFiles)
                    .accessibilityLabel("Choose files to upload")
            }
            if filesToUpload.isEmpty {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.quaternary)
                    .frame(height: 82)
                    .overlay {
                        Text("No files selected. Choose files to upload, or finish without adding files.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(12)
                    }
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(filesToUpload) { file in
                            HStack(spacing: 10) {
                                Image(systemName: "doc")
                                    .foregroundStyle(.secondary)
                                Text(file.fileName)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Button {
                                    filesToUpload.removeAll { $0.id == file.id }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Remove \(file.fileName)")
                                .accessibilityLabel("Remove \(file.fileName)")
                            }
                            .padding(.vertical, 6)
                            if file.id != filesToUpload.last?.id { Divider() }
                        }
                    }
                }
                .frame(maxHeight: 150)
                Text("Files upload in this order. Originals are streamed without transcoding.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var uploadsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Uploads")
                    .font(.body.weight(.medium))
                Spacer()
                if creation.canRetryInitialFiles {
                    Button("Retry Failed Files") { creation.retryFailedInitialFiles() }
                        .controlSize(.small)
                }
            }
            ScrollView {
                VStack(spacing: 10) {
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
            .frame(maxHeight: 190)
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

    @ViewBuilder private var navigationRecovery: some View {
        if creation.createdStage != .opened || creation.canOpenCreatedProject {
            HStack(spacing: 10) {
                Button("Refresh Library") {
                    Task { await creation.refreshLibrary() }
                }
                .disabled(creation.createdStage?.isBusy == true)
                if creation.canOpenCreatedProject {
                    Button("Open Project") {
                        Task { await creation.openCreatedProject() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(creation.createdStage?.isBusy == true)
                }
            }
        }
    }

    // MARK: - Guidance

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

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            footerLeadingButton
            Spacer()
            footerTrailingButton
        }
        .frame(height: 28)
    }

    @ViewBuilder private var footerLeadingButton: some View {
        if showsFilesPage {
            Button("Close") { close() }
                .disabled(creation.blocksDismissal)
        } else {
            switch creation.state {
            case .idle, .failed:
                if backend.isConnected, backend.hasToken {
                    Button("Cancel") { close() }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("cancelNewProject")
                } else {
                    Button("Close") { close() }
                        .keyboardShortcut(.cancelAction)
                }
            case .creating:
                Button("Cancel") {}.disabled(true)
                    .accessibilityIdentifier("cancelNewProject")
            case .uncertain:
                Button("Close") { close() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(creation.isRefreshingAfterUncertain)
            case .created:
                Button("Close") { close() }
                    .disabled(creation.blocksDismissal)
            }
        }
    }

    @ViewBuilder private var footerTrailingButton: some View {
        if showsFilesPage {
            if creation.isUploadingInitialFiles {
                Button("Cancel Uploads") { creation.cancelInitialUploads() }
                    .buttonStyle(.borderedProminent)
            } else if filesToUpload.isEmpty {
                Button("Done") { close() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(creation.blocksDismissal)
            } else {
                Button("Upload") { uploadSelectedFiles() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        } else {
            switch creation.state {
            case .idle, .failed:
                if backend.isConnected, backend.hasToken {
                    Button("Create") { submit() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(trimmedName.isEmpty || creation.isCreating || isPreparingArtwork)
                        .accessibilityIdentifier("createProject")
                }
            case .creating:
                Button("Create") {}.disabled(true)
                    .accessibilityIdentifier("createProject")
            case .uncertain(_, let canStartOver):
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
            case .created:
                Button("Continue") { page = .files }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Helpers

    private func createdMessage(_ stage: ProjectCreationCoordinator.Stage) -> String {
        switch stage {
        case .refreshing:
            return "Refreshing your complete Samply Library…"
        case .opening:
            return "Opening the project…"
        case .opened:
            return "Project opened in Tunes."
        case .delayed:
            return "The project has not appeared in your Library yet. Samply may still be updating history."
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

    private func chooseFilesToUpload() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.message = "Choose files to upload to the new project."
        panel.prompt = "Add Files"
        let generation = selectionGeneration
        let account = accountID
        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in
                guard generation == selectionGeneration,
                      account == accountID else { return }
                var seen = Set(filesToUpload.map { $0.url.standardizedFileURL.path })
                seen.formUnion(creation.initialFiles.map { $0.url.standardizedFileURL.path })
                for url in urls {
                    let path = url.standardizedFileURL.path
                    guard seen.insert(path).inserted else { continue }
                    filesToUpload.append(SelectedProjectFile(url: url))
                }
            }
        }
    }

    private func uploadSelectedFiles() {
        guard !filesToUpload.isEmpty else { return }
        if creation.addFiles(filesToUpload.map(\.url)) {
            filesToUpload = []
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
            await creation.create(name: name, artwork: artworkStore.selection?.payload)
            if creation.createdProject != nil { page = .files }
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
