import SwiftUI

/// Settings layout inspired by the user-provided AudioMator reference.
struct ConnectionView: View {
    @Bindable var backend: SamplyBackend
    @State private var token = ""
    @State private var isSaving = false
    @State private var message: String?

    var body: some View {
        TabView {
            settingsPage(
                title: "Account Settings",
                detail: "Manage your Samply account and playback session."
            ) {
                accountSection
                if !backend.isConnected && !backend.isCheckingSession && !backend.web.isSigningOut {
                    ConnectionSettingsSection(title: "Email Sign-In") {
                        EmailSignInLinkView(session: backend.web)
                            .padding(18)
                    }
                }
            }
            .tabItem { Label("Account", systemImage: "person.crop.circle") }

            settingsPage(
                title: "API Access",
                detail: "Connect a personal access token to create projects and upload original files."
            ) {
                tokenSection
                ConnectionSettingsSection(title: "Token Storage") {
                    ConnectionSettingsRow(
                        title: "Saved on This Mac",
                        detail: "Your token is stored unencrypted on this Mac and restored automatically for this account. Signing out or removing the token deletes the saved copy.",
                        systemImage: "internaldrive"
                    ) {
                        EmptyView()
                    }
                }
                if let message {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .accessibilityLabel(message)
                }
            }
            .tabItem { Label("API Access", systemImage: "key") }
        }
        .frame(width: 700, height: 560)
        .disabled(isSaving || backend.web.isSigningOut)
        .onDisappear { token = "" }
    }

    private func settingsPage<Content: View>(
        title: String,
        detail: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(detail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                content()
            }
            .padding(24)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var accountSection: some View {
        ConnectionSettingsSection {
            if backend.web.isSigningOut {
                ConnectionSettingsRow(title: "Signing out…", systemImage: "person.crop.circle") {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Signing out of Samply")
                }
            } else if backend.isCheckingSession {
                ConnectionSettingsRow(title: "Loading your Samply session…", systemImage: "person.crop.circle") {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Loading your Samply session")
                }
            } else if backend.isConnected {
                ConnectionSettingsRow(
                    title: "Signed in to Samply",
                    detail: accountName,
                    systemImage: "person.crop.circle"
                ) {
                    Button("Open Samply Window") { backend.web.showWindow() }
                }
                ConnectionSettingsDivider()
                ConnectionSettingsRow(
                    title: "Sign Out",
                    detail: "Stop playback and remove this app's session and personal access token.",
                    systemImage: "rectangle.portrait.and.arrow.right"
                ) {
                    Button("Sign Out", role: .destructive) { signOut() }
                        .accessibilityIdentifier("signOutSamply")
                }
            } else {
                ConnectionSettingsRow(
                    title: "Sign In to Samply",
                    detail: "Browse your library and play music with your Samply account.",
                    systemImage: "person.crop.circle"
                ) {
                    Button("Sign In") { backend.web.showSignIn() }
                }
            }
            ConnectionSettingsDivider()
            ConnectionSettingsRow(
                title: "Playback Session",
                detail: "Playback continues when you close the Samply window.",
                systemImage: "play.rectangle"
            ) {
                EmptyView()
            }
        }
    }

    private var accountName: String? {
        guard let name = backend.web.snapshot?.account?.name, !name.isEmpty else { return nil }
        return name
    }

    private var tokenSection: some View {
        ConnectionSettingsSection(title: "Personal Access Token") {
            ConnectionSettingsRow(
                title: backend.hasToken ? "Token Added" : "Optional API Access",
                detail: backend.hasToken
                    ? "A verified token is saved on this Mac."
                    : "Sign in, then add a token from the same Samply account.",
                systemImage: "key"
            ) {
                Button("Create Token") { backend.web.openTokenPreferences() }
            }
            ConnectionSettingsDivider()
            VStack(alignment: .leading, spacing: 10) {
                Text(backend.hasToken ? "Replace Token" : "Add Token")
                    .font(.body.weight(.medium))
                HStack(spacing: 12) {
                    SecureField("Paste your Samply token", text: $token)
                        .textFieldStyle(.roundedBorder)
                        .privacySensitive()
                        .onSubmit { save() }
                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Verifying token")
                    }
                    Button("Verify and Save") { save() }
                        .disabled(token.isEmpty || isSaving || !backend.isConnected || backend.isCheckingSession)
                }
            }
            .padding(.leading, 54)
            .padding(.trailing, 18)
            .padding(.vertical, 16)
            if backend.hasToken {
                ConnectionSettingsDivider()
                ConnectionSettingsRow(
                    title: "Remove Token",
                    detail: "Delete the saved token from this Mac. Library playback stays available.",
                    systemImage: "minus.circle"
                ) {
                    Button("Remove Token", role: .destructive) {
                        token = ""
                        do { try backend.removeToken(); message = "Token removed." }
                        catch { message = error.localizedDescription }
                    }
                }
            }
        }
    }

    private func signOut() {
        guard !backend.web.isSigningOut else { return }
        token = ""
        message = nil
        Task { await backend.signOut() }
    }

    private func save() {
        guard !isSaving, !token.isEmpty else { return }
        isSaving = true
        message = nil
        let candidate = token
        token = ""
        Task {
            do { try await backend.saveToken(candidate); message = "Token verified and saved on this Mac." }
            catch { message = error.localizedDescription }
            isSaving = false
        }
    }
}

private struct ConnectionSettingsSection<Content: View>: View {
    var title: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.secondary.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

private struct ConnectionSettingsRow<Action: View>: View {
    let title: String
    var detail: String? = nil
    let systemImage: String
    @ViewBuilder let action: Action

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body.weight(.medium))
                if let detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            action
                .controlSize(.small)
                .fixedSize()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }
}

private struct ConnectionSettingsDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, 54)
            .padding(.trailing, 18)
    }
}
