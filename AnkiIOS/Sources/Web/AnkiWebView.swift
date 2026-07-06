// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html

import SwiftUI
import WebKit

// MARK: - Generic SvelteKit page wrapper

/// Wraps any Anki SvelteKit page in a WKWebView.
///
/// Phase 5 pages (editor, deck-options, stats, image-occlusion) are served by
/// the rslib mediasrv running on a loopback port. This view takes a URL and
/// routes bridgeCommand messages back to a handler closure.
///
/// Usage:
///   AnkiWebPageView(url: mediasrvURL(for: "deck-options")) { cmd in
///       // handle bridgeCommand
///   }
struct AnkiWebPageView: View {
    let url: URL
    /// Optional handler for pycmd/bridgeCommand messages from the page JS.
    var onBridgeCommand: ((String) -> Void)?

    var body: some View {
        _AnkiWebPageRepresentable(url: url, onBridgeCommand: onBridgeCommand)
            .ignoresSafeArea(edges: .bottom)
    }
}

private struct _AnkiWebPageRepresentable: UIViewRepresentable {
    let url: URL
    var onBridgeCommand: ((String) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(onBridgeCommand: onBridgeCommand) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Inject window.bridgeCommand before any page script runs.
        let bridge = WKUserScript(
            source: """
            window.bridgeCommand = window.pycmd = function(arg, cb) {
                window.webkit.messageHandlers.ankiBridge.postMessage(arg);
                return false;
            };
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false)
        config.userContentController.addUserScript(bridge)
        config.userContentController.add(context.coordinator, name: "ankiBridge")
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.load(URLRequest(url: url))
        return wv
    }

    func updateUIView(_ wv: WKWebView, context: Context) {
        if wv.url != url {
            wv.load(URLRequest(url: url))
        }
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        var onBridgeCommand: ((String) -> Void)?
        init(onBridgeCommand: ((String) -> Void)?) { self.onBridgeCommand = onBridgeCommand }

        func userContentController(
            _ ucc: WKUserContentController, didReceive message: WKScriptMessage
        ) {
            guard message.name == "ankiBridge", let cmd = message.body as? String else { return }
            onBridgeCommand?(cmd)
        }
    }
}
