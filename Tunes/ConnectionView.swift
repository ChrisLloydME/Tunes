import SwiftUI

struct ConnectionView: View {
    @Bindable var backend: SamplyBackend
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var isSaving = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Connect to Samply").font(.title2.weight(.semibold))
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text(backend.isConnected ? "Signed in to Samply" : "Sign in to your Samply account").font(.headline)
                    Text("Sign in to browse your library and play music. Playback continues when you close the Samply window.")
                        .foregroundStyle(.secondary)
                    Button(backend.isConnected ? "Open Samply Window" : "Sign In to Samply") { backend.web.showWindow() }
                    if !backend.isConnected {
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
                Button("Sign Out", role: .destructive) { Task { await backend.signOut() } }
                    .disabled(backend.web.isSigningOut)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 540)
        .disabled(isSaving)
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
