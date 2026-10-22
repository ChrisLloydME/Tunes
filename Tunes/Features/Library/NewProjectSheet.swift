import AppKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct NewProjectSheet: View {
    private enum Page {
        case details, files
    }

    private let sheetWidth: CGFloat = 420
    private let sheetHeight: CGFloat = 680
    private let pagePadding: CGFloat = 20
    private var contentWidth: CGFloat { sheetWidth - pagePadding * 2 }

    @Bindable var backend: SamplyBackend
    var onReturnToLibrary: () -> Void = {}
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
    private var blocksFilesPageDismissal: Bool { creation.isUploadingInitialFiles }

    var body: some View {
        VStack(spacing: 0) {
            pageHeader
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            footer
                .padding(.horizontal, pagePadding)
                .padding(.vertical, 14)
        }
        .frame(width: sheetWidth, height: sheetHeight, alignment: .topLeading)
        .interactiveDismissDisabled(showsFilesPage ? blocksFilesPageDismissal : creation.blocksDismissal)
        .onAppear {
            if creation.canFinishCreatedProject { creation.reset() }
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

    @ViewBuilder private var pageHeader: some View {
        if showsFilesPage, let created = creation.createdProject {
            Text(created.project.name)
                .font(.title2.weight(.semibold))
                .lineLimit(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, pagePadding)
                .padding(.top, 18)
                .padding(.bottom, 12)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("New Project")
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("Create a project in Samply.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, pagePadding)
            .padding(.top, 18)
            .padding(.bottom, 12)
        }
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
            .padding(pagePadding)
        }
    }

    private var detailsForm: some View {
        VStack(alignment: .leading, spacing: 14) {
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

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    artworkPreview
                    Spacer(minLength: 0)
                }
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    artworkButtons
                        .frame(width: contentWidth)
                    Spacer(minLength: 0)
                }
                if let message = artworkStore.errorMessage {
                    statusMessage(message, systemImage: "exclamationmark.triangle")
                }
            }
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
                    .accessibilityLabel(isTransferringPhoto ? "Loading photo" : "Preparing artwork")
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
        .frame(width: contentWidth, height: contentWidth)
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

    // MARK: - Files page

    private var fileRows: [ProjectFileRow] {
        var rows = filesToUpload.map {
            ProjectFileRow(id: "local-\($0.id.uuidString)",
                           fileName: $0.fileName,
                           status: "Ready to upload",
                           symbol: "doc",
                           progress: nil,
                           localID: $0.id)
        }
        rows.append(contentsOf: creation.initialFiles.map {
            ProjectFileRow(id: "upload-\($0.id.uuidString)",
                           fileName: $0.fileName,
                           status: initialFileStatus($0),
                           symbol: initialFileSymbol($0.status),
                           progress: $0.status == .uploading ? $0.progress : nil,
                           localID: nil)
        })
        return rows
    }

    private var filesPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Files")
                    .font(.headline)
                Spacer()
                Button {
                    chooseFilesToUpload()
                } label: {
                    Label("Choose Files…", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .disabled(creation.isUploadingInitialFiles)
                .accessibilityLabel("Choose files to upload")
            }

            fileListCard

            if creation.canRetryInitialFiles {
                HStack {
                    Spacer()
                    Button("Retry Failed Files") {
                        creation.retryFailedInitialFiles()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(pagePadding)
    }

    private var fileListCard: some View {
        VStack(spacing: 0) {
            if fileRows.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "doc.badge.plus")
                        .font(.system(size: 34, weight: .regular))
                        .foregroundStyle(.secondary)
                    Text("No Files Selected")
                        .font(.headline)
                    Text("Choose original files to upload to this project.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(fileRows) { row in
                            fileRow(row)
                            if row.id != fileRows.last?.id {
                                Divider()
                                    .padding(.leading, 36)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { fileCardBackground }
        .clipShape(.rect(cornerRadius: 12))
        .overlay { fileCardBorder }
    }

    private func fileRow(_ row: ProjectFileRow) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: row.symbol)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.fileName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(row.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let progress = row.progress {
                    ProgressView(value: progress)
                        .controlSize(.small)
                }
            }
            Spacer(minLength: 8)
            if let localID = row.localID {
                Button {
                    filesToUpload.removeAll { $0.id == localID }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Remove \(row.fileName)")
                .accessibilityLabel("Remove \(row.fileName)")
            }
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private var fileCardBackground: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(.quaternary.opacity(0.28))
    }

    private var fileCardBorder: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.55))
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
            Button("Close") { returnToLibrary() }
                .disabled(blocksFilesPageDismissal)
        } else {
            switch creation.state {
            case .idle, .failed:
                if backend.isConnected, backend.hasToken {
                    Button("Cancel") { closeDetails() }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("cancelNewProject")
                } else {
                    Button("Close") { returnToLibrary() }
                        .keyboardShortcut(.cancelAction)
                }
            case .creating:
                Button("Cancel") {}.disabled(true)
                    .accessibilityIdentifier("cancelNewProject")
            case .uncertain:
                Button("Close") { returnToLibrary() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(creation.isRefreshingAfterUncertain)
            case .created:
                Button("Close") { returnToLibrary() }
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
                Button("Done") { returnToLibrary() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(blocksFilesPageDismissal)
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
            returnToLibrary()
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

    private func returnToLibrary() {
        onReturnToLibrary()
        Task { await backend.refresh(.library) }
        dismiss()
    }

    private func closeDetails() {
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

private struct ProjectFileRow: Identifiable {
    let id: String
    let fileName: String
    let status: String
    let symbol: String
    let progress: Double?
    let localID: UUID?
}

private struct SelectedProjectFile: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    var fileName: String { url.lastPathComponent }
}
