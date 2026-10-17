import AppKit
import Observation
import SwiftUI
import WebKit

@MainActor
@Observable
final class SamplyWebSession: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    private(set) var snapshot: WebSnapshot?
    private(set) var connectionError: String?
    private(set) var isSigningOut = false
    private(set) var authenticationState: WebAuthenticationState = .checking
    @ObservationIgnored let webView: WKWebView
    @ObservationIgnored private var window: NSWindow?
    @ObservationIgnored private var popupWindows: [NSWindow] = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private let script: String
    @ObservationIgnored private let dataStore: WKWebsiteDataStore

    override init() {
        // App-specific cookie/IndexedDB storage. Never read Safari/Chromium credentials.
        #if DEBUG
        let storeID = "110C778D-236A-4F13-A27C-9A85F4CAB40D"
        #else
        let storeID = "B5A86A16-97EB-4552-AFEF-78746D4732B7"
        #endif
        dataStore = WKWebsiteDataStore(forIdentifier: UUID(uuidString: storeID)!)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        if let url = Bundle.main.url(forResource: "SamplyBridge", withExtension: "js"),
           let source = try? String(contentsOf: url, encoding: .utf8) { script = source }
        else { script = "" }
        config.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 780), configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        #if DEBUG
        webView.isInspectable = true
        #endif
    }

    func start() {
        guard !hasStarted, !isSigningOut else { return }
        hasStarted = true
        authenticationState = .checking
        // Keep the same WKWebView attached to an app-owned window even when ordered out.
        // Login and background playback therefore share one media engine and website session.
        makeWindowIfNeeded()
        webView.load(URLRequest(url: URL(string: "https://samply.app/library")!))
    }

    func showWindow() {
        start()
        makeWindowIfNeeded()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func openTokenPreferences() {
        start()
        webView.load(URLRequest(url: URL(string: "https://samply.app/preferences/api")!))
        showWindow()
    }

    func openEmailSignInLink(_ input: String) throws {
        guard !isSigningOut else { throw EmailSignInLinkError.signingOut }
        guard snapshot?.account == nil else { throw EmailSignInLinkError.alreadyConnected }
        let url = try SamplyEmailSignInLink.parse(input)
        generation += 1
        authenticationState = .checking
        connectionError = nil
        // Loading in this WebView preserves Samply's emailForSignIn and existing auth state.
        // Do not preflight the one-time link or send it through a separate URLSession.
        hasStarted = true
        makeWindowIfNeeded()
        webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        showWindow()
    }

    private func makeWindowIfNeeded() {
        guard window == nil else { return }
        let window = NSWindow(contentRect: webView.frame, styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Samply · Sign-In and Player"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SamplyWebWindowView(session: self))
        window.delegate = self
        window.center()
        self.window = window
    }

    func refresh() async {
        guard !isSigningOut, webView.url?.host == "samply.app", webView.url?.scheme == "https" else { return }
        let stamp = generation
        do {
            let state: WebSnapshot = try await call("snapshot")
            guard generation == stamp else { return }
            // A newer/different contract must never silently drive the native library.
            guard state.version == 1 else { throw SamplyError.invalidResponse }
            snapshot = state
            authenticationState = state.authenticationState
            connectionError = nil
        } catch {
            guard generation == stamp else { return }
            connectionError = error.localizedDescription
        }
    }

    func call<T: Decodable>(_ command: String, arguments: [String: Any] = [:]) async throws -> T {
        guard !isSigningOut, !script.isEmpty, webView.url?.host == "samply.app",
              webView.url?.scheme == "https" else { throw SamplyError.bridgeUnavailable }
        let stamp = generation
        let result = try await webView.callAsyncJavaScript("""
            if (!window.__tunesSamply) { \(script) }
            if (!window.__tunesSamply) throw new Error('Samply adapter unavailable.');
            return JSON.stringify(await window.__tunesSamply.command(command, args));
            """, arguments: ["command": command, "args": arguments], in: nil, contentWorld: .page)
        guard generation == stamp, !isSigningOut else { throw CancellationError() }
        guard let value = result as? String, let data = value.data(using: .utf8) else { throw SamplyError.invalidResponse }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func signOut() async {
        isSigningOut = true
        authenticationState = .checking
        generation += 1
        snapshot = nil
        connectionError = nil
        webView.stopLoading()
        await webView.pauseAllMediaPlayback()
        for popup in popupWindows { popup.close() }
        popupWindows.removeAll()
        webView.loadHTMLString("", baseURL: nil)
        // Remove IndexedDB (Firebase auth), cookies, caches and service workers together.
        await dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        hasStarted = false
        authenticationState = .signedOut
        isSigningOut = false
        window?.orderOut(nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView === self.webView { connectionError = nil }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        reportNavigationFailure(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        reportNavigationFailure(error)
    }

    private func reportNavigationFailure(_ error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        // Localized WebKit/network errors can contain the URL, including the email code.
        connectionError = "Could not load the page. Check your connection and try again. If your sign-in link has expired, request a new email."
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        generation += 1
        snapshot = nil
        authenticationState = .checking
        connectionError = "The Samply web process stopped. Reloading…"
        webView.reload()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if ["http", "https"].contains(url.scheme?.lowercased() ?? "") || url.absoluteString == "about:blank" { decisionHandler(.allow) }
        else { decisionHandler(.cancel) }
    }

    // OAuth popups must keep the supplied WebKit configuration/window.opener relationship.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.targetFrame == nil, !isSigningOut,
              navigationAction.request.url?.scheme == "https" else { return nil }
        let popup = WKWebView(frame: NSRect(x: 0, y: 0, width: 580, height: 720), configuration: configuration)
        popup.navigationDelegate = self
        popup.uiDelegate = self
        let window = NSWindow(contentRect: popup.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Samply Sign-In"
        window.contentView = popup
        window.delegate = self
        popupWindows.append(window)
        window.center()
        window.makeKeyAndOrderFront(nil)
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        popupWindows.first(where: { $0.contentView === webView })?.close()
        popupWindows.removeAll { $0.contentView === webView }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === window { sender.orderOut(nil); return false }
        return true
    }
}
