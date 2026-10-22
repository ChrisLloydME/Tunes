import Foundation
import WebKit

/// One complete adapter invocation. Production uses WebKit; tests inject a
/// transport that can delay, never complete, or complete after supersession
/// without navigating a real page.
@MainActor
protocol SamplyBridgeTransport: AnyObject {
    func invoke(command: String, arguments: [String: Any],
                completion: @escaping @MainActor (Result<Any?, Error>) -> Void)
}

@MainActor
final class WebKitBridgeTransport: SamplyBridgeTransport {
    private let webView: WKWebView
    private let script: String

    init(webView: WKWebView, script: String) {
        self.webView = webView
        self.script = script
    }

    func invoke(command: String, arguments: [String: Any],
                completion: @escaping @MainActor (Result<Any?, Error>) -> Void) {
        webView.callAsyncJavaScript(Self.functionBody(adapter: script),
                                    arguments: ["command": command, "args": arguments],
                                    in: nil, in: .page,
                                    completionHandler: { result in
            Task { @MainActor in
                switch result {
                case .success(let value): completion(.success(value))
                case .failure(let error): completion(.failure(error))
                }
            }
        })
    }

    /// The adapter source is bundled, never assembled from caller input.
    static func functionBody(adapter: String) -> String {
        """
        try {
        if (!window.__tunesSamply) { \(adapter) }
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
        """
    }
}
