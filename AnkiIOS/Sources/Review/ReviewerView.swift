// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html

import SwiftUI
import WebKit

// MARK: - SwiftUI View

struct ReviewerView: View {
    @StateObject private var session: ReviewSession
    @Environment(\.dismiss) private var dismiss

    /// The collection.media folder URL, used by MediaSchemeHandler.
    private let mediaFolder: URL

    init(backend: BackendClient, deckId: Int64, mediaFolder: URL) {
        _session = StateObject(wrappedValue: ReviewSession(backend: backend, deckId: deckId))
        self.mediaFolder = mediaFolder
    }

    var body: some View {
        VStack(spacing: 0) {
            countsBar
            reviewArea
            actionBar
        }
        .navigationBarBackButtonHidden(false)
        .task { session.start() }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var countsBar: some View {
        switch session.reviewState {
        case .question(let ctx), .answer(let ctx):
            HStack(spacing: 16) {
                Label("\(ctx.newCount)", systemImage: "sparkles")
                    .foregroundStyle(.blue)
                Label("\(ctx.learningCount)", systemImage: "arrow.clockwise")
                    .foregroundStyle(.orange)
                Label("\(ctx.reviewCount)", systemImage: "checkmark")
                    .foregroundStyle(.green)
            }
            .font(.caption)
            .padding(.vertical, 8)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var reviewArea: some View {
        switch session.reviewState {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .question(let ctx):
            ReviewWebView(
                html: reviewPageHTML(
                    cardCSS: ctx.cardCSS,
                    mediaFolder: mediaFolder),
                pendingJS: showQuestionJS(
                    q: ctx.questionHTML,
                    a: ctx.answerHTML,
                    bodyClass: "card"),
                onCommand: bridgeCommandHandler,
                mediaFolder: mediaFolder)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .answer(let ctx):
            ReviewWebView(
                html: reviewPageHTML(
                    cardCSS: ctx.cardCSS,
                    mediaFolder: mediaFolder),
                pendingJS: showAnswerJS(
                    a: ctx.answerHTML,
                    bodyClass: "card"),
                onCommand: bridgeCommandHandler,
                mediaFolder: mediaFolder)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .congrats:
            VStack(spacing: 16) {
                Image(systemName: "party.popper")
                    .font(.system(size: 60))
                    .foregroundStyle(.green)
                Text("Congratulations!\nNo cards remaining for today.")
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .error(let msg):
            ContentUnavailableView(
                "Review Error",
                systemImage: "exclamationmark.triangle",
                description: Text(msg))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Bridge command handler

    /// Closure passed to ReviewWebView.onCommand. Captures session strongly —
    /// ReviewerView is a struct, so there is no retain cycle.
    private var bridgeCommandHandler: (String) -> Void {
        { [session] cmd in
            Task { @MainActor in
                switch cmd {
                case "ans":
                    session.showAnswer()
                case _ where cmd.hasPrefix("ease"):
                    if let ease = Int(cmd.dropFirst(4)) {
                        session.answer(ease: ease)
                    }
                default:
                    break
                }
            }
        }
    }

    @ViewBuilder
    private var actionBar: some View {
        switch session.reviewState {
        case .question:
            Button("Show Answer") { session.showAnswer() }
                .buttonStyle(.borderedProminent)
                .padding()

        case .answer:
            HStack(spacing: 8) {
                EaseButton(label: "Again", color: .red) { session.answer(ease: 1) }
                EaseButton(label: "Hard", color: .orange) { session.answer(ease: 2) }
                EaseButton(label: "Good", color: .green) { session.answer(ease: 3) }
                EaseButton(label: "Easy", color: .blue) { session.answer(ease: 4) }
            }
            .padding()

        case .congrats:
            Button("Back to Decks") { dismiss() }
                .buttonStyle(.borderedProminent)
                .padding()

        default:
            EmptyView()
        }
    }
}

// MARK: - Helper Button

private struct EaseButton: View {
    let label: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(color)
    }
}

// MARK: - HTML / JS Generation

private func reviewPageHTML(cardCSS: String, mediaFolder: URL) -> String {
    // The reviewer page is a minimal self-contained HTML document.
    // We define window.bridgeCommand to route commands from card JS to Swift
    // via WKScriptMessageHandler ("ankiBridge").
    // Media files are loaded from anki-media:// (served by MediaSchemeHandler).
    return """
    <!doctype html>
    <html>
    <head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no">
    <style>
    html, body { margin: 0; padding: 0; }
    body { padding: 12px; font-family: -apple-system, sans-serif; font-size: 18px; }
    #qa img { max-width: 100%; height: auto; }
    #_flag, #_mark { display: none; }
    </style>
    <style id="card-css">\(escapeCSSForHTML(cardCSS))</style>
    </head>
    <body class="card">
    <div id="_flag" hidden></div>
    <div id="_mark" hidden></div>
    <div id="qa"></div>
    <script>
    // Route bridgeCommand (pycmd) to Swift WKScriptMessageHandler
    window.bridgeCommand = window.pycmd = function(arg, cb) {
        window.webkit.messageHandlers.ankiBridge.postMessage(arg);
        return false;
    };

    function _setInnerHTML(el, html) {
        el.innerHTML = html;
        // Re-execute any <script> tags inside the injected HTML
        Array.from(el.querySelectorAll("script")).forEach(function(old) {
            var s = document.createElement("script");
            s.textContent = old.textContent;
            old.replaceWith(s);
        });
    }

    function _showQuestion(q, a, bodyclass) {
        document.body.className = bodyclass || "card";
        window.scrollTo(0, 0);
        _setInnerHTML(document.getElementById("qa"), q);
    }

    function _showAnswer(a, bodyclass) {
        if (bodyclass) { document.body.className = bodyclass; }
        _setInnerHTML(document.getElementById("qa"), a);
        var anchor = document.getElementById("answer");
        if (anchor) { anchor.scrollIntoView(); }
    }

    function _drawFlag(flag) {
        var el = document.getElementById("_flag");
        if (!el) return;
        if (flag === 0) { el.setAttribute("hidden",""); }
        else { el.removeAttribute("hidden"); el.style.color = "var(--flag-" + flag + ")"; }
    }

    function _drawMark(mark) {
        var el = document.getElementById("_mark");
        if (!el) return;
        if (mark) { el.removeAttribute("hidden"); } else { el.setAttribute("hidden",""); }
    }

    function _typeAnsPress() {
        if ((window.event || {}).key === "Enter") { bridgeCommand("ans"); }
    }
    </script>
    </body>
    </html>
    """
}

private func escapeCSSForHTML(_ css: String) -> String {
    // Only </style> needs escaping inside a <style> block.
    css.replacingOccurrences(of: "</style>", with: "<\\/style>")
}

private func jsStringLiteral(_ s: String) -> String {
    // JSON-encode the string so it can be passed safely to JS eval.
    let data = try? JSONSerialization.data(withJSONObject: s)
    return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
}

private func showQuestionJS(q: String, a: String, bodyClass: String) -> String {
    "_showQuestion(\(jsStringLiteral(q)), \(jsStringLiteral(a)), \(jsStringLiteral(bodyClass)));"
}

private func showAnswerJS(a: String, bodyClass: String) -> String {
    "_showAnswer(\(jsStringLiteral(a)), \(jsStringLiteral(bodyClass)));"
}

// MARK: - WKWebView UIViewRepresentable

/// UIViewRepresentable wrapping WKWebView for the card reviewer.
///
/// `html` is the full reviewer page HTML (regenerated when card CSS changes).
/// `pendingJS` is evaluated after the page finishes loading to inject card content.
/// The web view is recreated when `html` changes (which happens every card since
/// each card can have different CSS — WKWebView recreation is cheap here).
private struct ReviewWebView: UIViewRepresentable {
    let html: String
    let pendingJS: String
    let onCommand: (String) -> Void
    let mediaFolder: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(onCommand: onCommand)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(
            MediaSchemeHandler(mediaFolder: mediaFolder),
            forURLScheme: "anki-media")
        config.userContentController.add(context.coordinator, name: "ankiBridge")
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = context.coordinator
        context.coordinator.currentHTML = html
        context.coordinator.pendingJS = pendingJS
        wv.loadHTMLString(html, baseURL: nil)
        return wv
    }

    static func dismantleUIView(_ wv: WKWebView, coordinator: Coordinator) {
        wv.configuration.userContentController.removeScriptMessageHandler(forName: "ankiBridge")
    }

    func updateUIView(_ wv: WKWebView, context: Context) {
        if context.coordinator.currentHTML != html {
            // Card CSS changed (different note type). Reload the page, then
            // the navigation delegate will evaluate pendingJS on didFinish.
            context.coordinator.currentHTML = html
            context.coordinator.pendingJS = pendingJS
            context.coordinator.pageLoaded = false
            wv.loadHTMLString(html, baseURL: nil)
        } else if context.coordinator.pendingJS != pendingJS {
            // Same page, new card content (question → answer, or next card
            // with the same CSS). Evaluate directly if already loaded.
            context.coordinator.pendingJS = pendingJS
            if context.coordinator.pageLoaded {
                wv.evaluateJavaScript(pendingJS)
            }
        }
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let onCommand: (String) -> Void
        var pendingJS: String = ""
        var currentHTML: String = ""
        var pageLoaded = false

        init(onCommand: @escaping (String) -> Void) {
            self.onCommand = onCommand
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            pageLoaded = true
            if !pendingJS.isEmpty {
                webView.evaluateJavaScript(pendingJS)
            }
        }

        func userContentController(
            _ ucc: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "ankiBridge",
                  let cmd = message.body as? String
            else { return }
            handleBridgeCommand(cmd, webView: message.webView)
        }

        private func handleBridgeCommand(_ cmd: String, webView: WKWebView?) {
            onCommand(cmd)
        }
    }
}
