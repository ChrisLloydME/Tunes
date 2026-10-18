import AppKit
import Observation
import SwiftUI
import WebKit

@MainActor
@Observable
final class SamplyWebSession: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    let profile: SamplyProfileCache
    private(set) var snapshot: WebSnapshot?
    private(set) var connectionError: String?
    private(set) var isSigningOut = false
    private(set) var authenticationState: WebAuthenticationState = .checking
    private(set) var pageBackgroundColor = NSColor.windowBackgroundColor
    @ObservationIgnored let webView: WKWebView
    @ObservationIgnored private var window: NSWindow?
    @ObservationIgnored private var signInWindow: NSWindow?
    @ObservationIgnored private var popupWindows: [NSWindow] = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private let sessionHistory: SamplySessionHistory
    @ObservationIgnored private var isCheckingStoredData = false
    @ObservationIgnored private var bridgeHealth = SamplyBridgeHealth()
    @ObservationIgnored private var isRefreshingSnapshot = false
    @ObservationIgnored private var pageBackgroundObservation: NSKeyValueObservation?

    var pollInterval: Duration { bridgeHealth.pollInterval(at: ProcessInfo.processInfo.systemUptime) }
    @ObservationIgnored private let script: String
    @ObservationIgnored private let dataStore: WKWebsiteDataStore

    override init() {
        let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ||
            NSClassFromString("XCTestCase") != nil
        profile = SamplyProfileCache(defaults: isTesting ? nil : .standard)
        sessionHistory = SamplySessionHistory(defaults: isTesting ? nil : .standard)
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
        authenticationState = sessionHistory.initialAuthenticationState
        webView.navigationDelegate = self
        webView.uiDelegate = self
        pageBackgroundColor = webView.underPageBackgroundColor
        pageBackgroundObservation = webView.observe(\.underPageBackgroundColor, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pageBackgroundColor = self.webView.underPageBackgroundColor
            }
        }
        #if DEBUG
        webView.isInspectable = true
        #endif
    }

    func start() {
        guard !hasStarted, !isSigningOut else { return }
        if let wasSignedIn = sessionHistory.wasSignedIn {
            if wasSignedIn { loadSession() }
            return
        }
        guard !isCheckingStoredData else { return }
        isCheckingStoredData = true
        let stamp = generation
        // Older installs have no startup hint. Check only this build's WebKit store,
        // preserving existing sessions without contacting Samply on a fresh install.
        dataStore.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { [weak self] records in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isCheckingStoredData = false
                guard self.generation == stamp, !self.hasStarted, !self.isSigningOut else { return }
                if self.sessionHistory.shouldRestoreLegacySession(hasWebsiteData: !records.isEmpty) {
                    self.loadSession()
                } else {
                    self.authenticationState = .signedOut
                }
            }
        }
    }

    private func loadSession() {
        guard !hasStarted, !isSigningOut else { return }
        hasStarted = true
        authenticationState = .checking
        // Keep the same WKWebView attached to an app-owned window even when ordered out.
        // Login and background playback therefore share one media engine and website session.
        makeWindowIfNeeded()
        webView.load(URLRequest(url: URL(string: "https://samply.app/library")!))
    }

    func showWindow() {
        loadSession()
        makeWindowIfNeeded()
        dismissSignIn()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showSignIn() {
        presentSignIn(resetPage: true)
    }

    private func presentSignIn(resetPage: Bool) {
        guard !isSigningOut else { return }
        if let signInWindow {
            signInWindow.makeKeyAndOrderFront(nil)
            return
        }
        guard let parent = NSApp.keyWindow ?? NSApp.mainWindow, parent !== window else { return }
        let restartsSignIn = resetPage && hasStarted && snapshot?.account == nil
        loadSession()
        makeWindowIfNeeded()
        if restartsSignIn {
            generation += 1
            authenticationState = .checking
            connectionError = nil
            webView.stopLoading()
            webView.load(URLRequest(url: URL(string: "https://samply.app/library")!,
                                    cachePolicy: .reloadIgnoringLocalCacheData))
        }
        window?.orderOut(nil)
        // Only one host may own the live player WebView at a time.
        window?.contentView = nil
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 620),
                             styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        sheet.title = "Sign In to Samply"
        sheet.titleVisibility = .hidden
        sheet.titlebarAppearsTransparent = true
        sheet.titlebarSeparatorStyle = .none
        sheet.isReleasedWhenClosed = false
        sheet.contentView = NSHostingView(rootView: SamplyWebWindowView(session: self, isSignIn: true))
        signInWindow = sheet
        parent.beginSheet(sheet) { [weak self, weak sheet] _ in
            guard let self, let sheet else { return }
            self.restorePlayerHost(after: sheet)
        }
    }

    func dismissSignIn() {
        guard let sheet = signInWindow else { return }
        sheet.sheetParent?.endSheet(sheet)
        restorePlayerHost(after: sheet)
    }

    private func restorePlayerHost(after sheet: NSWindow) {
        guard signInWindow === sheet else { return }
        sheet.orderOut(nil)
        sheet.contentView = nil
        signInWindow = nil
        window?.contentView = NSHostingView(rootView: SamplyWebWindowView(session: self))
    }

    func openTokenPreferences() {
        loadSession()
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
        // Present the email link already loading, without resetting it to the sign-in entry page.
        if signInWindow == nil { presentSignIn(resetPage: false) }
    }

    private func makeWindowIfNeeded() {
        guard window == nil else { return }
        let window = NSWindow(contentRect: webView.frame, styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Samply · Sign-In and Player"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SamplyWebWindowView(session: self))
        window.delegate = self
        window.center()
        self.window = window
    }

    @discardableResult
    func refresh() async -> Bool {
        guard !isSigningOut, !webView.isLoading, !isRefreshingSnapshot,
              webView.url?.host == "samply.app", webView.url?.scheme == "https" else { return false }
        isRefreshingSnapshot = true
        defer { isRefreshingSnapshot = false }
        let stamp = generation
        do {
            let state: WebSnapshot = try await call("snapshot")
            guard generation == stamp else { return false }
            // A newer/different contract must never silently drive the native library.
            guard state.version == 1 else { throw SamplyError.invalidResponse }
            profile.accept(state.account, authentication: state.authenticationState)
            sessionHistory.accept(state.authenticationState)
            snapshot = state
            authenticationState = state.authenticationState
            if state.authenticationState == .signedIn { dismissSignIn() }
            bridgeHealth.reset()
            connectionError = nil
            return true
        } catch {
            guard generation == stamp, !isSigningOut, !(error is CancellationError) else { return false }
            if error is SamplyBridgeError,
               !bridgeHealth.recordFailure(at: ProcessInfo.processInfo.systemUptime) { return false }
            connectionError = error.localizedDescription
            return false
        }
    }

    func call<T: Decodable>(_ command: String, arguments: [String: Any] = [:]) async throws -> T {
        guard !isSigningOut, !script.isEmpty, webView.url?.host == "samply.app",
              webView.url?.scheme == "https" else { throw SamplyError.bridgeUnavailable }
        let stamp = generation
        let result: Any?
        do {
            result = try await webView.callAsyncJavaScript("""
            try {
            if (!window.__tunesSamply) { \(script) }
            if (!window.__tunesSamply) throw new Error('Samply adapter unavailable.');
            return JSON.stringify({payload: await window.__tunesSamply.command(command, args)});
            } catch (error) {
                // Never send arbitrary page exception text (which can contain URLs or credentials).
                const code = error?.code;
                const rejected = code === 'TUNES_OPERATION_FAILED' ||
                    ['permission-denied', 'unauthenticated', 'not-found', 'functions/permission-denied',
                     'functions/unauthenticated', 'functions/not-found'].includes(code);
                return JSON.stringify({failure: code === 'TUNES_NOT_READY' ? 'notReady' : rejected ? 'operationFailed' : 'executionFailed'});
            }
            """, arguments: ["command": command, "args": arguments], in: nil, contentWorld: .page)
        } catch {
            guard generation == stamp, !isSigningOut else { throw CancellationError() }
            throw SamplyBridgeError.executionFailed
        }
        guard generation == stamp, !isSigningOut else { throw CancellationError() }
        guard let value = result as? String, let data = value.data(using: .utf8) else { throw SamplyError.invalidResponse }
        let response = try JSONDecoder().decode(SamplyBridgeResponse<T>.self, from: data)
        if response.failure == "notReady" { throw SamplyBridgeError.notReady }
        if response.failure == "operationFailed" { throw SamplyBridgeError.operationFailed }
        if response.failure != nil { throw SamplyBridgeError.executionFailed }
        guard let payload = response.payload else { throw SamplyError.invalidResponse }
        return payload
    }

    func signOut() async {
        dismissSignIn()
        profile.clear()
        isSigningOut = true
        bridgeHealth.reset()
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
        sessionHistory.accept(.signedOut)
        authenticationState = .signedOut
        isSigningOut = false
        window?.orderOut(nil)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        generation += 1
        bridgeHealth.reset()
        connectionError = nil
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
        guard webView === self.webView else { return }
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

private struct SamplyBridgeResponse<Payload: Decodable>: Decodable {
    let payload: Payload?
    let failure: String?
}
