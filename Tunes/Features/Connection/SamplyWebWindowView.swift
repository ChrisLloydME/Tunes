import SwiftUI
import WebKit

/// Keeps the email-link entry beside the same WebKit session that requested the email.
struct SamplyWebWindowView: View {
    @Bindable var session: SamplyWebSession
    var isSignIn = false

    var body: some View {
        SamplyBrowserView(webView: session.webView)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
            .overlay(alignment: .topLeading) {
                if isSignIn {
                    Color(nsColor: session.pageBackgroundColor)
                        .frame(width: 88, height: 88)
                        .contentShape(Rectangle())
                        // Block clicks to the webpage's covered navigation button.
                        .onTapGesture { }
                        .accessibilityHidden(true)
                }
            }
            .overlay(alignment: .topTrailing) {
                if isSignIn || session.snapshot?.account == nil {
                    HStack(alignment: .top) {
                        if isSignIn {
                            Button { session.dismissSignIn() } label: {
                                Image(systemName: "xmark")
                                    .frame(width: 32, height: 32)
                            }
                            .buttonStyle(.plain)
                            .compatGlass(interactive: true, in: .circle)
                            .accessibilityLabel("Close sign-in")
                            .help("Close sign-in")
                            .keyboardShortcut(.cancelAction)
                        }
                        Spacer()
                        EmailSignInLinkView(session: session, usesCapsule: true)
                    }
                    .padding(.top, 12)
                    .padding(.horizontal, 16)
                }
            }
            .frame(minWidth: 620, minHeight: 480)
    }
}

private struct SamplyBrowserView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
