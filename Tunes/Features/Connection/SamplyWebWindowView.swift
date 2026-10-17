import SwiftUI
import WebKit

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
