import SwiftUI

struct NewProjectSheet: View {
    @Bindable var backend: SamplyBackend
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var validationMessage: String?
    @FocusState private var nameFieldFocused: Bool

    private var creation: ProjectCreationCoordinator { backend.projectCreation }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("New Project")
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("Create an empty project in Samply. You can upload original files after it opens.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            if !backend.isConnected {
                signedOutGuidance
            } else if backend.hasToken {
                projectContent
            } else {
                tokenGuidance
            }

            footer
        }
        .padding(24)
        .frame(width: 480, alignment: .topLeading)
        .interactiveDismissDisabled(creation.blocksDismissal)
        .onAppear {
            if case .idle = creation.state {
                name = ""
                validationMessage = nil
                nameFieldFocused = true
            }
        }
        .onChange(of: backend.hasToken) { _, hasToken in
            if hasToken, case .idle = creation.state { nameFieldFocused = true }
        }
        .onChange(of: creation.createdStage) { _, stage in
            if stage == .opened { dismiss() }
        }
        .onDisappear {
            if creation.createdStage == .opened { creation.reset() }
        }
    }

    @ViewBuilder private var projectContent: some View {
        switch creation.state {
        case .idle, .failed:
            nameForm

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
            VStack(alignment: .leading, spacing: 12) {
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
            }

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
                    .disabled(trimmedName.isEmpty || creation.isCreating)
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
            if stage.isBusy {
                Button("Close") {}.disabled(true)
            } else {
                Button("Close") { close() }
                Button("Refresh Library") {
                    Task { await creation.refreshLibrary() }
                }
                .disabled(creation.isRefreshingAfterUncertain)
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
            return "Project created."
        case .delayed:
            return "Project created, but it has not appeared in your Library yet. Samply may still be updating your history."
        case .refreshFailed(let message), .openFailed(let message):
            return message
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

    private func submit() {
        guard backend.isConnected, backend.hasToken, !creation.isCreating else { return }
        guard !trimmedName.isEmpty else {
            validationMessage = "Enter a project name."
            nameFieldFocused = true
            return
        }
        validationMessage = nil
        Task { await creation.create(name: name) }
    }

    private func close() {
        switch creation.state {
        case .idle, .failed:
            creation.reset()
        default:
            break
        }
        dismiss()
    }
}
