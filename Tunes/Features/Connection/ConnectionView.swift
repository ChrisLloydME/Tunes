import SwiftUI

struct ConnectionView: View {
    @Bindable var backend: SamplyBackend
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var isSaving = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Samply Account").font(.title2.weight(.semibold))
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    if backend.web.isSigningOut {
                        HStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityLabel("Signing out of Samply")
                            Text("Signing out…")
                                .foregroundStyle(.secondary)
                        }
                    } else if backend.isCheckingSession {
                        HStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityLabel("Loading your Samply session")
                            Text("Loading your Samply session…")
                                .foregroundStyle(.secondary)
                        }
                    } else if backend.isConnected {
                        Text("Signed in to Samply").font(.headline)
                        if let name = backend.web.snapshot?.account?.name, !name.isEmpty {
                            Text(name)
                                .font(.callout)
                                .textSelection(.enabled)
                        }
                        Text("Signing out stops playback and removes this app's session and upload token.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Open Samply Window") { backend.web.showWindow() }
                            Spacer()
                            Button("Sign Out", role: .destructive) { signOut() }
                                .accessibilityIdentifier("signOutSamply")
                        }
                    } else {
                        Text("Sign in to your Samply account").font(.headline)
                        Text("Sign in to browse your library and play music. Playback continues when you close the Samply window.")
                            .foregroundStyle(.secondary)
                        Button("Sign In to Samply") { backend.web.showSignIn() }
                        Divider()
                        EmailSignInLinkView(session: backend.web)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Personal Access Token (Optional)").font(.headline)
                    Text("Uploads require a token from the same Samply account. It stays in memory until you quit Tunes.")
                        .foregroundStyle(.secondary)
                    HStack {
                        SecureField("Paste your Samply token", text: $token)
                            .onSubmit { save() }
                        Button("Verify and Save") { save() }.disabled(token.isEmpty || isSaving)
                    }
                    HStack {
                        Button("Create Token") { backend.web.openTokenPreferences() }
                        if backend.hasToken {
                            Text("Token saved for this session").foregroundStyle(.secondary)
                            Button("Remove Token") {
                                do { try backend.removeToken(); message = "Token removed." }
                                catch { message = error.localizedDescription }
                            }
                        }
                        if isSaving { ProgressView().controlSize(.small) }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            if let message { Text(message).font(.callout).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 540)
        .disabled(isSaving || backend.web.isSigningOut)
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
            do { try await backend.saveToken(candidate); message = "Token verified. It will be cleared when you quit Tunes." }
            catch { message = error.localizedDescription }
            isSaving = false
        }
    }
}
