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
    @ObservationIgnored let diagnostics: SamplyDiagnostics
    @ObservationIgnored let clock: any MonotonicClock
    @ObservationIgnored private var transportOverride: (any SamplyBridgeTransport)?
    @ObservationIgnored private var pendingInvocations: [UInt64: PendingBridgeInvocation] = [:]

    var pollInterval: Duration { bridgeHealth.pollInterval(at: clock.now()) }
    @ObservationIgnored private let script: String
    @ObservationIgnored private let dataStore: WKWebsiteDataStore
    @ObservationIgnored private lazy var webKitTransport = WebKitBridgeTransport(webView: webView, script: script)

    override convenience init() {
        self.init(diagnostics: nil, transport: nil)
    }

    init(diagnostics: SamplyDiagnostics?, transport: (any SamplyBridgeTransport)? = nil) {
        self.diagnostics = diagnostics ?? .shared
        clock = SystemMonotonicClock()
        transportOverride = transport
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
            beginNewDocumentGeneration()
            authenticationState = .checking
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
        beginNewDocumentGeneration()
        authenticationState = .checking
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
               !bridgeHealth.recordFailure(at: clock.now()) { return false }
            connectionError = error.localizedDescription
            return false
        }
    }

    func call<T: Decodable>(_ command: String, arguments: [String: Any] = [:]) async throws -> T {
        guard !isSigningOut else { throw CancellationError() }
        if transportOverride == nil {
            guard !script.isEmpty, webView.url?.host == "samply.app",
                  webView.url?.scheme == "https" else { throw SamplyError.bridgeUnavailable }
        }
        let stamp = generation
        let operationID = diagnostics.nextOperationID()
        let category = SamplyDiagnosticCommand(command: command)
        let startedAt = clock.now()
        let result: Any?
        do {
            result = try await invoke(command: command, arguments: arguments, operationID: operationID)
        } catch {
            let mapped: Error
            if error is CancellationError { mapped = error }
            else if let bridge = error as? SamplyBridgeError { mapped = bridge }
            else { mapped = SamplyBridgeError.executionFailed }
            recordInvocation(category, operationID, startedAt, bytes: 0,
                             outcome: SamplyDiagnosticOutcome(mapped))
            guard generation == stamp, !isSigningOut else { throw CancellationError() }
            throw mapped
        }
        guard generation == stamp, !isSigningOut else { throw CancellationError() }
        guard let value = result as? String, let data = value.data(using: .utf8) else {
            recordInvocation(category, operationID, startedAt, bytes: 0, outcome: .failure)
            throw SamplyError.invalidResponse
        }
        let decodeStartedAt = clock.now()
        let response: SamplyBridgeResponse<T>
        do {
            response = try JSONDecoder().decode(SamplyBridgeResponse<T>.self, from: data)
        } catch {
            diagnostics.record(SamplyDiagnosticSample(
                stage: .responseDecoding, command: category, operationID: operationID,
                duration: clock.now() - decodeStartedAt, responseBytes: data.count,
                outcome: .failure))
            recordInvocation(category, operationID, startedAt, bytes: data.count, outcome: .failure)
            throw SamplyError.invalidResponse
        }
        diagnostics.record(SamplyDiagnosticSample(
            stage: .responseDecoding, command: category, operationID: operationID,
            duration: clock.now() - decodeStartedAt, responseBytes: data.count))
        if let failure = response.failure {
            let error = Self.bridgeError(for: failure)
            recordInvocation(category, operationID, startedAt, bytes: data.count,
                             outcome: SamplyDiagnosticOutcome(error))
            throw error
        }
        guard let payload = response.payload else {
            recordInvocation(category, operationID, startedAt, bytes: data.count, outcome: .failure)
            throw SamplyError.invalidResponse
        }
        recordInvocation(category, operationID, startedAt, bytes: data.count, outcome: .success)
        return payload
    }

    /// Fixed mappings only. Arbitrary page exception text never reaches native UI.
    private static func bridgeError(for failure: String) -> SamplyBridgeError {
        switch failure {
        case "notReady": .notReady
        case "contractMismatch": .contractMismatch
        case "accessDenied": .accessDenied
        case "superseded": .superseded
        case "timedOut": .timedOut
        case "operationFailed": .operationFailed
        default: .executionFailed
        }
    }

    private func recordInvocation(_ category: SamplyDiagnosticCommand?, _ operationID: UInt64,
                                  _ startedAt: TimeInterval, bytes: Int,
                                  outcome: SamplyDiagnosticOutcome) {
        diagnostics.record(SamplyDiagnosticSample(
            stage: .bridgeInvocation, command: category, operationID: operationID,
            duration: clock.now() - startedAt, responseBytes: bytes, outcome: outcome))
    }

    /// The entire native invocation is settled exactly once by the registry:
    /// a late WebKit completion after cancellation is ignored.
    private func invoke(command: String, arguments: [String: Any],
                        operationID: UInt64) async throws -> Any? {
        let stamp = generation
        let transport = transportOverride ?? webKitTransport
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pendingInvocations[operationID] = PendingBridgeInvocation(generation: stamp,
                                                                          continuation: continuation)
                transport.invoke(command: command, arguments: arguments) { [weak self] result in
                    self?.finishInvocation(operationID, result: result)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishInvocation(operationID, result: .failure(CancellationError()))
            }
        }
    }

    private func finishInvocation(_ operationID: UInt64, result: Result<Any?, Error>) {
        guard let pending = pendingInvocations.removeValue(forKey: operationID) else { return }
        guard pending.generation == generation else {
            pending.continuation.resume(throwing: CancellationError())
            return
        }
        pending.continuation.resume(with: result)
    }

    /// Invalidates in-flight bridge work when the document changes. A late
    /// callback from the previous document must never settle a newer request.
    func beginNewDocumentGeneration() {
        generation += 1
        bridgeHealth.reset()
        connectionError = nil
        cancelPendingInvocations()
    }

    private func cancelPendingInvocations() {
        let pending = pendingInvocations
        pendingInvocations.removeAll()
        for entry in pending.values {
            entry.continuation.resume(throwing: CancellationError())
        }
    }

    func signOut() async {
        dismissSignIn()
        profile.clear()
        isSigningOut = true
        beginNewDocumentGeneration()
        authenticationState = .checking
        snapshot = nil
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
        beginNewDocumentGeneration()
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
        beginNewDocumentGeneration()
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

private struct PendingBridgeInvocation {
    let generation: Int
    let continuation: CheckedContinuation<Any?, Error>
}

private struct SamplyBridgeResponse<Payload: Decodable>: Decodable {
    let payload: Payload?
    let failure: String?
}
