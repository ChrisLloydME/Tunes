import SwiftUI
import WebKit

struct EmailSignInLinkView: View {
    @Bindable var session: SamplyWebSession
    @State private var link = ""
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Email Sign-In Link").font(.headline)
            Text("Request a sign-in email in Samply, then copy the link from the email and paste it here.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                SecureField("Paste the full sign-in link", text: $link)
                    .textFieldStyle(.roundedBorder)
                    .privacySensitive()
                    .onSubmit { openLink() }
                Button("Continue Sign-In") { openLink() }
                    .disabled(link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.isSigningOut)
            }
            if let message {
                Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: session.snapshot?.account?.uid) { _, _ in
            link = ""
            message = nil
        }
        .onDisappear { link = "" }
    }

    private func openLink() {
        let candidate = link
        link = ""
        do {
            try session.openEmailSignInLink(candidate)
            message = "Link opened. Complete sign-in in the Samply window. If the link has expired, request a new email."
        } catch {
            message = error.localizedDescription
        }
    }
}

/// Keeps the email-link entry beside the same WebKit session that requested the email.
struct SamplyWebWindowView: View {
    @Bindable var session: SamplyWebSession

    var body: some View {
        VStack(spacing: 0) {
            if session.snapshot?.account == nil {
                EmailSignInLinkView(session: session).padding(16)
                Divider()
            }
            SamplyBrowserView(webView: session.webView)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 620, minHeight: 480)
    }
}

private struct SamplyBrowserView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
